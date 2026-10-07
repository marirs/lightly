package com.lightlylabs.lightly.export

import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.image.asFrameSource
import com.lightlylabs.lightly.render.lut.CpuLutPassRenderer
import com.lightlylabs.lightly.render.lut.Lut3D
import com.lightlylabs.lightly.render.lut.LutPassPlan
import com.lightlylabs.lightly.render.lut.LutPassRenderer
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import java.io.OutputStream
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** Full-resolution tiled render (spec §5.3): seams, buffer accounting, and the 48 MP budget arithmetic. */
@OptIn(ExperimentalCoroutinesApi::class)
class TiledExportTest {

    private val source = Rgba8Image(300, 211, ByteArray(300 * 211 * 4).also { Random(21).nextBytes(it) })

    // Two passes with an out-of-range Auto, so clamping at each stage is exercised across seams.
    private val plan = run {
        val identity = Lut3D.identity()
        val auto = Lut3D(33, FloatArray(identity.rgba.size) { i -> if (i % 4 == 3) 1f else identity.rgba[i] * 1.35f - 0.12f })
        val look = Lut3D(33, FloatArray(identity.rgba.size) { i -> if (i % 4 == 3) 1f else identity.rgba[i] * identity.rgba[i] })
        LutPassPlan.of(auto, 0.8f, look, 0.9f)
    }

    @Test
    fun `tile boundary pixels are identical to an untiled render`() = runTest {
        val frame = Rgba8ExportFrame(source.width, source.height)
        TiledExportRenderer(maxTileEdge = 64).render(source.asFrameSource(), LutPassExportPlan(CpuLutPassRenderer, plan), frame)

        val untiled = CpuLutPassRenderer.render(source, plan).pixels
        // Explicitly the seam rows/columns on both sides of every tile boundary, then everything.
        for (boundary in listOf(63, 64, 127, 128, 191, 192, 255, 256)) {
            for (y in 0 until source.height) assertPixelEqual(untiled, frame.pixels, boundary.coerceAtMost(source.width - 1), y)
            if (boundary < source.height) for (x in 0 until source.width) assertPixelEqual(untiled, frame.pixels, x, boundary)
        }
        assertContentEquals(untiled, frame.pixels)
    }

    private fun assertPixelEqual(expected: ByteArray, actual: ByteArray, x: Int, y: Int) {
        val base = (y * source.width + x) * 4
        assertContentEquals(expected.copyOfRange(base, base + 4), actual.copyOfRange(base, base + 4), "pixel ($x,$y)")
    }

    @Test
    fun `export holds at most two full frames and two tile buffers, and one frame while encoding`() = runTest {
        val gateway = object : MediaStoreGateway<String> {
            override fun insertPending(spec: NewImageSpec) = "content://media/new/1"
            override fun openForWrite(handle: String): OutputStream = OutputStream.nullOutputStream()
            override fun publish(handle: String) = true
            override fun delete(handle: String) = Unit
        }
        val ledger = ExportBufferLedger()
        var fullFramesLiveDuringEncode = -1
        val encoder = JpegEncoder<Rgba8ExportFrame> { _, _, _ -> fullFramesLiveDuringEncode = ledger.liveCount(ExportBufferLedger.Kind.FULL_FRAME) }
        val coordinator = ExportCoordinator(SaveCopyExporter(gateway, encoder), Rgba8ExportFrame.factory,
            StandardTestDispatcher(testScheduler), maxTileEdge = 64, ledger = ledger,
        )

        coordinator.start(ExportJob("content://media/original/1", { source }, LutPassExportPlan(CpuLutPassRenderer, plan), NewImageSpec("x.jpg")))
        advanceUntilIdle()

        assertIs<ExportState.Saved<String>>(coordinator.state.value)
        assertEquals(ExportBufferLedger.MAX_FULL_FRAMES, ledger.peakCount(ExportBufferLedger.Kind.FULL_FRAME))
        assertTrue(ledger.peakCount(ExportBufferLedger.Kind.TILE) <= ExportBufferLedger.MAX_TILE_BUFFERS)
        assertEquals(1, fullFramesLiveDuringEncode, "the decoded source is released before encoding")
        assertEquals(0, ledger.liveCount(ExportBufferLedger.Kind.FULL_FRAME))
        assertEquals(0, ledger.liveCount(ExportBufferLedger.Kind.TILE))
        assertTrue(ledger.peakBytes <= ExportBufferLedger.budgetBytes(source.width, source.height, maxTileEdge = 64))
    }

    @Test
    fun `buffers are released when an export is cancelled mid-render`() = runTest {
        val ledger = ExportBufferLedger()
        val failingGateway = object : MediaStoreGateway<String> {
            override fun insertPending(spec: NewImageSpec) = error("must not be reached")
            override fun openForWrite(handle: String): OutputStream = error("must not be reached")
            override fun publish(handle: String) = false
            override fun delete(handle: String) = Unit
        }
        lateinit var coordinator: ExportCoordinator<String, Rgba8ExportFrame>
        var tilesRendered = 0
        // The user cancels while the third tile is rendering.
        val cancellingRenderer = object : LutPassRenderer {
            override fun render(source: Rgba8Image, plan: LutPassPlan): Rgba8Image {
                if (++tilesRendered == 3) coordinator.cancel()
                return CpuLutPassRenderer.render(source, plan)
            }
        }
        coordinator = ExportCoordinator(SaveCopyExporter(failingGateway, JpegEncoder<Rgba8ExportFrame> { _, _, _ -> }), Rgba8ExportFrame.factory,
            StandardTestDispatcher(testScheduler), maxTileEdge = 16, ledger = ledger,
        )
        coordinator.start(ExportJob("src", { source }, LutPassExportPlan(cancellingRenderer, plan), NewImageSpec("x.jpg")))
        advanceUntilIdle()

        assertEquals(3, tilesRendered, "rendering stops at the next tile boundary")
        assertIs<ExportState.Cancelled>(coordinator.state.value)
        assertEquals(0, ledger.liveCount(ExportBufferLedger.Kind.FULL_FRAME))
        assertEquals(0, ledger.liveCount(ExportBufferLedger.Kind.TILE))
    }

    @Test
    fun `documented 48 MP budget fits the 600 MB spec target`() {
        val budget = ExportBufferLedger.budgetBytes(8064, 6048)
        // 2 × 195,084,288 B (frames) + 2 × 67,108,864 B (4096² tiles).
        assertEquals(2L * 8064 * 6048 * 4 + 2L * 4096 * 4096 * 4, budget)
        assertTrue(budget <= 600_000_000L, "pipeline buffers alone: $budget B")
    }
}
