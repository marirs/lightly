package com.lightlylabs.lightly.editor

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipe
import androidx.compose.ui.test.pinch
import androidx.compose.ui.test.doubleClick
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
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
import com.lightlylabs.lightly.session.SourceFingerprint
import com.lightlylabs.lightly.session.SourceRef
import com.lightlylabs.lightly.shell.LightlyTheme
import com.lightlylabs.lightly.shell.ShellLayout
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.junit.Rule
import org.junit.Test
import kotlin.test.assertTrue
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.OutputStream
import java.util.concurrent.Executors
import kotlin.test.assertEquals

/**
 * The editor on Robolectric (phone layout): the approved controls and copy, the ruler as an accessible
 * range, Compare as an accessible toggle, and Undo after a commit. Pixels are compared on emulators
 * (docs/v1/slice2-android.md).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w427dp-h952dp")
class EditorScreenTest {
    @get:Rule
    val compose = createComposeRule()

    private val render = Executors.newSingleThreadExecutor().asCoroutineDispatcher()

    private fun image(w: Int, h: Int) = Rgba8Image(w, h, ByteArray(w * h * 4) { if (it % 4 == 3) -1 else (it % 200).toByte() })

    private fun editor(): EditorViewModel {
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
            photoLoader = PhotoLoader { asset ->
                LoadedPhoto(SourceRef(asset, SourceFingerprint("ab".repeat(32), 10, 30, 45), 1), image(20, 30), image(30, 45), FullResolutionSource { image(30, 45) })
            },
            photoAccess = object : PhotoAccessGrants {
                override fun retain(assetId: String) = true
                override fun release(assetId: String) = Unit
            },
            autoDeveloper = AutoDeveloper { _, _, _ -> DevelopResult.NoModelInThisBuild },
            personDetector = PendingPersonDetector,
            library = CompletableDeferred(BundledPack.library),
            previewRenderer = DevelopRenderer(),
            renderDispatcher = render,
            prefetchDispatcher = render,
            exporter = ExportCoordinator(SaveCopyExporter(gateway, JpegEncoder<Rgba8ExportFrame> { _, _, _ -> }), Rgba8ExportFrame.factory, render),
            favourites = favourites,
            debugBuild = true,
        )
        return EditorViewModel(SavedStateHandle(), env, CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate))
    }

    private fun show(vm: EditorViewModel) {
        compose.setContent {
            LightlyTheme(dark = false) { EditorScreen(vm, ShellLayout.Compact, EditorActions({}, {}, {})) }
        }
        vm.openPhoto("content://photo/1")
        compose.waitUntil(10_000) { vm.uiState.value.phase == EditorPhase.Ready }
        compose.waitForIdle()
    }

    @Test
    fun `reset all confirms and one undo restores scoped edits`() {
        val vm = editor()
        show(vm)
        compose.runOnIdle {
            vm.toggleEffect(EffectsSub.GRAIN)
            vm.toggleEffect(EffectsSub.VIGNETTE)
        }
        val before = vm.uiState.value.session!!.current
        compose.runOnIdle { vm.resetEdits("effects", "grain") }
        assertTrue(!vm.uiState.value.session!!.current.tools.effects.grain.enabled)
        assertEquals(before.tools.effects.vignette, vm.uiState.value.session!!.current.tools.effects.vignette)
        compose.runOnIdle { vm.undo() }
        assertEquals(before, vm.uiState.value.session!!.current)
        compose.onNodeWithTag("editor-reset-all").performClick()
        compose.onNodeWithText("Keep editing").performClick()
        assertEquals(before, vm.uiState.value.session!!.current)
        compose.onNodeWithTag("editor-reset-all").performClick()
        compose.onNodeWithText("Reset all edits").performClick()
        assertTrue(!vm.canReset("all"))
        compose.runOnIdle { vm.undo() }
        assertEquals(before, vm.uiState.value.session!!.current)
        compose.runOnIdle { vm.redo() }
        assertTrue(!vm.canReset("all"))
    }

    @Test
    fun `favourites starts at first and star edits the shown preset`() {
        val vm = editor()
        show(vm)
        compose.runOnIdle {
            vm.selectCategory("landscape")
            vm.onRulerDrag(2); vm.onRulerRelease(2); vm.toggleStar()
            vm.onRulerDrag(4); vm.onRulerRelease(4); vm.toggleStar()
            vm.selectCategory("favourites")
        }
        assertEquals(1, vm.panelModel()!!.stop)
        assertEquals(BundledPack.preset("landscape", 2).displayName, vm.panelModel()!!.name)
        compose.onNodeWithTag("develop-apply").assertExists()
        compose.onNodeWithText("Reset").assertExists()
        compose.runOnIdle { vm.toggleStar() }
        assertEquals(1, vm.panelModel()!!.presets.size)
        assertEquals(BundledPack.preset("landscape", 4).displayName, vm.panelModel()!!.name)
    }

    @Test
    fun `inspection zoom survives tools and never commits an edit`() {
        val vm = editor()
        show(vm)
        val before = vm.uiState.value.session
        val viewport = compose.onNodeWithTag("editor-inspection")
        viewport.performTouchInput {
            pinch(center - Offset(30f, 0f), center + Offset(30f, 0f),
                center - Offset(80f, 0f), center + Offset(80f, 0f), durationMillis = 400)
        }
        compose.waitForIdle()
        val zoom = viewport.fetchSemanticsNode().config[SemanticsProperties.StateDescription]
        assertTrue(zoom != "100 percent zoom", zoom)
        assertEquals(before, vm.uiState.value.session)
        compose.onNodeWithTag(EditorTags.tool(EditorTool.EFFECTS)).performClick()
        viewport.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, zoom))
        compose.onNodeWithTag(EditorTags.tool(EditorTool.DEVELOP)).performClick()
        viewport.performTouchInput { doubleClick(center) }
        viewport.assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "100 percent zoom"))
        assertEquals(before, vm.uiState.value.session)
    }

    @Test
    fun `pinch in crop and remove never commits a crop or stroke`() {
        val vm = editor()
        show(vm)
        compose.onNodeWithTag(EditorTags.tool(EditorTool.EDIT)).performClick()
        val before = vm.uiState.value.session
        fun pinch() = compose.onNodeWithTag("editor-inspection").performTouchInput {
            pinch(center - Offset(30f, 0f), center + Offset(30f, 0f),
                center - Offset(80f, 0f), center + Offset(80f, 0f), durationMillis = 400)
        }
        pinch()
        compose.waitForIdle()
        assertEquals(before, vm.uiState.value.session)
        compose.onNodeWithText("Remove").performClick()
        pinch()
        compose.waitForIdle()
        assertEquals(before, vm.uiState.value.session)
        assertTrue(vm.uiState.value.edit.pendingStroke == null)
    }

    @Test
    fun `adjacent sliders only change the touched row and border has no signature switch`() {
        val vm = editor()
        show(vm)
        compose.onNodeWithTag(EditorTags.tool(EditorTool.EFFECTS)).performClick()
        val rotation = vm.uiState.value.session!!.current.tools.effects.lightLeak.rotation
        val intensity = vm.uiState.value.session!!.current.tools.effects.lightLeak.intensity
        compose.onNodeWithTag("effects-slider-leakIntensity").performTouchInput {
            swipe(Offset(width * 0.3f, height * 0.5f), Offset(width * 0.8f, height * 0.5f), 300)
        }
        compose.waitForIdle()
        assertEquals(rotation, vm.uiState.value.session!!.current.tools.effects.lightLeak.rotation)
        assertTrue(intensity != vm.uiState.value.session!!.current.tools.effects.lightLeak.intensity)
        val top = vm.uiState.value.session!!.current.tools.effects.lightLeak.intensity
        compose.onNodeWithTag("effects-slider-leakRotation").performTouchInput {
            swipe(Offset(width * 0.5f, height * 0.5f), Offset(width * 0.2f, height * 0.5f), 300)
        }
        compose.waitForIdle()
        assertEquals(top, vm.uiState.value.session!!.current.tools.effects.lightLeak.intensity)
        compose.runOnIdle { vm.selectTool(EditorTool.BORDER); vm.chooseBorder(com.lightlylabs.lightly.session.BorderType.POLAROID) }
        compose.onNodeWithText("Signature on the margin").assertDoesNotExist()
        compose.onNodeWithTag("border-signature-on-margin").assertDoesNotExist()
    }

    @Test
    fun `clear preset preserves other edits and undo restores it`() {
        val vm = editor(); show(vm)
        compose.onNodeWithTag(EditorTags.RULER).performSemanticsAction(SemanticsActions.SetProgress) { it(37f) }
        val before = vm.uiState.value.session!!.current
        compose.onNodeWithTag("develop-clear").performClick()
        compose.waitForIdle()
        val cleared = vm.uiState.value.session!!.current
        assertEquals(null, cleared.look)
        assertEquals(before.tools, cleared.tools)
        compose.onNodeWithTag(EditorTags.UNDO).performClick()
        assertEquals(before.look, vm.uiState.value.session!!.current.look)
    }

    @Test
    fun `clear signature keeps saved drawing and delete removes it`() {
        val vm = editor(); show(vm)
        compose.runOnIdle {
            vm.selectTool(EditorTool.WATERMARK)
            vm.chooseWatermark(com.lightlylabs.lightly.session.WatermarkType.SIGNATURE)
            vm.padStroke(listOf(listOf(com.lightlylabs.lightly.signatures.DrawnSignature.Point(0.0, 0.0), com.lightlylabs.lightly.signatures.DrawnSignature.Point(40.0, 25.0))))
            vm.saveDrawnSignature()
        }
        compose.onNodeWithTag("watermark-signature-clear").performClick()
        compose.waitForIdle()
        assertEquals(com.lightlylabs.lightly.session.WatermarkType.NONE, vm.uiState.value.session!!.current.tools.watermark.type)
        assertTrue(vm.signatures.value.drawn != null)
        compose.runOnIdle { vm.undo() }
        assertEquals(com.lightlylabs.lightly.session.WatermarkType.SIGNATURE, vm.uiState.value.session!!.current.tools.watermark.type)
        compose.runOnIdle { vm.deleteDrawnSignature() }
        assertEquals(null, vm.signatures.value.drawn)
        assertEquals(com.lightlylabs.lightly.session.WatermarkType.NONE, vm.uiState.value.session!!.current.tools.watermark.type)
    }

    @Test
    fun `the editor shows the approved controls, copy and every tool`() {
        val vm = editor()
        show(vm)
        listOf(EditorTags.CLOSE, EditorTags.UNDO, EditorTags.REDO, EditorTags.COMPARE, EditorTags.SAVE, EditorTags.MORE, EditorTags.RULER).forEach {
            compose.onNodeWithTag(it).assertIsDisplayed()
        }
        compose.onNodeWithTag(EditorTags.UNDO).assertIsNotEnabled()
        compose.onNodeWithText("Save copy").assertIsDisplayed()
        compose.onNodeWithText("Original").assertDoesNotExist()
        compose.onNodeWithText("Automatic correction isn't available on this device. Presets still work.").assertDoesNotExist() // no standing notice (owner amendment 2026-10-05)
        compose.onNodeWithText("0 / 518").assertIsDisplayed()
        EditorTool.entries.forEach { compose.onNodeWithTag(EditorTags.tool(it)).assertExists() }
    }

    @Test
    fun `the ruler is an accessible range whose release is one undo step`() {
        val vm = editor()
        show(vm)
        compose.onNodeWithTag(EditorTags.RULER).performSemanticsAction(SemanticsActions.SetProgress) { it(37f) }
        compose.waitForIdle()
        compose.onNodeWithText("05 Hiking 05").assertIsDisplayed()
        compose.onNodeWithText("37 / 518").assertIsDisplayed()
        compose.onNodeWithTag(EditorTags.UNDO).assertIsEnabled()
        assertEquals(2, vm.uiState.value.session!!.history.entries.size)
        compose.onNodeWithTag(EditorTags.UNDO).performClick()
        compose.waitForIdle()
        compose.onNodeWithText("0 / 518").assertIsDisplayed()
    }

    @Test
    fun `Compare is an accessible toggle that shows the Original badge`() {
        val vm = editor()
        show(vm)
        compose.onNodeWithTag(EditorTags.COMPARE).assert(SemanticsMatcher.keyIsDefined(SemanticsActions.OnClick))
        compose.onNodeWithTag(EditorTags.COMPARE).performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()
        // The owner removed the stop-0 title; Original appears only on Compare.
        assertEquals(1, compose.onAllNodesWithText("Original").fetchSemanticsNodes().size)
    }

    @Test
    fun `without a person detector, debug builds offer Portrait with the approved no-face state`() {
        val vm = editor()
        show(vm)
        // PendingPersonDetector: presence is unknown, so debug builds offer Portrait; nothing was found.
        compose.onNodeWithTag(EditorTags.tool(EditorTool.PORTRAIT)).performClick()
        compose.waitForIdle()
        compose.onNodeWithText("No face can be edited in this photo.", substring = true).assertIsDisplayed()
    }

    @Test
    fun `Edit and Effects open their approved panels with the approved copy`() {
        val vm = editor()
        show(vm)
        compose.onNodeWithTag(EditorTags.tool(EditorTool.EDIT)).performClick()
        compose.waitForIdle()
        listOf("Crop", "Rotate", "Straighten", "Perspective", "Adjust", "Remove", "Drag corners or edges to crop.").forEach {
            assertTrue(compose.onAllNodesWithText(it).fetchSemanticsNodes().isNotEmpty(), it)
        }
        compose.onNodeWithText("Remove").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Undo stroke").assertExists()
        compose.onNodeWithText("Brush over anything you want removed.").assertExists()
        compose.onNodeWithTag(EditorTags.tool(EditorTool.EFFECTS)).performClick()
        compose.waitForIdle()
        listOf("Light Leaks", "Grain", "Vignette", "Warm edge", "Amber flare", "Rose", "Prism", "Intensity", "Rotation", "Drag on the photo to move the leak.").forEach {
            assertTrue(compose.onAllNodesWithText(it).fetchSemanticsNodes().isNotEmpty(), it)
        }
        compose.onNodeWithTag("effects-on-off").assertDoesNotExist()
        compose.onNodeWithText("Rose").performClick()
        compose.waitForIdle()
        assertTrue(vm.uiState.value.session!!.current.tools.effects.lightLeak.enabled)
    }
}
