package com.lightlylabs.lightly.export

import com.lightlylabs.lightly.render.gpu.TilePlan
import com.lightlylabs.lightly.render.image.FrameSource
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.image.asFrameSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext

/** Full-resolution, oriented, sRGB decode of the Original (spec §5.4 step 2). */
fun interface FullResolutionSource {
    suspend fun decode(): Rgba8Image

    /**
     * The decode as a frame read by region; Save copy uses this. The default holds [decode]'s image; the Android loader
     * keeps the frame in a native Bitmap instead (48 MP: no 192 MB Java array).
     */
    suspend fun decodeFrame(): FrameSource = decode().asFrameSource()
}

/**
 * Everything one Save copy needs, captured at tap time (spec §5.4 step 1). The plan is built from
 * the committed EditState, so later previews or commits cannot change what this export renders.
 */
class ExportJob<H>(
    val sourceHandle: H,
    val original: FullResolutionSource,
    val plan: ExportRenderPlan,
    val spec: NewImageSpec,
)

sealed interface ExportState<out H> {
    data object Idle : ExportState<Nothing>
    data class Running(val exportId: Long, val phase: Phase) : ExportState<Nothing>
    data class Saved<H>(val exportId: Long, val newAsset: H) : ExportState<H>
    data class Failed(val exportId: Long, val error: Throwable) : ExportState<Nothing>
    data class Cancelled(val exportId: Long) : ExportState<Nothing>

    enum class Phase { DECODING, RENDERING, ENCODING_AND_WRITING }
}

sealed interface ExportStart {
    data class Started(val exportId: Long) : ExportStart

    /** One export at a time: Save copy is disabled while this is returned. Nothing is queued. */
    data object AlreadyRunning : ExportStart
}

/**
 * The export path, deliberately separate from the preview [RenderScheduler][com.lightlylabs.lightly.render.schedule.RenderScheduler]:
 * previews are latest-wins and may be coalesced or dropped, an export never is. It runs in its own
 * job (not a child of the preview scheduler or of the session), so preview submits, preview
 * cancellation and closing the preview session cannot touch it.
 *
 * Flow: decode full resolution → render through [TilePlan] tiles with the job's [ExportRenderPlan],
 * the same operators as previews (Invariant P=E) → [SaveCopyExporter.save], which inserts the pending row, encodes once and
 * publishes. Cancel is honoured until encoding starts; encode + write run NonCancellable so a
 * cancel can never leave a partial asset (spec §5.4 step 8). A cancelled export never creates a
 * MediaStore row, because the row is inserted only after rendering finished.
 *
 * @param renderDispatcher the thread that owns the GL context (the same one previews use), so GL
 *   calls stay on their owner thread. Exports and previews interleave on it between tiles.
 */
class ExportCoordinator<H, F : ExportFrame>(
    private val saver: SaveCopyExporter<H, F>,
    private val frameFactory: ExportFrameFactory<F>,
    renderDispatcher: CoroutineDispatcher,
    maxTileEdge: Int = TilePlan.SPEC_MAX_TILE_EDGE,
    /** Exposed for tests of the documented buffer budget. */
    val ledger: ExportBufferLedger = ExportBufferLedger(),
) {
    private val tiledRenderer = TiledExportRenderer(maxTileEdge, ledger)
    private val scope = CoroutineScope(SupervisorJob() + renderDispatcher)
    private val lock = Any()

    private class Slot(val exportId: Long, val job: Job)

    // Guarded by [lock]. Occupied from start() until the export's Job has COMPLETED, not merely
    // until it is cancelled: `Job.isActive` turns false at cancel() while a NonCancellable write is
    // still running, and treating that as "free" let a second save start (Codex M2 review).
    private var slot: Slot? = null
    private var nextExportId = 0L

    private val stateFlow = MutableStateFlow<ExportState<H>>(ExportState.Idle)
    val state: StateFlow<ExportState<H>> = stateFlow.asStateFlow()

    fun start(job: ExportJob<H>): ExportStart = synchronized(lock) {
        if (slot != null) return ExportStart.AlreadyRunning
        val exportId = ++nextExportId
        stateFlow.value = ExportState.Running(exportId, ExportState.Phase.DECODING)
        // LAZY so the slot and the completion handler exist before the body can run or complete.
        val exportJob = scope.launch(start = CoroutineStart.LAZY) { runExport(exportId, job) }
        slot = Slot(exportId, exportJob)
        exportJob.invokeOnCompletion { cause -> onExportCompleted(exportId, cause) }
        exportJob.start()
        ExportStart.Started(exportId)
    }

    /** Cancels the running export if it has not started encoding; otherwise it completes. */
    fun cancel() {
        synchronized(lock) { slot?.job }?.cancel(CancellationException("Export cancelled by the user"))
    }

    /**
     * Runs after the export's Job has fully completed, including a NonCancellable write. Covers a
     * Job cancelled before its body ever ran (no catch block executes then), which previously left
     * the state stuck at DECODING. Only then is the slot released.
     */
    private fun onExportCompleted(exportId: Long, cause: Throwable?) = synchronized(lock) {
        if (slot?.exportId != exportId) return@synchronized
        val current = stateFlow.value
        if (current is ExportState.Running && current.exportId == exportId) {
            stateFlow.value = if (cause == null || cause is CancellationException) {
                ExportState.Cancelled(exportId)
            } else {
                ExportState.Failed(exportId, cause)
            }
        }
        slot = null
    }

    /** State writes are accepted only from the export that owns the slot (export-ID guard). */
    private fun publish(exportId: Long, newState: ExportState<H>) = synchronized(lock) {
        if (slot?.exportId == exportId) stateFlow.value = newState
    }

    private suspend fun runExport(exportId: Long, job: ExportJob<H>) {
        try {
            val saved = renderThenSave(exportId, job)
            // A cancel that arrived during the write does not undo it: the asset exists, so report it.
            publish(exportId, ExportState.Saved(exportId, saved))
        } catch (cancelled: CancellationException) {
            publish(exportId, ExportState.Cancelled(exportId))
        } catch (failure: Throwable) {
            publish(exportId, ExportState.Failed(exportId, failure))
        }
    }

    /**
     * Holds at most two full-frame buffers (decoded source + encode target) and releases the source
     * before encoding; see [ExportBufferLedger] for the budget.
     */
    private suspend fun renderThenSave(exportId: Long, job: ExportJob<H>): H {
        var source: FrameSource? = job.original.decodeFrame()
        val frameBytes = ExportBufferLedger.rgba8Bytes(source!!.width, source.height)
        ledger.acquire(ExportBufferLedger.Kind.FULL_FRAME, frameBytes)
        var sourceHeld = true
        try {
            publish(exportId, ExportState.Running(exportId, ExportState.Phase.RENDERING))
            val tileRenderer = job.plan.prepare(source)
            // The output may differ from the source in size (Edit › geometry); never larger than the source.
            val (width, height) = tileRenderer.outputSize(source)
            val targetBytes = ExportBufferLedger.rgba8Bytes(width, height)
            val target = frameFactory.allocate(width, height)
            ledger.acquire(ExportBufferLedger.Kind.FULL_FRAME, targetBytes)
            try {
                tiledRenderer.render(source, tileRenderer, target)
                // Drop the source before encoding so the encoder runs with one full frame live.
                source.close()
                source = null
                ledger.release(ExportBufferLedger.Kind.FULL_FRAME, frameBytes)
                sourceHeld = false
                coroutineContext.ensureActive() // last cancellation point before anything is written
                publish(exportId, ExportState.Running(exportId, ExportState.Phase.ENCODING_AND_WRITING))
                return withContext(NonCancellable) { saver.save(job.sourceHandle, job.spec, target) }
            } finally {
                ledger.release(ExportBufferLedger.Kind.FULL_FRAME, targetBytes)
            }
        } finally {
            if (sourceHeld) {
                source?.close()
                ledger.release(ExportBufferLedger.Kind.FULL_FRAME, frameBytes)
            }
        }
    }
}
