package com.lightlylabs.lightly.export

import com.lightlylabs.lightly.render.gpu.TileCopy
import com.lightlylabs.lightly.render.gpu.TilePlan
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.lut.LutPassPlan
import com.lightlylabs.lightly.render.lut.LutPassRenderer
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import kotlin.coroutines.coroutineContext

/** Full-resolution, oriented, sRGB decode of the Original (spec §5.4 step 2). */
fun interface FullResolutionSource {
    suspend fun decode(): Rgba8Image
}

/**
 * Everything one Save copy needs, captured at tap time (spec §5.4 step 1). The plan is built from
 * the committed EditState, so later previews or commits cannot change what this export renders.
 */
class ExportJob<H>(
    val sourceHandle: H,
    val original: FullResolutionSource,
    val plan: LutPassPlan,
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
 * Flow: decode full resolution → render through [TilePlan] tiles with the same [LutPassRenderer] as
 * previews (Invariant P=E) → [SaveCopyExporter.save], which inserts the pending row, encodes once and
 * publishes. Cancel is honoured until encoding starts; encode + write run NonCancellable so a
 * cancel can never leave a partial asset (spec §5.4 step 8). A cancelled export never creates a
 * MediaStore row, because the row is inserted only after rendering finished.
 *
 * @param renderDispatcher the thread that owns the GL context (the same one previews use), so GL
 *   calls stay on their owner thread. Exports and previews interleave on it between tiles.
 */
class ExportCoordinator<H>(
    private val renderer: LutPassRenderer,
    private val saver: SaveCopyExporter<H, Rgba8Image>,
    renderDispatcher: CoroutineDispatcher,
    private val maxTileEdge: Int = TilePlan.SPEC_MAX_TILE_EDGE,
) {
    private val scope = CoroutineScope(SupervisorJob() + renderDispatcher)
    private val lock = Any()
    private var running: Job? = null
    private var nextExportId = 0L

    private val stateFlow = MutableStateFlow<ExportState<H>>(ExportState.Idle)
    val state: StateFlow<ExportState<H>> = stateFlow.asStateFlow()

    fun start(job: ExportJob<H>): ExportStart = synchronized(lock) {
        if (running?.isActive == true) return ExportStart.AlreadyRunning
        val exportId = ++nextExportId
        stateFlow.value = ExportState.Running(exportId, ExportState.Phase.DECODING)
        running = scope.launch { runExport(exportId, job) }
        ExportStart.Started(exportId)
    }

    /** Cancels the running export if it has not started encoding; otherwise it completes. */
    fun cancel() {
        synchronized(lock) { running }?.cancel(CancellationException("Export cancelled by the user"))
    }

    private suspend fun runExport(exportId: Long, job: ExportJob<H>) {
        try {
            val original = job.original.decode()
            stateFlow.value = ExportState.Running(exportId, ExportState.Phase.RENDERING)
            val rendered = renderTiled(original, job.plan)
            coroutineContext.ensureActive() // last cancellation point before anything is written
            stateFlow.value = ExportState.Running(exportId, ExportState.Phase.ENCODING_AND_WRITING)
            val saved = withContext(NonCancellable) { saver.save(job.sourceHandle, job.spec, rendered) }
            stateFlow.value = ExportState.Saved(exportId, saved)
        } catch (cancelled: CancellationException) {
            stateFlow.value = ExportState.Cancelled(exportId)
        } catch (failure: Throwable) {
            stateFlow.value = ExportState.Failed(exportId, failure)
        }
    }

    /** Tile by tile so a 48 MP export never needs one huge GPU texture, with a cancel check per tile. */
    private suspend fun renderTiled(original: Rgba8Image, plan: LutPassPlan): Rgba8Image {
        val tiles = TilePlan.plan(original.width, original.height, maxTileEdge)
        val output = ByteArray(original.pixels.size)
        for (tile in tiles.tiles) {
            coroutineContext.ensureActive()
            TileCopy.insert(output, original.width, tile, renderer.render(TileCopy.extract(original, tile), plan))
            yield() // let queued preview renders on the shared GL thread interleave between tiles
        }
        return Rgba8Image(original.width, original.height, output)
    }
}
