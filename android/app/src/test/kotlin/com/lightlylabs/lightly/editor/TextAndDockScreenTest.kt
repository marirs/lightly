package com.lightlylabs.lightly.editor

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.doubleClick
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
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
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.OutputStream
import java.util.concurrent.Executors
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * Owner amendments 2026-10-11 on the phone editor (Robolectric): the eight-tool dock in its order, the Text tool's
 * add → type → Done flow, and the stage's double tap outside the photo (theme cycle) versus on it (inspection zoom).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w427dp-h952dp")
class TextAndDockScreenTest {
    @get:Rule
    val compose = createComposeRule()

    private val render = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    private var themeCycles = 0

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
            // A portrait photo on a phone: the stage has empty space beside it.
            photoLoader = PhotoLoader { asset -> LoadedPhoto(SourceRef(asset, SourceFingerprint("ab".repeat(32), 10, 30, 45), 1), image(20, 30), image(30, 45), FullResolutionSource { image(30, 45) }) },
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
            LightlyTheme(dark = false) { EditorScreen(vm, ShellLayout.Compact, EditorActions({}, {}, {}, cycleTheme = { themeCycles++ })) }
        }
        vm.openPhoto("content://photo/1")
        compose.waitUntil(10_000) { vm.uiState.value.phase == EditorPhase.Ready }
        compose.waitForIdle()
    }

    @Test
    fun `the dock holds the eight tools in the approved order, Text between Watermark and Border`() {
        assertEquals(listOf("Develop", "Background", "Portrait", "Edit", "Effects", "Watermark", "Text", "Border"), EditorTool.entries.map { it.label })
        val vm = editor(); show(vm)
        EditorTool.entries.forEach { compose.onNodeWithTag(EditorTags.tool(it)).assertExists() }
        compose.onNodeWithTag(EditorTags.tool(EditorTool.BORDER)).performScrollTo().performClick()
        compose.waitForIdle()
        assertEquals(EditorTool.BORDER, vm.uiState.value.tool)
    }

    @Test
    fun `the dock scrolls a selected tool fully into view`() {
        // 58 dp items after 6 dp padding, a 412 dp viewport.
        assertNull(DockScroll.targetFor(0, 58f, 6f, 0f, 412f))
        assertEquals(6f + 8 * 58f + 6f - 412f, DockScroll.targetFor(7, 58f, 6f, 0f, 412f))
        assertEquals(6f + 2 * 58f - 6f, DockScroll.targetFor(2, 58f, 6f, 200f, 412f))
    }

    @Test
    fun `Text - Add text, type and Done add the layer, then its chip, input box and fonts show`() {
        val vm = editor(); show(vm)
        compose.onNodeWithTag(EditorTags.tool(EditorTool.TEXT)).performScrollTo().performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Add text").assertIsDisplayed()
        compose.onNodeWithText("Add text, then drag it anywhere on the photo. Pinch to resize or turn it.").assertIsDisplayed()
        compose.onNodeWithTag(TextTags.ADD_TEXT).performClick()
        compose.waitForIdle()
        // The sheet ("Cancel · Text · Done"): Done waits for text.
        compose.onNodeWithTag("${TextTags.SHEET}-editor").assertExists()
        compose.onNodeWithTag("${TextTags.SHEET}-done").assertIsNotEnabled()
        compose.onNodeWithTag("${TextTags.SHEET}-editor").performTextInput("Summer in Lisbon")
        compose.onNodeWithTag("${TextTags.SHEET}-done").assertIsEnabled().performClick()
        compose.waitForIdle()
        val layer = vm.uiState.value.session!!.current.tools.text.layers.single()
        assertEquals("Summer in Lisbon", layer.text)
        assertEquals(2, vm.uiState.value.session!!.history.entries.size)
        compose.onNodeWithTag(TextTags.layer(0)).assertIsDisplayed()
        compose.onNodeWithTag(TextTags.ADD_CHIP).assertIsDisplayed()
        compose.onNodeWithTag(TextTags.INPUT).assertIsDisplayed()
        compose.onNodeWithTag(TextTags.font(com.lightlylabs.lightly.session.TextFont.PLAYFAIR_DISPLAY)).assertExists()
        // The selected layer's handles on the photo; ✕ deletes it (one more step).
        compose.onNodeWithTag(TextTags.DELETE).assertExists().performClick()
        compose.waitForIdle()
        assertEquals(0, vm.uiState.value.session!!.current.tools.text.layers.size)
        assertEquals(3, vm.uiState.value.session!!.history.entries.size)
    }

    @Test
    fun `Text - Cancel adds nothing`() {
        val vm = editor(); show(vm)
        compose.onNodeWithTag(EditorTags.tool(EditorTool.TEXT)).performScrollTo().performClick()
        compose.onNodeWithTag(TextTags.ADD_TEXT).performClick()
        compose.onNodeWithTag("${TextTags.SHEET}-editor").performTextInput("Draft")
        compose.onNodeWithTag("${TextTags.SHEET}-cancel").performClick()
        compose.waitForIdle()
        assertEquals(0, vm.uiState.value.session!!.current.tools.text.layers.size)
        assertEquals(1, vm.uiState.value.session!!.history.entries.size)
    }

    @Test
    fun `a double tap on the stage outside the photo cycles the theme, on the photo it does not`() {
        val vm = editor(); show(vm)
        compose.onNodeWithTag(EditorTags.STAGE).performTouchInput { doubleClick(Offset(width * 0.03f, height * 0.5f)) }
        compose.waitForIdle()
        assertEquals(1, themeCycles)
        compose.onNodeWithTag(EditorTags.STAGE).performTouchInput { doubleClick(center) }
        compose.waitForIdle()
        assertEquals(1, themeCycles, "the photo keeps its inspection zoom")
    }
}
