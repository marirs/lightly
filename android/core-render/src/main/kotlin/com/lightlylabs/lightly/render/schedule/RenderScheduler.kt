package com.lightlylabs.lightly.render.schedule

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/** One preview render request. [revision] is issued by the scheduler and strictly increases. */
data class RenderRequest<out P>(
    val sessionId: String,
    val revision: Long,
    val payload: P,
)

sealed interface RenderOutcome<out R> {
    data class Rendered<out R>(val value: R) : RenderOutcome<R>
    data class Failed(val error: Throwable) : RenderOutcome<Nothing>
}

data class RenderResult<out R>(
    val sessionId: String,
    val revision: Long,
    val outcome: RenderOutcome<R>,
)

/** The GPU/CPU renderer behind the scheduler. Cancellation is cooperative; see [RenderScheduler]. */
fun interface PreviewRenderer<in P, out R> {
    suspend fun render(request: RenderRequest<P>): R
}

/**
 * Latest-wins preview scheduler, one per editing session (spec §5.2).
 *
 * - **Bounded:** one in-flight slot and one pending slot. A new request *replaces* the pending one,
 *   so a slider drag never builds a queue. The in-flight render is not cancelled by a newer request
 *   (GPU work that is already submitted finishes anyway), its result is just not published.
 * - **Latest wins, frames only move forward:** a rendered result is published when it is newer than the
 *   result on screen, was not cancelled, and the session is open; an older result never replaces a newer
 *   one. A superseded result is still shown (2026-10-06): during a continuous ruler drag every finished
 *   render has already been superseded, and publishing only the latest requested revision left the photo
 *   frozen until the finger stopped. A failure is published only for the latest request.
 * - **cancel(through):** cancels only work whose revision is `<= through`. Newer work is untouched.
 *   (On iOS the first implementation cancelled the shared task, which also killed the newer pending
 *   request; the regression test for that is the first test in RenderSchedulerTest.)
 * - **close():** the session is gone (switch photo / leave). Nothing publishes afterwards, even from
 *   renderer work that ignores cancellation.
 *
 * Export is deliberately not routed through this scheduler: an export must never be coalesced away
 * or dropped by a later preview, so it gets its own single-flight path (core-export, M3).
 *
 * @param renderDispatcher where renders run. In the app this is the single thread that owns the EGL
 *   context. It must dispatch (not run inline, e.g. not `Dispatchers.Unconfined`) because renders are
 *   started while the scheduler's lock is held.
 */
class RenderScheduler<P : Any, R : Any>(
    val sessionId: String,
    private val renderer: PreviewRenderer<P, R>,
    parentScope: CoroutineScope,
    renderDispatcher: CoroutineDispatcher,
    /**
     * Told about a render that FAILED but is not published because a newer request superseded it.
     * Without this such failures vanished: a burst of out-of-memory failures during a Background
     * Save copy left no trace except the runtime's own "Throwing OutOfMemoryError" lines.
     */
    private val onUnpublishedFailure: (RenderRequest<P>, Throwable) -> Unit = { _, _ -> },
    /**
     * Where an interactive render runs while the main lane is busy with a settled one (2026-10-06). A slow initial or
     * settled render (23 s for a first full preview on the CPU emulator) otherwise held every drag frame behind it.
     * null: one lane only (tests that do not exercise this).
     */
    interactiveDispatcher: CoroutineDispatcher? = null,
    /** True for a request from a moving control (a ruler drag, a slider): it may use the interactive lane. */
    private val isInteractive: (P) -> Boolean = { false },
) {
    private class InFlight<P>(val request: RenderRequest<P>, val job: Job)

    private val lock = Any()
    private val scope = CoroutineScope(
        parentScope.coroutineContext + SupervisorJob(parentScope.coroutineContext[Job]) + renderDispatcher,
    )

    // All fields below are guarded by [lock].
    private var lastIssuedRevision = 0L
    private var cancelledThroughRevision = 0L
    private var lastPublishedRevision = 0L
    private var pending: RenderRequest<P>? = null
    private var inFlight: InFlight<P>? = null
    private var interactiveInFlight: InFlight<P>? = null
    private val interactiveScope: CoroutineScope? = interactiveDispatcher?.let {
        CoroutineScope(parentScope.coroutineContext + SupervisorJob(parentScope.coroutineContext[Job]) + it)
    }
    private var closed = false

    private val publishedResult = MutableStateFlow<RenderResult<R>?>(null)

    /** The most recent result that passed the latest-wins gate; `null` until the first one. */
    val published: StateFlow<RenderResult<R>?> = publishedResult.asStateFlow()

    val latestRequestedRevision: Long get() = synchronized(lock) { lastIssuedRevision }

    /**
     * Requests a preview of [payload] and returns its revision. Never suspends: called from the UI
     * thread on every slider step.
     */
    fun submit(payload: P): Long = synchronized(lock) {
        check(!closed) { "RenderScheduler for session $sessionId is closed" }
        lastIssuedRevision += 1
        // Replacing (not queueing) the pending request is what keeps the work bounded.
        pending = RenderRequest(sessionId, lastIssuedRevision, payload)
        dispatchLocked()
        lastIssuedRevision
    }

    /**
     * Cancels every request issued so far and suspends until the render in flight, if any, has
     * EXITED. Cancellation is cooperative: a CPU-bound render that does not check for it runs to its
     * end, and this waits for that. Save copy calls it before allocating its full-resolution buffers,
     * so a preview and the export never hold their large buffers at the same time.
     */
    suspend fun cancelAllAndAwaitIdle() {
        val jobs: List<Job> = synchronized(lock) {
            cancelledThroughRevision = lastIssuedRevision
            pending = null
            listOfNotNull(inFlight?.job, interactiveInFlight?.job)
        }
        jobs.forEach { it.cancelAndJoin() }
    }

    /** Cancels requests with revision `<= through`. Requests newer than [through] keep running. */
    fun cancel(through: Long) {
        val jobsToCancel: List<Job> = synchronized(lock) {
            cancelledThroughRevision = maxOf(cancelledThroughRevision, through)
            if ((pending?.revision ?: Long.MAX_VALUE) <= through) pending = null
            listOfNotNull(inFlight?.takeIf { it.request.revision <= through }?.job, interactiveInFlight?.takeIf { it.request.revision <= through }?.job)
        }
        // Outside the lock: a job that has not started yet completes synchronously inside cancel(),
        // and its completion handler takes the lock to start the (newer) pending request.
        jobsToCancel.forEach { it.cancel(CancellationException("Render cancelled through revision $through")) }
    }

    /** Ends the session: drops pending work, cancels the in-flight render, publishes nothing more. */
    fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            pending = null
        }
        scope.cancel(CancellationException("Render session $sessionId closed"))
        interactiveScope?.cancel(CancellationException("Render session $sessionId closed"))
    }

    /**
     * Starts the pending request if a lane is free. The main lane takes anything. An interactive request whose main
     * lane is busy with a settled render starts at once on the interactive lane, and the settled render is cancelled:
     * its result is older than the frames now asked for (cooperative: work that ignores cancellation finishes, and its
     * older result is then not published over a newer one).
     */
    private fun dispatchLocked() {
        val request = pending ?: return
        val running = inFlight
        if (running == null) {
            startLocked(request, interactiveLane = false)
        } else if (interactiveScope != null && interactiveInFlight == null && isInteractive(request.payload) && !isInteractive(running.request.payload)) {
            running.job.cancel(CancellationException("Settled render ${running.request.revision} superseded by an interactive request"))
            startLocked(request, interactiveLane = true)
        }
    }

    private fun startLocked(request: RenderRequest<P>, interactiveLane: Boolean) {
        pending = null
        val laneScope = if (interactiveLane) interactiveScope!! else scope
        // LAZY so the in-flight slot is recorded before the job can possibly complete.
        val job = laneScope.launch(start = CoroutineStart.LAZY) { renderAndMaybePublish(request) }
        if (interactiveLane) interactiveInFlight = InFlight(request, job) else inFlight = InFlight(request, job)
        // invokeOnCompletion (rather than a finally block) also fires for a job cancelled before it
        // ever ran, which would otherwise leave the in-flight slot occupied forever.
        job.invokeOnCompletion { onRenderCompleted(job) }
        job.start()
    }

    private fun onRenderCompleted(job: Job) = synchronized(lock) {
        when {
            inFlight?.job === job -> inFlight = null
            interactiveInFlight?.job === job -> interactiveInFlight = null
            else -> return@synchronized
        }
        if (!closed) dispatchLocked()
    }

    private suspend fun renderAndMaybePublish(request: RenderRequest<P>) {
        val outcome: RenderOutcome<R> = try {
            RenderOutcome.Rendered(renderer.render(request))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            RenderOutcome.Failed(failure)
        }
        val published = synchronized(lock) {
            isPublishableLocked(request, outcome).also { publishable ->
                if (publishable) {
                    publishedResult.value = RenderResult(request.sessionId, request.revision, outcome)
                    lastPublishedRevision = request.revision
                }
            }
        }
        if (!published && outcome is RenderOutcome.Failed) onUnpublishedFailure(request, outcome.error)
    }

    private fun isPublishableLocked(request: RenderRequest<P>, outcome: RenderOutcome<R>): Boolean =
        !closed &&
            request.sessionId == sessionId &&
            request.revision > cancelledThroughRevision &&
            request.revision > lastPublishedRevision &&
            (outcome is RenderOutcome.Rendered || request.revision == lastIssuedRevision)
}
