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
            border = tools.border.copy(type = com.lightlylabs.lightly.session.BorderType.FRAME, colour = "#111111", width = 3.0, spacing = 5.0),
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
    private var savedPixels: ByteArray? = null

    private fun TestScope.ready(inpainter: Inpainter?, savedState: SavedStateHandle = SavedStateHandle(), patchDirectory: java.io.File? = null, open: Boolean = true): EditorViewModel {
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
                SaveCopyExporter(gateway, JpegEncoder<Rgba8ExportFrame> { frame, _, sink -> savedSize = frame.width to frame.height; savedPixels = frame.pixels.copyOf(); sink.write(frame.pixels) }),
                Rgba8ExportFrame.factory, dispatcher, maxTileEdge = 32,
            ),
            favourites = Favourites(),
            debugBuild = true,
            inpainter = { inpainter },
            removePatchDirectory = patchDirectory,
        )
        val vm = EditorViewModel(savedState, env, CoroutineScope(SupervisorJob() + dispatcher))
        if (open) vm.openPhoto("content://photo/1")
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

    /** Mean of max − min over the channels (0 for black and white). */
    private fun meanChroma(image: Rgba8Image): Double {
        var total = 0.0
        for (p in 0 until image.width * image.height) {
            val r = image.pixels[p * 4].toInt() and 0xff; val g = image.pixels[p * 4 + 1].toInt() and 0xff; val b = image.pixels[p * 4 + 2].toInt() and 0xff
            total += (maxOf(r, g, b) - minOf(r, g, b)) / 255.0
        }
        return total / (image.width * image.height)
    }

    @Test
    fun `Selective Colour keeps a picked colour, greys the rest, and a pick, a removal and Clear are one step each`() = runTest {
        val vm = ready(null)
        vm.selectTool(EditorTool.EFFECTS)
        vm.selectEffectsSub(EffectsSub.SELECTIVE)
        advanceUntilIdle()
        assertTrue(vm.picksOnTap(), "the first tap on the photo picks")
        val before = meanChroma(vm.uiState.value.preview!!)
        vm.pickSelectiveColour(0.5, 0.5)
        advanceUntilIdle()
        val selective = vm.uiState.value.session!!.current.tools.effects.selectiveColour!!
        assertEquals(1, selective.colours.size)
        assertEquals(0.5, selective.colours[0].x, 1e-9); assertEquals(0.5, selective.colours[0].y, 1e-9)
        assertFalse(vm.picksOnTap(), "after the first colour, only (+) arms a pick")
        assertTrue(meanChroma(vm.uiState.value.preview!!) < before, "outside the kept colour the preview is black and white")
        vm.toggleAddingColour()
        assertTrue(vm.picksOnTap())
        vm.pickSelectiveColour(0.1, 0.9); advanceUntilIdle()
        assertEquals(2, vm.uiState.value.session!!.current.tools.effects.selectiveColour!!.colours.size)
        vm.removeSelectiveColour(0); advanceUntilIdle()
        assertEquals(1, vm.uiState.value.session!!.current.tools.effects.selectiveColour!!.colours.size)
        vm.undo(); advanceUntilIdle()
        assertEquals(2, vm.uiState.value.session!!.current.tools.effects.selectiveColour!!.colours.size, "a removal is one step")
        vm.clearSelectiveColour(); advanceUntilIdle()
        assertEquals(null, vm.uiState.value.session!!.current.tools.effects.selectiveColour)
        vm.undo(); vm.undo(); vm.undo(); advanceUntilIdle()
        assertEquals(null, vm.uiState.value.session!!.current.tools.effects.selectiveColour, "each pick was one step")
    }

    private fun EditorViewModel.kept() = uiState.value.session!!.current.tools.effects.selectiveColour?.colours.orEmpty()

    @Test
    fun `Clear while a pick is still sampling discards it`() = runTest {
        val vm = ready(null)
        vm.pickSelectiveColour(0.5, 0.5); advanceUntilIdle()
        assertEquals(1, vm.kept().size)
        vm.toggleAddingColour()
        vm.pickSelectiveColour(0.2, 0.8)   // still sampling…
        vm.clearSelectiveColour()          // …when Clear is tapped
        advanceUntilIdle()
        assertTrue(vm.kept().isEmpty(), "a pick sampled before Clear is discarded")
    }

    @Test
    fun `Undo while a pick is still sampling discards it and keeps the redo step`() = runTest {
        val vm = ready(null)
        vm.toggleEffect(EffectsSub.VIGNETTE); advanceUntilIdle()
        vm.pickSelectiveColour(0.5, 0.5)
        vm.undo()
        advanceUntilIdle()
        assertTrue(vm.kept().isEmpty())
        assertFalse(vm.uiState.value.session!!.current.tools.effects.vignette.enabled, "Undo stays undone")
        assertTrue(vm.uiState.value.canRedo, "the redo step is not destroyed by a late pick")
    }

    @Test
    fun `switching photos while a pick is still sampling discards it`() = runTest {
        val vm = ready(null)
        vm.pickSelectiveColour(0.5, 0.5)
        vm.openPhoto("content://photo/2")
        advanceUntilIdle()
        assertTrue(vm.kept().isEmpty())
    }

    @Test
    fun `rapid picks land in tap order and count towards the eight-colour limit`() = runTest {
        val vm = ready(null)
        repeat(6) { i -> vm.selectEffectsSub(EffectsSub.SELECTIVE); vm.toggleAddingColour(); vm.pickSelectiveColour(0.05 + i * 0.01, 0.5); advanceUntilIdle() }
        assertEquals(6, vm.kept().size)
        listOf(0.1 to 0.1, 0.9 to 0.9, 0.5 to 0.5).forEach { (x, y) -> vm.pickSelectiveColour(x, y) }
        advanceUntilIdle()
        val kept = vm.kept()
        assertEquals(EditorViewModel.MAX_KEPT_COLOURS, kept.size, "the third rapid pick is refused at the limit")
        assertEquals(0.1, kept[6].x, 1e-9); assertEquals(0.9, kept[7].x, 1e-9)   // tap order
        vm.undo(); advanceUntilIdle()
        assertEquals(7, vm.kept().size, "each pick is its own undo step")
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

    /** A model that must never run: a recovered session replays stored patches. */
    private class ForbiddenInpainter : Inpainter {
        override val model = ModelRef("test-red", "1")
        override fun inpaint(image: FloatArray, mask: FloatArray): FloatArray = error("the model ran again after recovery")
    }

    @Test
    fun `a Remove fill survives the app being killed and recovered, without re-running the model`() = runTest {
        val directory = kotlin.io.path.createTempDirectory("remove-patches").toFile()
        val firstState = SavedStateHandle()
        val first = ready(RedInpainter(), firstState, directory)
        first.removeStroke(listOf(0.4 to 0.4, 0.6 to 0.45))
        advanceUntilIdle()
        val digest = first.uiState.value.session!!.current.tools.edit.remove.strokes.single().result.patch!!.sha256
        val before = first.uiState.value.preview!!
        assertTrue(java.io.File(directory, "$digest.patch").isFile, "the patch is stored beside the edit")

        // Process death: only the saved-state bundle and the app's files survive. A new view model, a new
        // patch store (empty memory) and a model that fails if it is called.
        val restoredState = SavedStateHandle(firstState.keys().associateWith { firstState.get<Any>(it) })
        Dispatchers.resetMain()
        val second = ready(ForbiddenInpainter(), restoredState, directory, open = false)
        val recovered = second.uiState.value
        assertEquals(EditorPhase.Ready, recovered.phase)
        assertEquals(digest, recovered.session!!.current.tools.edit.remove.strokes.single().result.patch!!.sha256)
        assertTrue(before.pixels.contentEquals(recovered.preview!!.pixels), "the recovered preview shows the same fill")

        // Choosing another photo starts a new session and deletes the stored patches.
        second.openPhoto("content://photo/2")
        advanceUntilIdle()
        assertFalse(java.io.File(directory, "$digest.patch").exists())
    }

    @Test
    fun `four kept colours, remove one, Undo, kill and restore give the same colours, preview and Save copy`() = runTest {
        val firstState = SavedStateHandle()
        val first = ready(null, firstState)
        first.selectTool(EditorTool.EFFECTS); first.selectEffectsSub(EffectsSub.SELECTIVE)
        listOf(0.1 to 0.1, 0.9 to 0.1, 0.1 to 0.9, 0.9 to 0.9).forEachIndexed { i, (x, y) ->
            if (i > 0) first.toggleAddingColour()
            first.pickSelectiveColour(x, y); advanceUntilIdle()
        }
        val four = first.kept()
        assertEquals(4, four.size, "four colours kept together")
        assertEquals(4, four.map { it.oklab }.toSet().size, "four different colours")
        first.removeSelectiveColour(1); advanceUntilIdle()
        assertEquals(listOf(four[0], four[2], four[3]), first.kept(), "the × removes just that colour")
        first.undo(); advanceUntilIdle()
        assertEquals(four, first.kept(), "Undo brings it back in place")
        val preview = first.uiState.value.preview!!
        first.saveCopy(); advanceUntilIdle()
        val saved = savedPixels!!.copyOf()

        // Process death: only the saved-state bundle survives.
        val restoredState = SavedStateHandle(firstState.keys().associateWith { firstState.get<Any>(it) })
        Dispatchers.resetMain()
        val second = ready(null, restoredState, open = false)
        assertEquals(four, second.kept(), "the four colours are restored")
        assertTrue(preview.pixels.contentEquals(second.uiState.value.preview!!.pixels), "the restored preview is identical")
        savedPixels = null
        second.saveCopy(); advanceUntilIdle()
        assertTrue(saved.contentEquals(savedPixels!!), "the restored Save copy is identical")
        second.redo(); advanceUntilIdle()
        assertEquals(3, second.kept().size, "the removal can be redone after restore")
    }

    @Test
    fun `a stored patch whose bytes do not match its digest is skipped, never substituted`() {
        val directory = kotlin.io.path.createTempDirectory("remove-patches").toFile()
        val patch = RemoveEngine.patch(image(300, 200, 3), listOf(0.5 to 0.5), 10.0 / 300, RedInpainter())
        RemovePatchStore(directory).put(patch)
        val file = java.io.File(directory, "${patch.sha256}.patch")
        val bytes = file.readBytes().also { it[it.size - 2] = (it[it.size - 2] + 1).toByte() }
        file.writeBytes(bytes)
        assertEquals(null, RemovePatchStore(directory)[patch.sha256])
    }

    @Test
    fun `Border tabs commit one step each, Polaroid resets to white, and Save copy writes the canvas`() = runTest {
        val vm = ready(null)
        vm.selectTool(EditorTool.BORDER)
        vm.chooseBorder(com.lightlylabs.lightly.session.BorderType.SOLID)
        vm.setBorderColour("#111111")
        vm.onBorderSliderRelease("width", 5.0)
        advanceUntilIdle()
        val solid = vm.uiState.value.session!!.current.tools.border
        assertEquals("#111111", solid.colour); assertEquals(5.0, solid.width)
        // The 48 × 32 preview proxy: 5 % of the width, rounded, is 2 px on every side.
        assertEquals(52 to 36, vm.uiState.value.preview!!.width to vm.uiState.value.preview!!.height)
        vm.chooseBorder(com.lightlylabs.lightly.session.BorderType.POLAROID)
        advanceUntilIdle()
        assertEquals("#FFFFFF", vm.uiState.value.session!!.current.tools.border.colour)
        vm.undo(); advanceUntilIdle()
        assertEquals(com.lightlylabs.lightly.session.BorderType.SOLID, vm.uiState.value.session!!.current.tools.border.type)
        vm.saveCopy(); advanceUntilIdle()
        // Full resolution 96 × 64: 4.8 → 5 px on every side.
        assertEquals(106 to 74, savedSize)
    }
}
