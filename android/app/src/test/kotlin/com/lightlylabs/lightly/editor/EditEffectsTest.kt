package com.lightlylabs.lightly.editor

import androidx.lifecycle.SavedStateHandle
import com.lightlylabs.lightly.develop.DevelopRenderer
import com.lightlylabs.lightly.export.ExportCoordinator
import com.lightlylabs.lightly.export.ExportState
import com.lightlylabs.lightly.export.FullResolutionSource
import com.lightlylabs.lightly.export.JpegEncoder
import com.lightlylabs.lightly.export.MediaStoreGateway
import com.lightlylabs.lightly.export.NewImageSpec
import com.lightlylabs.lightly.export.Rgba8ExportFrame
import com.lightlylabs.lightly.export.SaveCopyExporter
import com.lightlylabs.lightly.export.TiledExportRenderer
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.CropAspect
import com.lightlylabs.lightly.session.EditSession
import com.lightlylabs.lightly.session.ModelRef
import com.lightlylabs.lightly.session.RemoveStatus
import com.lightlylabs.lightly.session.SourceFingerprint
import com.lightlylabs.lightly.session.SourceRef
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
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import kotlin.math.abs
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Slice 4: Edit (geometry, Adjust, Remove) and Effects in the one editing session; preview and export of one recipe. */
@OptIn(ExperimentalCoroutinesApi::class)
class EditEffectsTest {
    private val library = BundledPack.library

    private fun image(width: Int, height: Int, seed: Int) = Rgba8Image(width, height, ByteArray(width * height * 4) { i ->
        val p = i / 4
        if (i % 4 == 3) -1 else (((p % width) * 3 + (p / width) * 5 + seed * 11 + (i % 4) * 40) % 251).toByte()
    })

    /** A model stand-in that fills the hole with pure red, so the paste-back is visible and exact. */
    private class RedInpainter : Inpainter {
        override val model = ModelRef("test-red", "1")
        var calls = 0
        override fun inpaint(image: FloatArray, mask: FloatArray): FloatArray {
            calls++
            val n = mask.size
            return FloatArray(3 * n) { if (it < n) 1f else 0f }
        }
    }

    // --- Remove engine -------------------------------------------------------------------------------

    @Test
    fun `a Remove patch changes only the brush and its feather`() {
        val source = image(300, 200, 3)
        val radius = 10.0 / 300
        val patch = RemoveEngine.patch(source, listOf(0.5 to 0.5, 0.6 to 0.55), radius, RedInpainter())
        val out = RemoveEngine.composite(listOf(patch), source)
        for (y in 0 until 200) for (x in 0 until 300) {
            val d = RemoveEngine.distanceToStroke(x + 0.5, y + 0.5, listOf(150.0 to 100.0, 180.0 to 110.0))
            val o = (y * 300 + x) * 4
            if (d > 10 + RemoveEngine.FEATHER_PX + 1) {
                for (c in 0 until 3) assertEquals(source.pixels[o + c], out.pixels[o + c], "pixel ($x, $y) outside the brush changed")
            }
            if (d < 9) assertEquals(255, out.pixels[o].toInt() and 0xff, "pixel ($x, $y) inside the brush is not the fill")
        }
    }

    @Test
    fun `the preview composites the same patch scaled`() {
        val full = image(400, 300, 5)
        val patch = RemoveEngine.patch(full, listOf(0.3 to 0.4), 20.0 / 400, RedInpainter())
        val preview = RemoveEngine.composite(listOf(patch), image(200, 150, 5))
        val o = ((60) * 200 + 60) * 4 // (0.3, 0.4) at half size
        assertEquals(255, preview.pixels[o].toInt() and 0xff)
        assertEquals(0, preview.pixels[o + 1].toInt() and 0xff)
    }

    // --- one recipe, preview and export --------------------------------------------------------------

    private fun editedState(): com.lightlylabs.lightly.session.EditState {
        val fingerprint = SourceFingerprint("cd".repeat(32), 1000, 96, 64)
        val start = EditSession.start(SourceRef("content://photo/9", fingerprint, 1), com.lightlylabs.lightly.session.AutoResult("ia3dlut", "no-model-in-build", listOf(0f, 0f, 0f), null, 0f)).current
        val tools = start.tools
        return start.copy(tools = tools.copy(
            edit = tools.edit.copy(
                geometry = tools.edit.geometry.copy(quarterTurns = 1, straighten = -3.0, crop = com.lightlylabs.lightly.session.Crop(CropAspect.FREE, com.lightlylabs.lightly.session.NormalisedRect(0.1, 0.05, 0.8, 0.85))),
                adjust = tools.edit.adjust.copy(exposure = 12.0, contrast = 10.0, temp = 15.0, sharpness = 30.0, noise = 20.0),
            ),
            effects = tools.effects.copy(vignette = tools.effects.vignette.copy(enabled = true), lightLeak = tools.effects.lightLeak.copy(enabled = true), grain = tools.effects.grain.copy(enabled = true)),
        ))
    }

    @Test
    fun `Save copy renders the recipe tile by tile exactly as the whole-frame preview at the same size`() = runTest {
        val state = editedState()
        assertTrue(EditMapping.usesEditOrEffects(state))
        val plan = library.planFor(state)
        val renderer = DevelopRenderer()
        val pipeline = EditPipeline(library.model, renderer)
        val source = image(96, 64, 7)
        val preview = pipeline.renderPreview(source, state, plan, null)
        val target = Rgba8ExportFrame(preview.width, preview.height)
        val tileRenderer = pipeline.exportPlan(state, plan, emptyList(), null).prepare(Rgba8Image(96, 64, source.pixels.copyOf()))
        assertEquals(preview.width to preview.height, tileRenderer.outputSize(source))
        TiledExportRenderer(maxTileEdge = 24).render(source, tileRenderer, target)
        var worst = 0
        for (i in preview.pixels.indices) if (i % 4 != 3) worst = maxOf(worst, abs((preview.pixels[i].toInt() and 0xff) - (target.pixels[i].toInt() and 0xff)))
        assertEquals(0, worst, "tiled export differs from the preview by $worst levels")
    }

    // --- the editing session -------------------------------------------------------------------------

    private class MemoryGateway : MediaStoreGateway<String> {
        val files = mutableMapOf<String, ByteArrayOutputStream>()
        override fun insertPending(spec: NewImageSpec) = "content://media/new/${files.size + 1}"
        override fun openForWrite(handle: String): OutputStream = ByteArrayOutputStream().also { files[handle] = it }
        override fun publish(handle: String) = true
        override fun delete(handle: String) { files.remove(handle) }
    }

    private class Favourites : FavouritesStore {
        private val state = MutableStateFlow<List<String>>(emptyList())
        override val favourites: StateFlow<List<String>> = state
        override fun update(change: (List<String>) -> List<String>) { state.value = change(state.value) }
    }

    private var savedSize: Pair<Int, Int>? = null

    private fun TestScope.ready(inpainter: Inpainter?): EditorViewModel {
        val dispatcher = StandardTestDispatcher(testScheduler)
        Dispatchers.setMain(dispatcher)
        val gateway = MemoryGateway()
        val env = EditorEnvironment(
            photoLoader = PhotoLoader { asset ->
                val fingerprint = SourceFingerprint("ab".repeat(32), 1000, 96, 64)
                LoadedPhoto(SourceRef(asset, fingerprint, 1), image(24, 16, 1), image(48, 32, 2), FullResolutionSource { image(96, 64, 2) })
            },
            photoAccess = object : PhotoAccessGrants {
                override fun retain(assetId: String) = true
                override fun release(assetId: String) {}
            },
            autoDeveloper = AutoDeveloper { _, _ -> DevelopResult.NoModelInThisBuild },
            personDetector = PendingPersonDetector,
            library = CompletableDeferred(library),
            previewRenderer = DevelopRenderer(),
            renderDispatcher = dispatcher,
            prefetchDispatcher = dispatcher,
            exporter = ExportCoordinator(
                SaveCopyExporter(gateway, JpegEncoder<Rgba8ExportFrame> { frame, _, sink -> savedSize = frame.width to frame.height; sink.write(frame.pixels) }),
                Rgba8ExportFrame.factory, dispatcher, maxTileEdge = 32,
            ),
            favourites = Favourites(),
            debugBuild = true,
            inpainter = { inpainter },
        )
        val vm = EditorViewModel(SavedStateHandle(), env, CoroutineScope(SupervisorJob() + dispatcher))
        vm.openPhoto("content://photo/1")
        advanceUntilIdle()
        return vm
    }

    @AfterTest
    fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `Edit and Effects changes are whole-recipe undo steps and sliders preview without committing`() = runTest {
        val vm = ready(null)
        vm.selectTool(EditorTool.EDIT)
        vm.setCropAspect(CropAspect.FOUR_FIVE)
        vm.onEditSlider("exposure", 40.0)
        advanceUntilIdle()
        assertEquals(0.0, vm.uiState.value.session!!.current.tools.edit.adjust.exposure)
        vm.onEditSliderRelease("exposure", 40.0)
        vm.selectTool(EditorTool.EFFECTS)
        vm.toggleEffect(EffectsSub.VIGNETTE)
        advanceUntilIdle()
        val ui = vm.uiState.value
        assertEquals(CropAspect.FOUR_FIVE, ui.session!!.current.tools.edit.geometry.crop.aspect)
        assertEquals(40.0, ui.session!!.current.tools.edit.adjust.exposure)
        assertTrue(ui.session!!.current.tools.effects.vignette.enabled)
        // The preview is the 4:5 frame.
        assertEquals(4.0 / 5, ui.preview!!.width.toDouble() / ui.preview!!.height, 0.05)
        vm.undo(); advanceUntilIdle()
        assertFalse(vm.uiState.value.session!!.current.tools.effects.vignette.enabled)
        assertEquals(40.0, vm.uiState.value.session!!.current.tools.edit.adjust.exposure)
        vm.undo(); vm.undo(); advanceUntilIdle()
        assertEquals(CropAspect.ORIGINAL, vm.uiState.value.session!!.current.tools.edit.geometry.crop.aspect)
        assertFalse(vm.uiState.value.canUndo)
        vm.redo(); vm.redo(); vm.redo(); advanceUntilIdle()
        assertTrue(vm.uiState.value.session!!.current.tools.effects.vignette.enabled)
    }

    @Test
    fun `the used dots follow the approved toolUsed rules`() = runTest {
        val vm = ready(null)
        val recipe = { vm.uiState.value.session!!.current }
        vm.flipVertical(); advanceUntilIdle()
        assertFalse(ToolUsed.edit(recipe(), pendingStroke = false), "Flip vertical is not in the approved rule (Q1)")
        vm.flipHorizontal(); advanceUntilIdle()
        assertTrue(ToolUsed.edit(recipe(), pendingStroke = false))
        assertFalse(ToolUsed.effects(recipe()))
        vm.toggleEffect(EffectsSub.GRAIN); advanceUntilIdle()
        assertTrue(ToolUsed.effects(recipe()))
    }

    @Test
    fun `a Remove stroke is one step with its patch, Undo stroke takes it back, redo replays the patch`() = runTest {
        val model = RedInpainter()
        val vm = ready(model)
        vm.selectTool(EditorTool.EDIT)
        vm.selectEditSub(EditSub.REMOVE)
        vm.removeStroke(listOf(0.5 to 0.5, 0.6 to 0.5))
        assertEquals(RemoveOp.REMOVING, vm.uiState.value.edit.removeOp)
        advanceUntilIdle()
        val strokes = vm.uiState.value.session!!.current.tools.edit.remove.strokes
        assertEquals(1, strokes.size)
        assertEquals(RemoveStatus.APPLIED, strokes[0].result.status)
        assertNotNull(strokes[0].result.patch)
        assertEquals(RemoveOp.IDLE, vm.uiState.value.edit.removeOp)
        val withPatch = vm.uiState.value.preview!!
        vm.undoStroke(); advanceUntilIdle()
        assertTrue(vm.uiState.value.session!!.current.tools.edit.remove.strokes.isEmpty())
        vm.undo(); advanceUntilIdle()
        assertEquals(1, model.calls, "redo/undo never re-run the model")
        assertTrue(withPatch.pixels.contentEquals(vm.uiState.value.preview!!.pixels))
    }

    @Test
    fun `without the model a stroke shows the approved failure state and nothing changes`() = runTest {
        val vm = ready(null)
        val before = vm.uiState.value.session!!.current
        vm.removeStroke(listOf(0.5 to 0.5))
        advanceUntilIdle()
        assertEquals(RemoveOp.FAILED, vm.uiState.value.edit.removeOp)
        assertNotNull(vm.uiState.value.edit.pendingStroke)
        assertEquals(before, vm.uiState.value.session!!.current)
        assertTrue(ToolUsed.edit(before, pendingStroke = true), "the prototype counts the stroke being removed")
    }

    @Test
    fun `cancel while removing changes nothing`() = runTest {
        val vm = ready(RedInpainter())
        val before = vm.uiState.value.session!!.current
        vm.removeStroke(listOf(0.5 to 0.5))
        vm.cancelRemove()
        runCurrent()
        assertEquals(EditorViewModel.OPERATION_CANCELLED, vm.uiState.value.toast)
        advanceUntilIdle()
        assertEquals(RemoveOp.IDLE, vm.uiState.value.edit.removeOp)
        assertEquals(before, vm.uiState.value.session!!.current)
    }

    @Test
    fun `Save copy writes the cropped frame at full resolution`() = runTest {
        val vm = ready(null)
        vm.setCropAspect(CropAspect.SQUARE)
        advanceUntilIdle()
        vm.saveCopy()
        advanceUntilIdle()
        assertTrue(vm.uiState.value.overlay == EditorOverlay.SAVED, "overlay ${vm.uiState.value.overlay}")
        assertEquals(64 to 64, savedSize)
    }
}
