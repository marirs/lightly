package com.lightlylabs.lightly.editor

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.DpRect
import androidx.compose.ui.unit.height
import androidx.compose.ui.unit.width
import androidx.lifecycle.SavedStateHandle
import com.lightlylabs.lightly.export.ExportCoordinator
import com.lightlylabs.lightly.export.FullResolutionSource
import com.lightlylabs.lightly.export.JpegEncoder
import com.lightlylabs.lightly.export.MediaStoreGateway
import com.lightlylabs.lightly.export.NewImageSpec
import com.lightlylabs.lightly.export.Rgba8ExportFrame
import com.lightlylabs.lightly.export.SaveCopyExporter
import com.lightlylabs.lightly.model.BasisRegistry
import com.lightlylabs.lightly.model.RegistryAutoLutResolver
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.lut.CpuLutPassRenderer
import com.lightlylabs.lightly.session.SourceFingerprint
import com.lightlylabs.lightly.session.SourceRef
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The editor screen on Robolectric with the catalog-shaped pack and no Auto model (the shipping
 * situation): placement per window size and posture, stop markers and caption, Strength, Compare,
 * notices and large text. Pixels and real gestures are checked on the emulator (doc §9).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w411dp-h891dp")
class EditorScreenTest {

    @get:Rule
    val compose = createComposeRule()

    private val scheduler = TestCoroutineScheduler()
    private val dispatcher = StandardTestDispatcher(scheduler)
    private val assetId = "content://media/picker/0/7"
    private val source = SourceRef(assetId, SourceFingerprint("ef".repeat(32), 500_000, 60, 40), orientation = 1)
    private val photo = Rgba8Image(60, 40, ByteArray(60 * 40 * 4) { if (it % 4 == 3) -1 else (it % 200).toByte() })

    private fun environment() = EditorEnvironment(
        photoLoader = PhotoLoader { LoadedPhoto(source, photo, photo, FullResolutionSource { photo }) },
        photoAccess = object : PhotoAccessGrants {
            override fun retain(assetId: String) = true
            override fun release(assetId: String) = Unit
        },
        autoDeveloper = AutoDeveloper { _, _ -> DevelopResult.NoModelInThisBuild },
        autoResolver = RegistryAutoLutResolver(BasisRegistry(emptyList())),
        lookBook = FixtureLookPack.book(FixtureLookPack.catalogShapedCategories),
        previewRenderer = CpuLutPassRenderer,
        renderDispatcher = dispatcher,
        exporter = ExportCoordinator(
            CpuLutPassRenderer,
            SaveCopyExporter(
                object : MediaStoreGateway<String> {
                    override fun insertPending(spec: NewImageSpec) = "content://media/new/1"
                    override fun openForWrite(handle: String): OutputStream = ByteArrayOutputStream()
                    override fun publish(handle: String) = true
                    override fun delete(handle: String) = Unit
                },
                JpegEncoder<Rgba8ExportFrame> { frame, _, sink -> sink.write(frame.pixels) },
            ),
            Rgba8ExportFrame.factory,
            dispatcher,
        ),
    )

    /** A Ready editor on screen; [hinges] in window pixels. */
    private fun showReadyEditor(hinges: List<WindowHinge> = emptyList()): EditorViewModel {
        val vm = EditorViewModel(SavedStateHandle(), environment(), CoroutineScope(SupervisorJob() + dispatcher))
        vm.openPhoto(assetId)
        scheduler.advanceUntilIdle()
        compose.setContent {
            MaterialTheme {
                val ui by vm.uiState.collectAsState()
                EditorContent(ui, vm, hinges, pickPhoto = {})
            }
        }
        settle()
        return vm
    }

    private fun settle() {
        compose.waitForIdle()
        scheduler.advanceUntilIdle()
        compose.waitForIdle()
    }

    private fun bounds(tag: String): DpRect = compose.onNodeWithTag(tag).getBoundsInRoot()

    // --- Placement ------------------------------------------------------------------------------

    @Test
    fun `phone portrait - controls below the photo, the photo keeps most of the height`() {
        showReadyEditor()
        val photo = bounds(EditorTags.PHOTO)
        val panel = bounds(EditorTags.PANEL)
        val root = compose.onRoot().getBoundsInRoot()

        assertTrue(photo.bottom <= panel.top, "panel $panel is below photo $photo")
        assertTrue(panel.height.value <= root.height.value * EditorLayoutPolicy.STACKED_PANEL_FRACTION + 1f, "panel ${panel.height} of ${root.height}")
        assertTrue(photo.height.value >= root.height.value * 0.55f)
    }

    @Test
    @Config(qualifiers = "w891dp-h411dp")
    fun `phone landscape - a 320 to 380 dp panel beside the photo`() {
        showReadyEditor()
        val photo = bounds(EditorTags.PHOTO)
        val panel = bounds(EditorTags.PANEL)

        assertTrue(photo.right <= panel.left, "panel $panel is right of photo $photo")
        assertTrue(panel.width.value in 320f..380f, "panel width ${panel.width}")
        assertTrue(photo.width > panel.width)
    }

    @Test
    @Config(qualifiers = "w800dp-h1280dp")
    fun `tablet portrait - side panel`() {
        showReadyEditor()
        val photo = bounds(EditorTags.PHOTO)
        val panel = bounds(EditorTags.PANEL)

        assertTrue(photo.right <= panel.left)
        assertTrue(panel.width.value in 320f..380f, "panel width ${panel.width}")
    }

    @Test
    @Config(qualifiers = "w840dp-h880dp")
    fun `foldable in book posture - the whole photo stays on one side of the hinge`() {
        val density = RuntimeEnvironment.getApplication().resources.displayMetrics.density
        val hingeLeftPx = 418f * density
        val hingeRightPx = 422f * density
        showReadyEditor(listOf(WindowHinge(Rect(hingeLeftPx, 0f, hingeRightPx, 880f * density), isVertical = true, separatesContent = true)))
        val photo = bounds(EditorTags.PHOTO)
        val panel = bounds(EditorTags.PANEL)

        assertTrue(photo.right.value <= 418f + 0.5f, "photo ends at ${photo.right}, hinge starts at 418dp")
        assertTrue(panel.left.value >= 422f - 0.5f, "panel starts at ${panel.left}, hinge ends at 422dp")
    }

    @Test
    @Config(qualifiers = "w840dp-h880dp")
    fun `foldable lying flat - a non-separating fold does not split the layout`() {
        val density = RuntimeEnvironment.getApplication().resources.displayMetrics.density
        showReadyEditor(listOf(WindowHinge(Rect(420f * density, 0f, 420f * density, 880f * density), isVertical = true, separatesContent = false)))
        val panel = bounds(EditorTags.PANEL)

        assertTrue(panel.width.value in 320f..380f, "panel width ${panel.width}")
    }

    @Test
    fun `large text - the panel scrolls, the photo stays visible and long names wrap`() {
        RuntimeEnvironment.setFontScale(2f)
        val vm = showReadyEditor()
        vm.selectCategory("cat-cool")
        vm.onStopSettled(1) // "Cinematic Light Tone (11)", the longest name
        settle()
        val root = compose.onRoot().getBoundsInRoot()
        val photo = bounds(EditorTags.PHOTO)

        assertTrue(photo.height.value >= root.height.value * 0.4f, "photo ${photo.height} of ${root.height}")
        compose.onNodeWithTag(EditorTags.STOP_CAPTION).assertTextEquals("Cinematic Light Tone (11) · 2 of 4")
        val caption = bounds(EditorTags.STOP_CAPTION)
        assertTrue(caption.right <= bounds(EditorTags.PANEL).right, "the caption wraps inside the panel")
        compose.onNodeWithTag(EditorTags.SAVE_COPY).performScrollTo().assertIsDisplayed()
        assertTrue(bounds(EditorTags.PHOTO).height.value >= root.height.value * 0.4f, "scrolling the panel never covers the photo")
    }

    // --- Stops, Strength, Compare, Reset, notices ---------------------------------------------

    @Test
    fun `every stop has a visible marker and the caption names the stop and its position`() {
        val vm = showReadyEditor()
        vm.selectCategory("cat-warm")
        settle()

        (0..4).forEach { compose.onNodeWithTag(SteppedSliderTags.marker(it)).assertExists() }
        compose.onNodeWithTag(SteppedSliderTags.marker(5)).assertDoesNotExist()
        compose.onNodeWithTag(EditorTags.STOP_CAPTION).assertTextEquals("Original · 1 of 5")

        compose.onNodeWithTag(SteppedSliderTags.marker(2)).performClick()
        settle()
        compose.onNodeWithTag(EditorTags.STOP_CAPTION).assertTextEquals("Nordic Tone (10) · 3 of 5")
        assertEquals("nordic-tone-10-7b6a3a", vm.uiState.value.session!!.current.look?.lookId)
        assertEquals(2, vm.uiState.value.session!!.history.entries.size, "a tap is one step")
    }

    @Test
    fun `strength appears only with a Look`() {
        val vm = showReadyEditor()
        compose.onNodeWithTag(EditorTags.STRENGTH).assertDoesNotExist()

        vm.selectCategory("cat-mono")
        settle()
        compose.onNodeWithTag(SteppedSliderTags.marker(3)).performClick()
        settle()
        compose.onNodeWithTag(EditorTags.STOP_CAPTION).assertTextEquals("11 Black and White 11 · 4 of 4")
        compose.onNodeWithTag(EditorTags.STRENGTH).assertExists()

        compose.onNodeWithText("Reset").performScrollTo().performClick()
        settle()
        compose.onNodeWithTag(EditorTags.STRENGTH).assertDoesNotExist()
        compose.onNodeWithText("Undo").assertIsEnabled()
        compose.onNodeWithText("Reset").assertIsNotEnabled()
    }

    @Test
    fun `compare puts an Original label on the photo`() {
        val vm = showReadyEditor()
        vm.selectCategory("cat-film")
        vm.onStopSettled(2)
        settle()
        compose.onNodeWithTag(EditorTags.ORIGINAL_INDICATOR).assertDoesNotExist()

        compose.onNodeWithText("Compare").performScrollTo().performClick()
        settle()
        compose.onNodeWithTag(EditorTags.ORIGINAL_INDICATOR).assertIsDisplayed()
        compose.onNodeWithText("Original").assertIsDisplayed()

        compose.onNodeWithText("Compare").performClick()
        settle()
        compose.onNodeWithTag(EditorTags.ORIGINAL_INDICATOR).assertDoesNotExist()
    }

    @Test
    fun `no model - straight to editing, a compact notice, no Retry, and Save copy is prominent`() {
        showReadyEditor()

        compose.onNodeWithTag(EditorTags.NOTICES).assertExists()
        compose.onNodeWithText(AutoStatus.NoModelInThisBuild.NOTICE).assertExists()
        compose.onNodeWithText(LookBook.APPROXIMATE_NOTICE).assertExists()
        compose.onNodeWithText("Retry").assertDoesNotExist()
        compose.onNodeWithTag(EditorTags.SAVE_COPY).performScrollTo().assertIsDisplayed().assertIsEnabled()
        assertEquals(bounds(EditorTags.PANEL).width.value, bounds(EditorTags.SAVE_COPY).width.value + 32f, 1f)
    }
}
