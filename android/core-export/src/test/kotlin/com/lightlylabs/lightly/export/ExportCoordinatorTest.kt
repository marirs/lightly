package com.lightlylabs.lightly.export

import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.lut.CpuLutPassRenderer
import com.lightlylabs.lightly.render.lut.Lut3D
import com.lightlylabs.lightly.render.lut.LutPassPlan
import com.lightlylabs.lightly.render.lut.LutPassRenderer
import com.lightlylabs.lightly.render.schedule.PreviewRenderer
import com.lightlylabs.lightly.render.schedule.RenderScheduler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** Export path (spec §5.4) on virtual time, sharing the render dispatcher with previews. */
@OptIn(ExperimentalCoroutinesApi::class)
class ExportCoordinatorTest {

    private val original = Rgba8Image(97, 61, ByteArray(97 * 61 * 4).also { Random(9).nextBytes(it) })
    private val snapshotPlan = LutPassPlan.of(OUT_OF_RANGE_AUTO, 0.75f, null, 1f)
    private val spec = NewImageSpec(displayName = "IMG_1_lightly.jpg")

    private class MemoryGateway : MediaStoreGateway<String> {
        val inserted = mutableListOf<String>()
        val files = mutableMapOf<String, ByteArrayOutputStream>()
        val published = mutableListOf<String>()
        override fun insertPending(spec: NewImageSpec) = "content://media/new/${inserted.size + 1}".also { inserted += it }
        override fun openForWrite(handle: String): OutputStream = ByteArrayOutputStream().also { files[handle] = it }
        override fun publish(handle: String) = published.add(handle)
        override fun delete(handle: String) { files.remove(handle) }
    }

    /** "Encodes" by writing the raw pixels, so the test can compare what was saved. */
    private class CountingEncoder(private val onEncode: () -> Unit = {}) : JpegEncoder<Rgba8Image> {
        var calls = 0
        override fun encode(image: Rgba8Image, quality: Int, sink: OutputStream) {
            calls++
            onEncode()
            sink.write(image.pixels)
        }
    }

    private class SlowSource(private val image: Rgba8Image, private val millis: Long) : FullResolutionSource {
        override suspend fun decode(): Rgba8Image { delay(millis); return image }
    }

    private class Harness(test: TestScope, encoder: CountingEncoder = CountingEncoder(), tileEdge: Int = 32) {
        val dispatcher = StandardTestDispatcher(test.testScheduler)
        val gateway = MemoryGateway()
        val encoder = encoder
        val coordinator = ExportCoordinator(CpuLutPassRenderer, SaveCopyExporter(gateway, encoder), dispatcher, maxTileEdge = tileEdge)
    }

    private fun job(decodeMillis: Long = 500) =
        ExportJob("content://media/original/1", SlowSource(original, decodeMillis), snapshotPlan, spec)

    @Test
    fun `an export is not dropped or superseded by later previews or by closing the preview session`() = runTest {
        val h = Harness(this)
        val previews = RenderScheduler(
            sessionId = "session",
            renderer = PreviewRenderer<Int, Int> { request -> delay(50); request.payload },
            parentScope = CoroutineScope(Job()),
            renderDispatcher = h.dispatcher,
        )

        val started = h.coordinator.start(job())
        runCurrent()
        // A slider drag while saving: 30 previews, then cancel them all, then leave the photo.
        val revisions = (1..30).map { previews.submit(it) }
        advanceTimeBy(120)
        previews.cancel(through = revisions.last())
        previews.close()
        advanceUntilIdle()

        val saved = assertIs<ExportState.Saved<String>>(h.coordinator.state.value)
        assertEquals((started as ExportStart.Started).exportId, saved.exportId)
        assertEquals(listOf(saved.newAsset), h.gateway.published)
        assertEquals(1, h.encoder.calls, "encoded exactly once")
        assertContentEquals(CpuLutPassRenderer.render(original, snapshotPlan).pixels, h.gateway.files.getValue(saved.newAsset).toByteArray())
    }

    @Test
    fun `tiled export equals a whole-frame render of the snapshot plan`() = runTest {
        val h = Harness(this, tileEdge = 16)
        h.coordinator.start(job(decodeMillis = 0))
        advanceUntilIdle()

        val saved = assertIs<ExportState.Saved<String>>(h.coordinator.state.value)
        assertContentEquals(CpuLutPassRenderer.render(original, snapshotPlan).pixels, h.gateway.files.getValue(saved.newAsset).toByteArray())
    }

    @Test
    fun `only one export runs at a time and a retry is a new export`() = runTest {
        val h = Harness(this)
        assertIs<ExportStart.Started>(h.coordinator.start(job()))
        assertEquals(ExportStart.AlreadyRunning, h.coordinator.start(job()))
        advanceUntilIdle()

        assertIs<ExportStart.Started>(h.coordinator.start(job()))
        advanceUntilIdle()
        assertEquals(2, h.gateway.published.size)
        assertEquals(2, h.encoder.calls)
    }

    @Test
    fun `cancel before encoding leaves no MediaStore row and encodes nothing`() = runTest {
        val h = Harness(this)
        h.coordinator.start(job(decodeMillis = 500))
        advanceTimeBy(100)

        h.coordinator.cancel()
        advanceUntilIdle()

        assertIs<ExportState.Cancelled>(h.coordinator.state.value)
        assertTrue(h.gateway.inserted.isEmpty(), "the pending row is created only after rendering")
        assertEquals(0, h.encoder.calls)
    }

    @Test
    fun `cancel once encoding has started does not interrupt encode and write`() = runTest {
        lateinit var h: Harness
        h = Harness(this, encoder = CountingEncoder(onEncode = { h.coordinator.cancel() }))
        h.coordinator.start(job(decodeMillis = 0))
        advanceUntilIdle()

        val saved = assertIs<ExportState.Saved<String>>(h.coordinator.state.value)
        assertEquals(listOf(saved.newAsset), h.gateway.published)
        assertEquals(1, h.encoder.calls)
    }

    @Test
    fun `a failing save is reported and the pending row is gone`() = runTest {
        val failing = object : MediaStoreGateway<String> {
            val deleted = mutableListOf<String>()
            override fun insertPending(spec: NewImageSpec) = "content://media/new/1"
            override fun openForWrite(handle: String): OutputStream = throw java.io.IOException("ENOSPC (No space left on device)")
            override fun publish(handle: String) = true
            override fun delete(handle: String) { deleted += handle }
        }
        val coordinator = ExportCoordinator(CpuLutPassRenderer, SaveCopyExporter(failing, CountingEncoder()), StandardTestDispatcher(testScheduler))
        coordinator.start(job(decodeMillis = 0))
        advanceUntilIdle()

        val failed = assertIs<ExportState.Failed>(coordinator.state.value)
        assertIs<SaveCopyFailure.OutOfStorage>(failed.error)
        assertEquals(listOf("content://media/new/1"), failing.deleted)
    }

    @Test
    fun `export renders through the injected renderer, the same one previews use`() = runTest {
        var renderCalls = 0
        val counting = object : LutPassRenderer {
            override fun render(source: Rgba8Image, plan: LutPassPlan): Rgba8Image { renderCalls++; return CpuLutPassRenderer.render(source, plan) }
        }
        val coordinator = ExportCoordinator(counting, SaveCopyExporter(MemoryGateway(), CountingEncoder()), StandardTestDispatcher(testScheduler), maxTileEdge = 32)
        coordinator.start(job(decodeMillis = 0))
        advanceUntilIdle()

        assertEquals(4 * 2, renderCalls, "97x61 at 32-px tiles = 4 x 2 tiles")
    }

    companion object {
        private val OUT_OF_RANGE_AUTO: Lut3D = run {
            val identity = Lut3D.identity()
            Lut3D(33, FloatArray(identity.rgba.size) { i -> if (i % 4 == 3) 1f else identity.rgba[i] * 1.3f - 0.1f })
        }
    }
}
