package com.lightlylabs.lightly.editor

import androidx.lifecycle.SavedStateHandle
import com.lightlylabs.lightly.develop.DevelopRenderer
import com.lightlylabs.lightly.develop.PixelRect
import com.lightlylabs.lightly.export.ExportCoordinator
import com.lightlylabs.lightly.export.FullResolutionSource
import com.lightlylabs.lightly.export.JpegEncoder
import com.lightlylabs.lightly.export.MediaStoreGateway
import com.lightlylabs.lightly.export.NewImageSpec
import com.lightlylabs.lightly.export.Rgba8ExportFrame
import com.lightlylabs.lightly.export.SaveCopyExporter
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.BorderType
import com.lightlylabs.lightly.session.EditTools
import com.lightlylabs.lightly.session.NormalisedPoint
import com.lightlylabs.lightly.session.SourceFingerprint
import com.lightlylabs.lightly.session.SourceRef
import com.lightlylabs.lightly.session.WatermarkFont
import com.lightlylabs.lightly.session.WatermarkPlacement
import com.lightlylabs.lightly.session.WatermarkType
import com.lightlylabs.lightly.signatures.DrawnSignature
import com.lightlylabs.lightly.signatures.SignatureStore
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
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Watermark (slice 5): stage-12 layout rules, the contract sizes and the panel's session behaviour. */
@OptIn(ExperimentalCoroutinesApi::class)
class WatermarkTest {
    private val stage = WatermarkStage(WatermarkSizes.REVISION_2, WatermarkFonts(null))
    private val neutral = EditTools.neutral(0).watermark

    @Test
    fun `the sizes are read from the bundled contract`() {
        val contract = File(checkNotNull(System.getProperty("lightly.renderingContract"))).readText()
        assertEquals(WatermarkSizes(0.06225, 0.08995, 0.09415), WatermarkSizes.fromContract(contract))
    }

    @Test
    fun `sizes follow the photo's short edge and size over 34`() {
        assertEquals(0.08995 * 1000, stage.mainSize(WatermarkStage.Kind.SIGNATURE, 34.0, 1000.0), 1e-9)
        assertEquals(0.06225 * 1000 * 2, stage.mainSize(WatermarkStage.Kind.TEXT, 68.0, 1000.0), 1e-9)
        assertEquals(0.09415 * 1000 / 30, stage.cssPixel(WatermarkStage.Kind.LOGO, 1000.0), 1e-12)
    }

    @Test
    fun `on the photo the box sits at the anchor with the prototype's alignment and strut`() {
        val image = PixelRect(0, 0, 1500, 1000)
        val extent = WatermarkStage.Extent(200.0, 90.0, 0.0)
        // Position 8 (bottom right, 94 %): the box ends at the anchor on both axes.
        val l = stage.layout(neutral, WatermarkStage.Kind.SIGNATURE, extent, 1500, 1000, image, BorderType.NONE)
        val px = 0.08995 * 1000 / 26
        assertEquals(1500 * 0.94 - 200, l.left, 1e-9)
        assertEquals(90 + 2 * px, l.height, 1e-9) // the 2 CSS px strut below the inline SVG
        assertEquals(1000 * 0.94 - l.height, l.top, 1e-9)
        assertEquals("#FFFFFF", l.ink)
        // A dragged offset at 50 % centres the box.
        val dragged = stage.layout(neutral.copy(offset = NormalisedPoint(0.5, 0.2)), WatermarkStage.Kind.SIGNATURE, extent, 1500, 1000, image, BorderType.NONE)
        assertEquals(750.0 - 100, dragged.left, 1e-9); assertEquals(200.0, dragged.top, 1e-9)
    }

    @Test
    fun `on a polaroid margin it is centred 6 percent above the canvas bottom in #222222`() {
        val l = stage.layout(neutral.copy(placement = WatermarkPlacement.BORDER), WatermarkStage.Kind.SIGNATURE, WatermarkStage.Extent(200.0, 90.0, 0.0), 1110, 1355, PixelRect(55, 55, 1000, 1000), BorderType.POLAROID)
        assertTrue(l.onBorder)
        assertEquals(1110 / 2.0 - 100, l.left, 1e-9)
        assertEquals(1355 * 0.94, l.top + l.height, 1e-9)
        assertEquals("#222222", l.ink)
        // Placement border without a border: on the photo.
        assertFalse(stage.layout(neutral.copy(placement = WatermarkPlacement.BORDER), WatermarkStage.Kind.SIGNATURE, WatermarkStage.Extent(1.0, 1.0, 0.0), 10, 10, PixelRect(0, 0, 10, 10), BorderType.NONE).onBorder)
    }

    @Test fun `canvas placement crosses photo and border and clamps to canvas`() {
        for (y in listOf(0.0, 0.5, 0.94, 1.0)) {
            val l = stage.layout(neutral.copy(placement = WatermarkPlacement.CANVAS, offset = NormalisedPoint(0.5, y)),
                WatermarkStage.Kind.SIGNATURE, WatermarkStage.Extent(100.0, 30.0, 0.0),
                1000, 1000, PixelRect(50, 50, 900, 700), BorderType.POLAROID)
            assertEquals(500.0, l.left + l.width / 2, 1e-9)
            assertTrue(l.top >= 0); assertTrue(l.top + l.height <= 1000)
            if (y == 0.94) assertTrue(l.top > 750)
        }
    }

    // --- the session --------------------------------------------------------------------------------

    private class Gateway : MediaStoreGateway<String> {
        override fun insertPending(spec: NewImageSpec) = "content://media/new/1"
        override fun openForWrite(handle: String) = java.io.ByteArrayOutputStream()
        override fun publish(handle: String) = true
        override fun delete(handle: String) {}
    }

    private class Favourites : FavouritesStore {
        private val state = MutableStateFlow<List<String>>(emptyList())
        override val favourites: StateFlow<List<String>> = state
        override fun update(change: (List<String>) -> List<String>) { state.value = change(state.value) }
    }

    private fun image(w: Int, h: Int) = Rgba8Image(w, h, ByteArray(w * h * 4) { if (it % 4 == 3) -1 else 120 })

    private fun TestScope.ready(store: SignatureStore = SignatureStore(null)): EditorViewModel {
        val dispatcher = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(dispatcher)
        val env = EditorEnvironment(
            photoLoader = PhotoLoader { asset -> LoadedPhoto(SourceRef(asset, SourceFingerprint("ab".repeat(32), 1, 96, 64), 1), image(24, 16), image(48, 32), FullResolutionSource { image(96, 64) }) },
            photoAccess = object : PhotoAccessGrants { override fun retain(assetId: String) = true; override fun release(assetId: String) {} },
            autoDeveloper = AutoDeveloper { _, _, _ -> DevelopResult.NoModelInThisBuild },
            personDetector = PendingPersonDetector,
            library = CompletableDeferred(BundledPack.library),
            previewRenderer = DevelopRenderer(),
            renderDispatcher = dispatcher, prefetchDispatcher = dispatcher,
            exporter = ExportCoordinator(SaveCopyExporter(Gateway(), JpegEncoder<Rgba8ExportFrame> { _, _, _ -> }), Rgba8ExportFrame.factory, dispatcher, maxTileEdge = 32),
            favourites = Favourites(), debugBuild = true, signatures = store,
        )
        val vm = EditorViewModel(SavedStateHandle(), env, CoroutineScope(SupervisorJob() + dispatcher))
        vm.openPhoto("content://photo/1")
        advanceUntilIdle()
        return vm
    }

    @AfterTest
    fun tearDown() = Dispatchers.resetMain()

    private fun EditorViewModel.watermark() = uiState.value.session!!.current.tools.watermark

    @Test
    fun `Text is one step with the sample text, the font and position change as steps, and undo walks back`() = runTest {
        val vm = ready()
        vm.selectTool(EditorTool.WATERMARK)
        vm.chooseWatermark(WatermarkType.TEXT)
        assertEquals(WatermarkOptions.DEFAULT_TEXT, vm.watermark().text?.text)
        vm.chooseFont(WatermarkFont.CAVEAT)
        vm.cycleWatermarkPosition()
        vm.setWatermarkText("Lightly")
        advanceUntilIdle()
        assertEquals("Lightly", vm.watermark().text?.text); assertEquals(WatermarkFont.CAVEAT, vm.watermark().text?.font); assertEquals(0, vm.watermark().position)
        vm.undo(); vm.undo(); vm.undo(); advanceUntilIdle()
        assertEquals(WatermarkFont.ALLURA, vm.watermark().text?.font)
        vm.undo(); advanceUntilIdle()
        assertEquals(WatermarkType.NONE, vm.watermark().type)
    }

    @Test
    fun `without a saved signature the Signature tab shows but changes nothing, and Draw then Save uses the drawing`() = runTest {
        val store = SignatureStore(null)
        val vm = ready(store)
        vm.selectTool(EditorTool.WATERMARK)
        vm.chooseWatermark(WatermarkType.SIGNATURE)
        assertEquals(WatermarkType.SIGNATURE, vm.watermarkTab())
        assertEquals(WatermarkType.NONE, vm.watermark().type)
        vm.openDrawSignature()
        vm.padStroke(prototypePadStrokes())
        vm.saveDrawnSignature()
        advanceUntilIdle()
        assertEquals(WatermarkType.SIGNATURE, vm.watermark().type)
        assertEquals(store.contents.value.drawn?.reference, vm.watermark().signature)
        assertNull(vm.uiState.value.overlay)
    }

    @Test
    fun `Signature on the margin with nothing saved opens Draw, and the drawing goes on the margin`() = runTest {
        val vm = ready()
        vm.selectTool(EditorTool.BORDER)
        vm.chooseBorder(BorderType.POLAROID)
        vm.toggleSignatureOnMargin()
        assertEquals(EditorOverlay.SIGNATURE_DRAW, vm.uiState.value.overlay)
        vm.padStroke(listOf(listOf(DrawnSignature.Point(10.0, 10.0), DrawnSignature.Point(60.0, 30.0))))
        vm.saveDrawnSignature()
        advanceUntilIdle()
        assertEquals(WatermarkPlacement.BORDER, vm.watermark().placement)
        assertTrue(vm.signatureOnMargin())
        vm.toggleSignatureOnMargin()
        assertEquals(WatermarkPlacement.PHOTO, vm.watermark().placement)
    }

    @Test
    fun `a watermark whose saved signature was deleted renders without it`() = runTest {
        val store = SignatureStore(null)
        store.saveDrawn(DrawnSignature.PROTOTYPE_SAMPLE)
        val vm = ready(store)
        vm.chooseWatermark(WatermarkType.SIGNATURE)
        advanceUntilIdle()
        assertNotNull(vm.watermark().signature)
        store.delete(com.lightlylabs.lightly.session.SignatureKind.DRAWN)
        assertNull(store.resolve(vm.watermark().signature!!))
    }

    @Test
    fun `W1 - the watermark is the prototype's on-screen size on every device, and Save uses the stage's size`() = runTest {
        val vm = ready()
        // Before the stage is laid out: the contract's values.
        assertEquals(WatermarkSizes.REVISION_2, vm.watermarkSizes(BundledPack.library))
        // A phone-sized and a tablet-sized photo box: the text is 18 dp on screen in both.
        for (shortDp in listOf(400f, 760f)) {
            vm.onStagePhotoMeasured(shortDp, shortDp * 1.5f)
            val sizes = vm.watermarkSizes(BundledPack.library)
            assertEquals(18.0, sizes.textFontSize * shortDp, 1e-9)
            assertEquals(26.0, sizes.signatureHeight * shortDp, 1e-9)
            assertEquals(30.0, sizes.logoHeight * shortDp, 1e-9)
        }
    }

    @Test
    fun `blur - R_max follows the displayed photo so the on-screen blur is blur over 9 dp on every device`() = runTest {
        val vm = ready()
        val recipe = vm.uiState.value.session!!.current
        assertEquals(0.06, vm.maxBlurFraction(recipe), 1e-12)
        // Pixel 9 Pro bg-focus: the photo is about 479 dp long, where the contract's 0.06 was calibrated (+4 to 9 %).
        vm.onStagePhotoMeasured(320f, 479f)
        assertEquals(0.0576, vm.maxBlurFraction(recipe), 0.0005)
        // A tablet shows the photo about twice as large, so the fraction halves: the same σ in dp on screen.
        vm.onStagePhotoMeasured(640f, 958f)
        assertEquals(0.0288, vm.maxBlurFraction(recipe), 0.0005)
    }
}
