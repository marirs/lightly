package com.lightlylabs.lightly.editor

import androidx.lifecycle.SavedStateHandle
import com.lightlylabs.lightly.develop.DevelopRenderer
import com.lightlylabs.lightly.export.ExportCoordinator
import com.lightlylabs.lightly.export.FullResolutionSource
import com.lightlylabs.lightly.export.JpegEncoder
import com.lightlylabs.lightly.export.MediaStoreGateway
import com.lightlylabs.lightly.export.NewImageSpec
import com.lightlylabs.lightly.export.Rgba8ExportFrame
import com.lightlylabs.lightly.export.SaveCopyExporter
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.NormalisedPoint
import com.lightlylabs.lightly.session.SourceFingerprint
import com.lightlylabs.lightly.session.SourceRef
import com.lightlylabs.lightly.session.TextFont
import com.lightlylabs.lightly.session.TextLayer
import com.lightlylabs.lightly.session.TextWeight
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.OutputStream
import kotlin.math.abs
import kotlin.random.Random
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The Text tool (owner amendment 2026-10-11): stage 11's layout and pixels, the pure layer edits and the session steps. */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class TextToolTest {
    private val stage = TextStage(WatermarkFonts(null))

    private fun layer(text: String = "Summer in Lisbon", size: Int = 42, centre: NormalisedPoint = NormalisedPoint(0.5, 0.5), rotation: Double = 0.0) =
        TextLayer("0a1b2c3d", text, TextFont.PLAYFAIR_DISPLAY, TextWeight.REGULAR, size, "#FFFFFF", 100.0, centre, rotation)

    private fun grey(width: Int, height: Int) = Rgba8Image(width, height, ByteArray(width * height * 4) { if (it % 4 == 3) -1 else 60 })

    // --- stage 11 layout and pixels ------------------------------------------------------------

    @Test
    fun `the font size is size over 100 times a quarter of the frame's short edge`() {
        assertEquals(42.0 / 100 * 0.25 * 600, TextStage.fontSize(42, 900.0, 600.0), 1e-9)
        assertEquals(stage.block(layer(), 900.0, 600.0).fontSize, TextStage.fontSize(42, 600.0, 900.0), 1e-9)
    }

    @Test
    fun `the text block is centred on centre times the frame`() {
        val block = stage.block(layer(centre = NormalisedPoint(0.25, 0.8)), 1000.0, 500.0)
        assertEquals(250.0, block.centreX, 1e-9)
        assertEquals(400.0, block.centreY, 1e-9)
        assertTrue(block.width > 0 && block.height > 0)
        val two = stage.block(layer(text = "one\ntwo"), 1000.0, 500.0)
        assertEquals(2 * two.lineHeight, two.height, 1e-9)
    }

    @Test
    fun `the block covers the same part of the frame at any resolution (within 0_5 percent of the short edge)`() {
        val small = stage.block(layer(), 800.0, 600.0)
        val large = stage.block(layer(), 4000.0, 3000.0)
        assertTrue(abs(small.width / 600 - large.width / 3000) < 0.005, "width ${small.width / 600} vs ${large.width / 3000}")
        assertTrue(abs(small.height / 600 - large.height / 3000) < 0.005, "height ${small.height / 600} vs ${large.height / 3000}")
    }

    @Test
    fun `text is drawn at its centre and pixels far from it are unchanged`() {
        val frame = grey(400, 300)
        val out = stage.apply(frame, listOf(layer(size = 60)), 400, 300)
        fun changed(x0: Int, y0: Int, x1: Int, y1: Int) = (y0 until y1).any { y -> (x0 until x1).any { x -> (0 until 3).any { c -> out.pixels[(y * 400 + x) * 4 + c] != frame.pixels[(y * 400 + x) * 4 + c] } } }
        assertTrue(changed(150, 130, 250, 170), "white text near the centre")
        assertFalse(changed(0, 0, 400, 40), "nothing in the top band")
        assertFalse(changed(0, 260, 400, 300), "nothing in the bottom band")
        assertContentEquals(frame.pixels, stage.apply(frame, emptyList(), 400, 300).pixels)
    }

    @Test
    fun `Save copy's tiles draw exactly what the whole frame does`() {
        val frame = grey(320, 240)
        val layers = listOf(layer(size = 50, rotation = -12.0), layer(text = "2026", size = 20, centre = NormalisedPoint(0.7, 0.85)).copy(id = "00000002", opacity = 60.0))
        val whole = stage.apply(frame, layers, 320, 240)
        for ((x, y) in listOf(0 to 0, 128 to 96, 192 to 160)) {
            val tile = Rgba8Image(128, 80, ByteArray(128 * 80 * 4).also { bytes ->
                for (ty in 0 until 80) System.arraycopy(frame.pixels, ((y + ty) * 320 + x) * 4, bytes, ty * 128 * 4, 128 * 4)
            })
            val drawn = stage.apply(tile, layers, 320, 240, x, y)
            for (ty in 0 until 80) for (tx in 0 until 128) for (c in 0 until 4) {
                assertEquals(whole.pixels[((y + ty) * 320 + x + tx) * 4 + c], drawn.pixels[(ty * 128 + tx) * 4 + c], "tile ($x, $y) pixel ($tx, $ty)")
            }
        }
    }

    // --- pure layer edits --------------------------------------------------------------------

    @Test
    fun `a new layer has the approved defaults`() {
        val new = TextEdits.newLayer("12345678", "Hello")
        assertEquals(TextLayer("12345678", "Hello", TextFont.PLAYFAIR_DISPLAY, TextWeight.REGULAR, 42, "#FFFFFF", 100.0, NormalisedPoint(0.5, 0.5), 0.0), new)
        val ids = (1..200).map { TextEdits.newId(emptyList(), Random(it)) }
        assertTrue(ids.all { Regex("^[0-9a-f]{8}$").matches(it) })
        assertNotEquals(ids[0], TextEdits.newId(listOf(ids[0]), Random(1)))
    }

    @Test
    fun `moving keeps the centre in the frame, resizing and turning stay in range`() {
        assertEquals(NormalisedPoint(1.0, 0.0), TextEdits.moved(layer(), 0.9, -0.7).centre)
        assertEquals(100, TextEdits.scaledAndTurned(layer(), 5.0, 0.0).size)
        assertEquals(10, TextEdits.scaledAndTurned(layer(), 0.01, 0.0).size)
        assertEquals(-170.0, TextEdits.scaledAndTurned(layer(rotation = 170.0), 1.0, 20.0).rotation, 1e-9)
        assertEquals(180.0, TextEdits.normalisedDegrees(-180.0), 1e-9)
        assertEquals(63, TextEdits.withSlider(layer(), "size", 62.6).size)
        assertNull(TextEdits.acceptedText("   "))
        assertEquals(120, TextEdits.acceptedText("x".repeat(200))!!.length)
    }

    // --- the session: every finished change is one undo step ------------------------------------

    private fun image(w: Int, h: Int) = Rgba8Image(w, h, ByteArray(w * h * 4) { if (it % 4 == 3) -1 else (it % 200).toByte() })

    private fun TestScope.ready(): EditorViewModel {
        val dispatcher = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(dispatcher)
        val favourites = object : FavouritesStore {
            private val state = MutableStateFlow<List<String>>(emptyList())
            override val favourites: StateFlow<List<String>> = state
            override fun update(change: (List<String>) -> List<String>) { state.value = change(state.value) }
        }
        val gateway = object : MediaStoreGateway<String> {
            override fun insertPending(spec: NewImageSpec) = "content://new/1"
            override fun openForWrite(handle: String): OutputStream = OutputStream.nullOutputStream()
            override fun publish(handle: String) = true
            override fun delete(handle: String) = Unit
        }
        val env = EditorEnvironment(
            photoLoader = PhotoLoader { asset -> LoadedPhoto(SourceRef(asset, SourceFingerprint("ab".repeat(32), 10, 48, 32), 1), image(24, 16), image(48, 32), FullResolutionSource { image(48, 32) }) },
            photoAccess = object : PhotoAccessGrants {
                override fun retain(assetId: String) = true
                override fun release(assetId: String) = Unit
            },
            autoDeveloper = AutoDeveloper { _, _, _ -> DevelopResult.NoModelInThisBuild },
            personDetector = PendingPersonDetector,
            library = CompletableDeferred(BundledPack.library),
            previewRenderer = DevelopRenderer(),
            renderDispatcher = dispatcher,
            prefetchDispatcher = dispatcher,
            exporter = ExportCoordinator(SaveCopyExporter(gateway, JpegEncoder<Rgba8ExportFrame> { _, _, _ -> }), Rgba8ExportFrame.factory, dispatcher),
            favourites = favourites,
            debugBuild = true,
        )
        val vm = EditorViewModel(SavedStateHandle(), env, CoroutineScope(SupervisorJob() + dispatcher))
        vm.openPhoto("content://photo/1")
        advanceUntilIdle()
        vm.selectTool(EditorTool.TEXT)
        return vm
    }

    @After
    fun tearDown() = Dispatchers.resetMain()

    private val EditorViewModel.layers get() = uiState.value.session!!.current.tools.text.layers
    private val EditorViewModel.steps get() = uiState.value.session!!.history.entries.size

    @Test
    fun `Done adds one selected layer in one step, Cancel and blank text add nothing`() = runTest {
        val vm = ready()
        vm.openAddText(); vm.closeTextSheet()
        vm.openAddText(); vm.finishTextSheet("   ")
        assertEquals(TextSheet.Adding, vm.uiState.value.text.sheet, "blank text keeps the sheet open (Done is disabled there)")
        vm.closeTextSheet()
        assertEquals(1, vm.steps)
        assertTrue(vm.layers.isEmpty())
        assertFalse(toolUsed(vm.uiState.value, EditorTool.TEXT))
        vm.finishTextSheet("ignored: the sheet is closed")
        vm.openAddText(); vm.finishTextSheet("Summer in Lisbon")
        advanceUntilIdle()
        assertEquals(2, vm.steps)
        val added = vm.layers.single()
        assertEquals(TextEdits.newLayer(added.id, "Summer in Lisbon"), added)
        assertEquals(added.id, vm.uiState.value.text.selectedId)
        assertNull(vm.uiState.value.text.sheet)
        assertTrue(toolUsed(vm.uiState.value, EditorTool.TEXT), "the dock's edit dot")
        assertTrue(vm.canReset("all"))
    }

    @Test
    fun `edit, font, slider, colour, move and delete are one step each, and Undo walks them back`() = runTest {
        val vm = ready()
        vm.openAddText(); vm.finishTextSheet("Summer")
        val id = vm.layers.single().id
        var expected = vm.steps
        vm.openEditText(); vm.finishTextSheet("Summer in Lisbon"); expected++
        assertEquals("Summer in Lisbon", vm.layers.single().text); assertEquals(expected, vm.steps)
        vm.chooseTextFont(TextFont.BEBAS_NEUE); expected++
        assertEquals(expected, vm.steps)
        vm.onTextSlider("size", 60.0); vm.onTextSlider("size", 70.0)
        assertEquals(expected, vm.steps, "a moving slider records nothing")
        vm.onTextSliderRelease("size", 70.0); expected++
        assertEquals(70, vm.layers.single().size); assertEquals(expected, vm.steps)
        vm.setTextColour("#1F2328"); expected++
        val moved = TextEdits.moved(vm.layers.single(), 0.1, -0.2)
        vm.previewTextLayer(moved); vm.previewTextLayer(TextEdits.moved(moved, 0.01, 0.0))
        vm.commitTextLayer(moved); expected++
        assertEquals(NormalisedPoint(0.6, 0.3), vm.layers.single().centre.let { NormalisedPoint(Math.round(it.x * 10) / 10.0, Math.round(it.y * 10) / 10.0) })
        assertEquals(expected, vm.steps)
        vm.commitTextLayer(vm.layers.single())
        assertEquals(expected, vm.steps, "an unchanged gesture records nothing")
        vm.deleteTextLayer(id); expected++
        assertTrue(vm.layers.isEmpty()); assertEquals(expected, vm.steps)
        assertNull(vm.uiState.value.text.selectedId)
        vm.undo()
        assertEquals(moved, vm.layers.single(), "Undo brings the deleted layer back as it was")
        vm.undo()
        assertEquals(0.5, vm.layers.single().centre.x, 1e-9)
        advanceUntilIdle()
    }

    @Test
    fun `Reset all clears every text layer`() = runTest {
        val vm = ready()
        vm.openAddText(); vm.finishTextSheet("One")
        vm.openAddText(); vm.finishTextSheet("Two")
        assertEquals(2, vm.layers.size)
        assertEquals(listOf("One", "Two"), vm.layers.map { it.text })
        vm.resetEdits()
        assertTrue(vm.layers.isEmpty())
        advanceUntilIdle()
    }

    @Test
    fun `opening the Text tool selects the first layer`() = runTest {
        val vm = ready()
        vm.openAddText(); vm.finishTextSheet("One")
        vm.openAddText(); vm.finishTextSheet("Two")
        vm.selectTool(EditorTool.DEVELOP)
        assertNull(vm.uiState.value.text.selectedId)
        vm.selectTool(EditorTool.TEXT)
        assertEquals(vm.layers.first().id, vm.uiState.value.text.selectedId)
        advanceUntilIdle()
    }
}
