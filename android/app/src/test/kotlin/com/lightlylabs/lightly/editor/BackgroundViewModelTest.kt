package com.lightlylabs.lightly.editor

import androidx.lifecycle.SavedStateHandle
import com.lightlylabs.lightly.background.DepthEstimator
import com.lightlylabs.lightly.background.FloatPlane
import com.lightlylabs.lightly.background.SubjectSegmenter
import com.lightlylabs.lightly.develop.DevelopRenderer
import com.lightlylabs.lightly.export.ExportCoordinator
import com.lightlylabs.lightly.export.FullResolutionSource
import com.lightlylabs.lightly.export.JpegEncoder
import com.lightlylabs.lightly.export.MediaStoreGateway
import com.lightlylabs.lightly.export.NewImageSpec
import com.lightlylabs.lightly.export.Rgba8ExportFrame
import com.lightlylabs.lightly.export.SaveCopyExporter
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.DepthSource
import com.lightlylabs.lightly.session.ModelRef
import com.lightlylabs.lightly.session.Replacement
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
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Background in the session: separation states, the approved failure without a segmenter or depth,
 * commits of Focus & Blur and Change background, and that preview and Save copy apply the stage.
 * The depth estimator and segmenter here are test doubles (the real ones are pending, D3 / LiteRT).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class BackgroundViewModelTest {
    private val library = BundledPack.library

    @AfterTest
    fun tearDown() = Dispatchers.resetMain()

    private fun image(w: Int, h: Int) = Rgba8Image(w, h, ByteArray(w * h * 4) { i -> if (i % 4 == 3) -1 else (((i / 4) % w * 7 + (i / 4) / w * 3 + i % 4 * 50) % 251).toByte() })

    private class Gateway : MediaStoreGateway<String> {
        val files = mutableMapOf<String, ByteArrayOutputStream>()
        override fun insertPending(spec: NewImageSpec) = "content://new/${files.size + 1}"
        override fun openForWrite(handle: String): OutputStream = ByteArrayOutputStream().also { files[handle] = it }
        override fun publish(handle: String) = true
        override fun delete(handle: String) { files.remove(handle) }
    }

    private inner class Harness(test: TestScope, depth: DepthEstimator?, segmenter: SubjectSegmenter?) {
        val dispatcher = StandardTestDispatcher(test.testScheduler)
        val gateway = Gateway()
        val env = EditorEnvironment(
            photoLoader = PhotoLoader { asset ->
                LoadedPhoto(SourceRef(asset, SourceFingerprint("ab".repeat(32), 1000, 48, 32), 1), image(24, 16), image(48, 32), FullResolutionSource { image(96, 64) })
            },
            photoAccess = object : PhotoAccessGrants {
                override fun retain(assetId: String) = true
                override fun release(assetId: String) = Unit
            },
            autoDeveloper = AutoDeveloper { _, _ -> DevelopResult.NoModelInThisBuild },
            personDetector = PendingPersonDetector,
            library = CompletableDeferred(library),
            previewRenderer = DevelopRenderer(),
            renderDispatcher = dispatcher,
            prefetchDispatcher = dispatcher,
            exporter = ExportCoordinator(SaveCopyExporter(gateway, JpegEncoder<Rgba8ExportFrame> { f, _, sink -> sink.write(f.pixels) }), Rgba8ExportFrame.factory, dispatcher, maxTileEdge = 32),
            favourites = object : FavouritesStore {
                override val favourites: StateFlow<List<String>> = MutableStateFlow(emptyList())
                override fun update(change: (List<String>) -> List<String>) = Unit
            },
            debugBuild = true,
            depthEstimator = depth ?: com.lightlylabs.lightly.background.UnavailableDepthEstimator,
            depthModelRef = depth?.let { ModelRef("test-depth", "1") },
            segmenter = segmenter ?: com.lightlylabs.lightly.background.PendingSubjectSegmenter,
            segmenterModelRef = segmenter?.let { ModelRef("test-segmenter", "1") },
        )

        fun ready(scope: TestScope): EditorViewModel {
            Dispatchers.setMain(dispatcher)
            val vm = EditorViewModel(SavedStateHandle(), env, CoroutineScope(SupervisorJob() + dispatcher))
            vm.openPhoto("content://photo/1")
            scope.advanceUntilIdle()
            return vm
        }
    }

    /** Left half near, right half far, at the model's output size. */
    private val depthDouble = DepthEstimator { FloatPlane(518, 392, FloatArray(518 * 392) { if (it % 518 < 259) 3f else 1f }) }

    /** A disc subject in the middle. */
    private val segmenterDouble = SubjectSegmenter { _, w, h -> FloatPlane(w, h, FloatArray(w * h) { p -> val x = p % w - w / 2; val y = p / w - h / 2; if (x * x + y * y < 64) 1f else 0f }) }

    @Test
    fun `without a segmenter or depth the panel shows the approved failure, never a substitute`() = runTest {
        val vm = Harness(this, null, null).ready(this)
        vm.selectTool(EditorTool.BACKGROUND)
        assertEquals(SeparationState.Separating, vm.uiState.value.separation)
        advanceUntilIdle()
        val finished = assertIs<SeparationState.Finished>(vm.uiState.value.separation)
        assertEquals(false, finished.depthAvailable)
        assertEquals(BackgroundPanelState.Failed, BackgroundPanelState.of(vm.uiState.value.background, finished, null))
        vm.selectBackgroundSub(BackgroundSub.CHANGE)
        assertEquals(BackgroundPanelState.Failed, BackgroundPanelState.of(vm.uiState.value.background, finished, null))
    }

    @Test
    fun `the focal nearness without colour planes equals the full scene's`() {
        val w = 120
        val h = 90
        val nearness = FloatPlane(w, h, FloatArray(w * h) { p -> ((p % w) * 0.006f + (p / w) * 0.003f).coerceIn(0f, 1f) })
        val matte = FloatPlane(w, h, FloatArray(w * h) { p -> val x = p % w - 60; val y = p / w - 50; if (x * x + y * y < 600) 1f else if (x * x + y * y < 700) 0.5f else 0f })
        val scene = com.lightlylabs.lightly.background.Refocus.buildScene(com.lightlylabs.lightly.background.FloatImage(w, h, 3), nearness, matte)
        for ((x, y) in listOf(0.5 to 0.55, 0.1 to 0.1, 0.9 to 0.8, 0.62 to 0.3)) {
            assertEquals(com.lightlylabs.lightly.background.Refocus.focalNearness(scene, x, y), BackgroundSession.focalNearness(nearness, matte, x, y), 1e-9)
        }
        val plain = com.lightlylabs.lightly.background.Refocus.buildScene(com.lightlylabs.lightly.background.FloatImage(w, h, 3), nearness, null)
        assertEquals(com.lightlylabs.lightly.background.Refocus.focalNearness(plain, 0.3, 0.4), BackgroundSession.focalNearness(nearness, null, 0.3, 0.4), 1e-9)
    }

    @Test
    fun `a colour replacement renders behind the subject in the preview`() = runTest {
        val vm = Harness(this, depthDouble, segmenterDouble).ready(this)
        vm.selectTool(EditorTool.BACKGROUND)
        vm.selectBackgroundSub(BackgroundSub.CHANGE)
        advanceUntilIdle()
        vm.chooseBackgroundColour("#3C4A55"); advanceUntilIdle()
        val preview = assertNotNull(vm.uiState.value.preview)
        // A corner is background: it takes the colour (graded by the photo's global colour, here identity).
        val o = 0
        assertEquals(listOf(0x3C, 0x4A, 0x55), (0 until 3).map { preview.pixels[o + it].toInt() and 0xff }, "corner pixel")
    }

    @Test
    fun `cancelling separation changes nothing and says so`() = runTest {
        val vm = Harness(this, depthDouble, segmenterDouble).ready(this)
        vm.selectTool(EditorTool.BACKGROUND)
        vm.cancelSeparation()
        assertEquals(SeparationState.NotStarted, vm.uiState.value.separation)
        assertEquals(EditorViewModel.OPERATION_CANCELLED, vm.uiState.value.toast)
        assertEquals(1, vm.uiState.value.session!!.history.entries.size)
    }

    @Test
    fun `depth without a subject offers Focus and Blur, and Change background shows the failure`() = runTest {
        val vm = Harness(this, depthDouble, null).ready(this)
        vm.selectTool(EditorTool.BACKGROUND); advanceUntilIdle()
        val finished = assertIs<SeparationState.Finished>(vm.uiState.value.separation)
        assertEquals(BackgroundPanelState.Focus, BackgroundPanelState.of(vm.uiState.value.background, finished, null))
        vm.selectBackgroundSub(BackgroundSub.CHANGE)
        assertEquals(BackgroundPanelState.Failed, BackgroundPanelState.of(vm.uiState.value.background, finished, null))
    }

    @Test
    fun `blur commits one step, records the depth source, and changes the preview and the saved copy`() = runTest {
        val harness = Harness(this, depthDouble, null)
        val vm = harness.ready(this)
        val before = vm.uiState.value.preview!!.pixels.copyOf()
        vm.selectTool(EditorTool.BACKGROUND); advanceUntilIdle()
        vm.onBackgroundSlider("blur", 30.0); vm.onBackgroundSlider("blur", 80.0)
        assertEquals(1, vm.uiState.value.session!!.history.entries.size, "dragging never commits")
        vm.onBackgroundSliderRelease("blur", 80.0); advanceUntilIdle()
        val recipe = vm.uiState.value.session!!.current.tools.background
        assertEquals(80.0, recipe.focus.blur)
        assertEquals(DepthSource.ESTIMATED, recipe.focus.depth.source)
        assertEquals(ModelRef("test-depth", "1"), recipe.focus.depth.map?.model)
        assertEquals(2, vm.uiState.value.session!!.history.entries.size)
        assertNotEquals(before.toList(), vm.uiState.value.preview!!.pixels.toList())
        vm.saveCopy(); advanceUntilIdle()
        assertEquals(EditorOverlay.SAVED, vm.uiState.value.overlay)
        val written = harness.gateway.files.values.single().toByteArray()
        assertNotEquals(image(96, 64).pixels.toList(), written.toList(), "the saved copy carries the blur")
    }

    @Test
    fun `tapping the photo stores the target and the depth under it`() = runTest {
        val vm = Harness(this, depthDouble, null).ready(this)
        vm.selectTool(EditorTool.BACKGROUND); advanceUntilIdle()
        vm.setFocusTarget(0.25, 0.5)
        val focus = vm.uiState.value.session!!.current.tools.background.focus
        assertEquals(0.25, focus.target!!.x)
        assertNotNull(focus.depth.focusDepth)
        assertTrue(focus.depth.focusDepth!! < 0.5, "the left half is near: small depth")
    }

    @Test
    fun `with a subject, Change background commits a colour, gradient or bundled image and can be removed`() = runTest {
        val vm = Harness(this, depthDouble, segmenterDouble).ready(this)
        vm.selectTool(EditorTool.BACKGROUND); advanceUntilIdle()
        vm.selectBackgroundSub(BackgroundSub.CHANGE)
        val finished = assertIs<SeparationState.Finished>(vm.uiState.value.separation)
        assertEquals(BackgroundPanelState.Change(ReplacementKind.IMAGE), BackgroundPanelState.of(vm.uiState.value.background, finished, null))
        vm.chooseBackgroundColour("#3C4A55"); advanceUntilIdle()
        assertEquals(Replacement.Colour("#3C4A55"), vm.uiState.value.session!!.current.tools.background.replacement)
        assertNotNull(vm.uiState.value.session!!.current.tools.background.subject.matte)
        vm.chooseBackgroundGradient(0)
        assertIs<Replacement.Gradient>(vm.uiState.value.session!!.current.tools.background.replacement)
        vm.removeBackgroundChange()
        assertNull(vm.uiState.value.session!!.current.tools.background.replacement)
        assertEquals(4, vm.uiState.value.session!!.history.entries.size)
        vm.undo()
        assertIs<Replacement.Gradient>(vm.uiState.value.session!!.current.tools.background.replacement)
    }

    @Test
    fun `a Refine edges stroke is one undo step and changes the refined matte`() = runTest {
        val vm = Harness(this, depthDouble, segmenterDouble).ready(this)
        vm.selectTool(EditorTool.BACKGROUND); advanceUntilIdle()
        vm.selectBackgroundSub(BackgroundSub.REFINE)
        val before = vm.refinedMatte()!!.values.sum()
        vm.setBrushMode(BrushMode.ERASE)
        vm.addRefineStroke(listOf(0.4 to 0.5, 0.6 to 0.5))
        val stroke = vm.uiState.value.session!!.current.tools.background.subject.refinements.single()
        assertEquals(com.lightlylabs.lightly.session.RefineMode.ERASE, stroke.mode)
        assertEquals(2, vm.uiState.value.session!!.history.entries.size)
        assertTrue(vm.refinedMatte()!!.values.sum() < before, "erasing removes subject")
        vm.undo()
        assertTrue(vm.uiState.value.session!!.current.tools.background.subject.refinements.isEmpty())
    }
}
