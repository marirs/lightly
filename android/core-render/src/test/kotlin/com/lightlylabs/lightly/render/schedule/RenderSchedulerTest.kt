package com.lightlylabs.lightly.render.schedule

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Virtual-time tests for spec §5.2 (one in-flight + one conflated pending slot, latest wins) and
 * §10 "Concurrency tests". The first test is the regression for the iOS defect where cancelling
 * through an old revision also killed the newer pending request.
 */
@OptIn(ExperimentalCoroutinesApi::class) // virtual-time controls (runCurrent, advanceTimeBy, UnconfinedTestDispatcher)
class RenderSchedulerTest {

    /** A renderer that takes [renderMillis] of virtual time and records every revision it starts/finishes. */
    private class SlowFakeRenderer(
        private val renderMillis: Long = 100,
        private val ignoresCancellation: Boolean = false,
        private val failingPayloads: Set<String> = emptySet(),
    ) : PreviewRenderer<String, String> {
        val started = mutableListOf<Long>()
        val finished = mutableListOf<Long>()

        override suspend fun render(request: RenderRequest<String>): String {
            started += request.revision
            if (ignoresCancellation) {
                // Models GPU work that was already submitted: it runs to completion regardless (§5.2).
                withContext(NonCancellable) { delay(renderMillis) }
            } else {
                delay(renderMillis)
            }
            if (request.payload in failingPayloads) error("renderer failed on ${request.payload}")
            finished += request.revision
            return "rendered:${request.payload}"
        }
    }

    private class Harness(testScope: TestScope, val renderer: SlowFakeRenderer, sessionId: String = "session-A") {
        val scheduler = RenderScheduler(
            sessionId = sessionId,
            renderer = renderer,
            // Not backgroundScope: advanceUntilIdle() ignores background work, so renders there would
            // never advance. A detached scope on the test scheduler runs in virtual time.
            parentScope = CoroutineScope(Job()),
            renderDispatcher = StandardTestDispatcher(testScope.testScheduler),
        )
        val publishedHistory = mutableListOf<RenderResult<String>>()

        init {
            // Unconfined collector sees every StateFlow emission in order, so "never published" is checkable.
            testScope.backgroundScope.launch(UnconfinedTestDispatcher(testScope.testScheduler)) {
                scheduler.published.collect { result -> if (result != null) publishedHistory += result }
            }
        }
    }

    private fun TestScope.harness(renderer: SlowFakeRenderer = SlowFakeRenderer()) = Harness(this, renderer)

    // --- Written first: regression for the iOS cancel(through:) defect -------------------------

    @Test
    fun `cancel through revision 1 leaves revision 2 alive and published`() = runTest {
        val h = harness()
        val first = h.scheduler.submit("one")
        runCurrent() // revision 1 is now rendering
        val second = h.scheduler.submit("two") // revision 2 waits in the pending slot

        h.scheduler.cancel(through = first)
        advanceUntilIdle()

        assertEquals(listOf(1L, 2L), listOf(first, second))
        assertEquals(listOf(1L, 2L), h.renderer.started)
        assertEquals(listOf(2L), h.renderer.finished, "revision 1 was cancelled mid-render")
        assertEquals(listOf(RenderResult("session-A", 2L, RenderOutcome.Rendered("rendered:two"))), h.publishedHistory)
    }

    @Test
    fun `cancel through 1 does not cancel revision 2 when 2 is already in flight`() = runTest {
        val h = harness()
        h.scheduler.submit("one")
        advanceUntilIdle() // revision 1 completes and publishes
        val second = h.scheduler.submit("two")
        runCurrent() // revision 2 in flight

        h.scheduler.cancel(through = 1)
        advanceUntilIdle()

        assertEquals(listOf(1L, 2L), h.publishedHistory.map { it.revision })
        assertEquals(second, h.publishedHistory.last().revision)
    }

    @Test
    fun `cancel through the latest revision drops both slots and publishes nothing`() = runTest {
        val h = harness()
        h.scheduler.submit("one")
        runCurrent()
        val second = h.scheduler.submit("two")

        h.scheduler.cancel(through = second)
        advanceUntilIdle()

        assertTrue(h.publishedHistory.isEmpty())
        assertEquals(listOf(1L), h.renderer.started, "the pending revision 2 must never start")

        // The scheduler is still usable after a cancel.
        h.scheduler.submit("three")
        advanceUntilIdle()
        assertEquals(listOf(3L), h.publishedHistory.map { it.revision })
    }

    @Test
    fun `cancel through a revision is honoured even if the renderer ignores cancellation`() = runTest {
        val h = harness(SlowFakeRenderer(ignoresCancellation = true))
        val first = h.scheduler.submit("one")
        runCurrent()

        h.scheduler.cancel(through = first)
        advanceUntilIdle()

        assertEquals(listOf(1L), h.renderer.finished, "submitted GPU work finishes")
        assertTrue(h.publishedHistory.isEmpty(), "but its result is discarded")
    }

    // --- Latest wins / bounded work --------------------------------------------------------------

    @Test
    fun `N rapid requests render at most twice and publish in order, ending on the last`() = runTest {
        val h = harness()

        val revisions = (1..20).map { index -> h.scheduler.submit("drag-$index") }
        advanceUntilIdle()

        assertEquals((1L..20L).toList(), revisions, "revisions increase monotonically")
        assertTrue(h.renderer.started.size <= 2, "rendered ${h.renderer.started}")
        // The first render (already running) is shown when it lands, then the last request; nothing in between.
        assertEquals(listOf(1L, 20L), h.publishedHistory.map { it.revision })
        assertEquals(RenderOutcome.Rendered("rendered:drag-20"), h.publishedHistory.last().outcome)
    }

    @Test
    fun `a slider drag spread over time keeps one pending slot and ends on the last value`() = runTest {
        val h = harness(SlowFakeRenderer(renderMillis = 100))

        // 50 requests 10 ms apart against a 100 ms renderer: 500 ms of input.
        repeat(50) { index ->
            h.scheduler.submit("stop-$index")
            advanceTimeBy(10)
        }
        advanceUntilIdle()

        // At most one render per 100 ms window plus the trailing one, far fewer than the 50 requests.
        assertTrue(h.renderer.started.size <= 7, "rendered ${h.renderer.started.size} times")
        assertEquals("rendered:stop-49", (h.publishedHistory.last().outcome as RenderOutcome.Rendered).value)
        // Every published result was the latest at the moment it was published, so revisions only go up.
        val publishedRevisions = h.publishedHistory.map { it.revision }
        assertEquals(publishedRevisions.sorted().distinct(), publishedRevisions)
    }

    @Test
    fun `a superseded result newer than the screen is shown, then the latest`() = runTest {
        val h = harness()
        h.scheduler.submit("old")
        runCurrent()
        h.scheduler.submit("new")

        advanceTimeBy(101) // "old" has finished; "new" just started
        runCurrent()
        assertEquals(listOf(1L), h.publishedHistory.map { it.revision }, "a continuous drag shows each finished frame")

        advanceUntilIdle()
        assertEquals(listOf(1L, 2L), h.publishedHistory.map { it.revision })
    }

    @Test
    fun `an older result never replaces a newer one on screen`() = runTest {
        // Revision 1 ignores cancellation and finishes after revision 2 was published (cancelled through 1 meanwhile
        // is the normal path; here a slow renderer makes 1 finish last without any cancel).
        val h = harness(SlowFakeRenderer(renderMillis = 100))
        h.scheduler.submit("a"); runCurrent()
        h.scheduler.submit("b")
        advanceUntilIdle()
        val revisions = h.publishedHistory.map { it.revision }
        assertEquals(revisions.sorted().distinct(), revisions, "published revisions only increase")
    }

    // --- Session lifetime ------------------------------------------------------------------------

    @Test
    fun `closing the session publishes nothing afterwards`() = runTest {
        val h = harness()
        h.scheduler.submit("one")
        runCurrent()
        h.scheduler.submit("two")

        h.scheduler.close()
        advanceUntilIdle()

        assertTrue(h.publishedHistory.isEmpty())
        assertEquals(listOf(1L), h.renderer.started)
        assertFailsWith<IllegalStateException> { h.scheduler.submit("after close") }
    }

    @Test
    fun `closing drops a result from work that ignores cancellation`() = runTest {
        val h = harness(SlowFakeRenderer(ignoresCancellation = true))
        h.scheduler.submit("one")
        runCurrent()

        h.scheduler.close()
        advanceUntilIdle()

        assertEquals(listOf(1L), h.renderer.finished)
        assertTrue(h.publishedHistory.isEmpty())
    }

    @Test
    fun `results carry the scheduler's session id`() = runTest {
        val h = Harness(this, SlowFakeRenderer(), sessionId = "photo-2")
        h.scheduler.submit("x")
        advanceUntilIdle()

        assertEquals("photo-2", h.publishedHistory.single().sessionId)
    }

    // --- Failures --------------------------------------------------------------------------------

    @Test
    fun `a failure of the latest request is published as Failed`() = runTest {
        val h = harness(SlowFakeRenderer(failingPayloads = setOf("bad")))
        h.scheduler.submit("bad")
        advanceUntilIdle()

        val outcome = h.publishedHistory.single().outcome
        assertIs<RenderOutcome.Failed>(outcome)
    }

    @Test
    fun `a failure of a stale request is dropped and the next request still runs`() = runTest {
        val h = harness(SlowFakeRenderer(failingPayloads = setOf("bad")))
        h.scheduler.submit("bad")
        runCurrent()
        h.scheduler.submit("good")
        advanceUntilIdle()

        assertEquals(listOf(RenderResult("session-A", 2L, RenderOutcome.Rendered("rendered:good"))), h.publishedHistory)
    }

    @Test
    fun `nothing is published before the first request completes`() = runTest {
        val h = harness()
        assertNull(h.scheduler.published.value)
        h.scheduler.submit("one")
        runCurrent()
        assertNull(h.scheduler.published.value)
        advanceUntilIdle()
        assertEquals(1L, h.scheduler.published.value?.revision)
    }

    // --- Starvation (2026-10-06) -----------------------------------------------------------------------

    /** Settled renders take 3 s (ignoring cancellation, like CPU work); drag frames ("drag-*") take 100 ms. */
    private class MixedRenderer : PreviewRenderer<String, String> {
        val finished = mutableListOf<String>()
        override suspend fun render(request: RenderRequest<String>): String {
            withContext(NonCancellable) { delay(if (request.payload.startsWith("drag")) 100 else 3_000) }
            finished += request.payload
            return "rendered:${request.payload}"
        }
    }

    @Test
    fun `a long settled render does not hold up drag frames, and its late result never replaces them`() = runTest {
        val renderer = MixedRenderer()
        val scheduler = RenderScheduler(
            sessionId = "session-A", renderer = renderer, parentScope = CoroutineScope(Job()),
            renderDispatcher = StandardTestDispatcher(testScheduler),
            interactiveDispatcher = StandardTestDispatcher(testScheduler),
            isInteractive = { it.startsWith("drag") },
        )
        val published = mutableListOf<Pair<Long, String>>()
        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            scheduler.published.collect { r -> if (r != null) published += currentTime to ((r.outcome as RenderOutcome.Rendered).value) }
        }
        scheduler.submit("initial-full")
        advanceTimeBy(200)
        // The finger moves: a new stop every 50 ms for 1 s, then reverses for 0.5 s, while the initial render runs on.
        val dragStart = currentTime
        repeat(20) { i -> scheduler.submit("drag-$i"); advanceTimeBy(50) }
        repeat(10) { i -> scheduler.submit("drag-back-${19 - i}"); advanceTimeBy(50) }
        advanceUntilIdle()

        val firstDrag = published.first { it.second.contains("drag") }
        assertTrue(firstDrag.first - dragStart <= 150, "first drag frame visible after ${firstDrag.first - dragStart} ms")
        val dragFrames = published.count { it.second.contains("drag") }
        assertTrue(dragFrames >= 8, "frames keep appearing during the movement ($dragFrames)")
        assertEquals("rendered:drag-back-10", published.last().second, "the latest selection is what stays on screen")
        assertTrue(published.none { it.second == "rendered:initial-full" }, "the older settled result never replaces newer frames")
    }
}
