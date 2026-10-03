package com.lightlylabs.lightly.export

import com.lightlylabs.lightly.render.gpu.Tile
import com.lightlylabs.lightly.render.gpu.TileCopy
import com.lightlylabs.lightly.render.gpu.TilePlan
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.lut.LutPassPlan
import com.lightlylabs.lightly.render.lut.LutPassRenderer
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.yield
import kotlin.coroutines.coroutineContext

/**
 * The buffer the export is rendered into AND the one the encoder reads. Tiles are written straight
 * into it, so there is no separate "rendered frame" copy between render and encode. On Android this
 * is an ARGB_8888 sRGB Bitmap ([BitmapExportFrame]); on the JVM an RGBA8 byte frame.
 */
interface ExportFrame {
    val width: Int
    val height: Int

    fun writeTile(tile: Tile, pixels: Rgba8Image)
}

fun interface ExportFrameFactory<F : ExportFrame> {
    fun allocate(width: Int, height: Int): F
}

/** JVM frame (tests, and any encoder that takes RGBA bytes). */
class Rgba8ExportFrame(override val width: Int, override val height: Int) : ExportFrame {
    val pixels = ByteArray(width * height * Rgba8Image.CHANNELS)

    override fun writeTile(tile: Tile, pixels: Rgba8Image) = TileCopy.insert(this.pixels, width, tile, pixels)

    fun toImage(): Rgba8Image = Rgba8Image(width, height, pixels)

    companion object {
        val factory = ExportFrameFactory { width, height -> Rgba8ExportFrame(width, height) }
    }
}

/**
 * Records the pipeline's own large buffers so the memory budget is testable on the JVM.
 *
 * Documented budget for one export (spec §5.3: ≤ 600 MB at 48 MP on 8 GB Android devices):
 * - full-frame buffers live at once: at most [MAX_FULL_FRAMES] = 2 (the decoded source and the
 *   encode target). The source is released before encoding starts, so encoding holds 1.
 * - tile buffers live at once: at most [MAX_TILE_BUFFERS] = 2 (the extracted input tile and the
 *   rendered output tile), each ≤ 4096² × 4 B = 64 MiB.
 * At 48 MP (8064×6048, 195 MB per RGBA8 frame) that is ≈ 390 MB + 128 MiB ≈ 524 MB, before the
 * renderer's internal GL buffers and the JPEG encoder's working memory. Real peaks are PENDING
 * device measurement.
 */
class ExportBufferLedger {
    enum class Kind { FULL_FRAME, TILE }

    private val live = mutableMapOf(Kind.FULL_FRAME to 0, Kind.TILE to 0)
    private val peak = mutableMapOf(Kind.FULL_FRAME to 0, Kind.TILE to 0)
    private var liveBytes = 0L
    var peakBytes = 0L
        private set

    fun acquire(kind: Kind, bytes: Long) = synchronized(this) {
        live[kind] = live.getValue(kind) + 1
        peak[kind] = maxOf(peak.getValue(kind), live.getValue(kind))
        liveBytes += bytes
        peakBytes = maxOf(peakBytes, liveBytes)
    }

    fun release(kind: Kind, bytes: Long) = synchronized(this) {
        check(live.getValue(kind) > 0) { "release of $kind without acquire" }
        live[kind] = live.getValue(kind) - 1
        liveBytes -= bytes
    }

    fun peakCount(kind: Kind): Int = synchronized(this) { peak.getValue(kind) }
    fun liveCount(kind: Kind): Int = synchronized(this) { live.getValue(kind) }

    companion object {
        const val MAX_FULL_FRAMES = 2
        const val MAX_TILE_BUFFERS = 2

        fun rgba8Bytes(width: Int, height: Int): Long = width.toLong() * height * Rgba8Image.CHANNELS

        /** Upper bound of the pipeline's own buffers for a frame, per the budget above. */
        fun budgetBytes(width: Int, height: Int, maxTileEdge: Int = TilePlan.SPEC_MAX_TILE_EDGE): Long {
            val edge = minOf(maxTileEdge, TilePlan.SPEC_MAX_TILE_EDGE)
            val tileBytes = rgba8Bytes(minOf(edge, width), minOf(edge, height))
            return MAX_FULL_FRAMES * rgba8Bytes(width, height) + MAX_TILE_BUFFERS * tileBytes
        }
    }
}

/**
 * What one export renders. [prepare] is called once with the decoded full frame (so a plan can compute
 * per-frame context, such as clarity's low-resolution base), then the returned renderer is asked for
 * each tile. A tile renderer reads whatever neighbourhood (apron) it needs from the full frame itself.
 */
fun interface ExportRenderPlan {
    fun prepare(frame: Rgba8Image): ExportTileRenderer
}

fun interface ExportTileRenderer {
    /** The finished pixels of [tile], exactly tile-sized. */
    fun renderTile(frame: Rgba8Image, tile: Tile): Rgba8Image
}

/** The per-pixel LUT-pass plan of M2: tiles need no apron. */
class LutPassExportPlan(private val renderer: LutPassRenderer, val plan: LutPassPlan) : ExportRenderPlan {
    override fun prepare(frame: Rgba8Image) = ExportTileRenderer { source, tile -> renderer.render(TileCopy.extract(source, tile), plan) }
}

/**
 * Full-resolution tiled render (spec §5.3): tiles ≤ min(device limit, 4096)², each rendered by the
 * job's [ExportRenderPlan] and written straight into the encode target.
 *
 * Memory: the plan's own working buffers for a tile (its apron and float planes) are bounded by the
 * tile edge, which is why the app exports Develop recipes with spatial operators in 1024² tiles.
 */
class TiledExportRenderer(
    private val maxTileEdge: Int = TilePlan.SPEC_MAX_TILE_EDGE,
    private val ledger: ExportBufferLedger = ExportBufferLedger(),
) {
    suspend fun render(source: Rgba8Image, plan: ExportRenderPlan, target: ExportFrame) {
        require(target.width == source.width && target.height == source.height) { "Target frame does not match the source" }
        val tileRenderer = plan.prepare(source)
        for (tile in TilePlan.plan(source.width, source.height, maxTileEdge).tiles) {
            coroutineContext.ensureActive() // cancel is honoured between tiles, before encoding
            val tileBytes = ExportBufferLedger.rgba8Bytes(tile.width, tile.height)
            ledger.acquire(ExportBufferLedger.Kind.TILE, tileBytes) // the plan's working tile (input/apron)
            ledger.acquire(ExportBufferLedger.Kind.TILE, tileBytes) // the rendered output tile
            val rendered = tileRenderer.renderTile(source, tile)
            ledger.release(ExportBufferLedger.Kind.TILE, tileBytes)
            target.writeTile(tile, rendered)
            ledger.release(ExportBufferLedger.Kind.TILE, tileBytes)
            yield() // let preview renders queued on the shared render thread interleave between tiles
        }
    }
}
