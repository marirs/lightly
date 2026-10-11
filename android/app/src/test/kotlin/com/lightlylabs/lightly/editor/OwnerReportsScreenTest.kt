package com.lightlylabs.lightly.editor

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
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
import com.lightlylabs.lightly.session.ModelRef
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
import org.robolectric.annotation.GraphicsMode
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Owner reports of 2026-10-11 on the motorola edge 60 (Robolectric, native graphics): the tab pill's grey press box, the
 * Remove brush left on the photo, the Text handle's smoothness and visibility, and Background on a photo with no clear
 * subject.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w427dp-h952dp")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class OwnerReportsScreenTest {
    @get:Rule
    val compose = createComposeRule()

    private val render = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    private val renders = AtomicInteger()

    /** A varied photo, so a translucent red mark changes some pixels a lot. */
    private fun image(w: Int, h: Int) = Rgba8Image(w, h, ByteArray(w * h * 4) { i -> if (i % 4 == 3) -1 else (((i / 4) * 7 + (i % 4) * 90) % 251).toByte() })

    /** Hands back the photo unchanged: a removal that leaves the pixels as they were. */
    private class UnchangedInpainter : Inpainter {
        override val model = ModelRef("test-unchanged", "1")
        override fun inpaint(image: FloatArray, mask: FloatArray): FloatArray = image.copyOf()
    }

    private fun editor(
        segmenter: SubjectSegmenter = com.lightlylabs.lightly.background.PendingSubjectSegmenter,
        depth: DepthEstimator = com.lightlylabs.lightly.background.UnavailableDepthEstimator,
        inpainter: Inpainter? = null,
    ): EditorViewModel {
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
            photoLoader = PhotoLoader { asset -> LoadedPhoto(SourceRef(asset, SourceFingerprint("ab".repeat(32), 10, 120, 160), 1), image(60, 80), image(120, 160), FullResolutionSource { image(120, 160) }) },
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
            segmenter = segmenter,
            segmenterModelRef = ModelRef("test-segmenter", "1"),
            depthEstimator = depth,
            depthModelRef = ModelRef("test-depth", "1"),
            inpainter = { inpainter },
            onPreviewRendered = { _, _ -> renders.incrementAndGet() },
        )
        return EditorViewModel(SavedStateHandle(), env, CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate))
    }

    /** The Compose host view, drawn in software for pixel checks (captureToImage waits for a hardware frame here). */
    private var host: android.view.View? = null

    private fun show(vm: EditorViewModel) {
        compose.setContent {
            host = androidx.compose.ui.platform.LocalView.current
            LightlyTheme(dark = false) { EditorScreen(vm, ShellLayout.Compact, EditorActions({}, {}, {}, cycleTheme = {})) }
        }
        vm.openPhoto("content://photo/1")
        compose.waitUntil(10_000) { vm.uiState.value.phase == EditorPhase.Ready }
        compose.waitForIdle()
    }

    /**
     * Waits for the latest requested preview to be published. The render scheduler's delayed main-thread work runs only
     * when Robolectric's paused main looper is advanced, which waitUntil alone does not do.
     */
    private fun settle(vm: EditorViewModel, done: () -> Boolean = { vm.settledRevision >= vm.requestedRevision }) {
        compose.waitUntil(15_000) {
            org.robolectric.shadows.ShadowLooper.idleMainLooper(16, java.util.concurrent.TimeUnit.MILLISECONDS)
            done()
        }
        compose.waitForIdle()
    }

    /** The largest channel difference between two captures of the same node. */
    private fun maxDifference(a: Bitmap, b: Bitmap): Int {
        assertEquals(a.width to a.height, b.width to b.height)
        var worst = 0
        for (y in 0 until a.height) for (x in 0 until a.width) {
            val p = a.getPixel(x, y); val q = b.getPixel(x, y)
            for (shift in intArrayOf(0, 8, 16)) worst = maxOf(worst, abs(((p shr shift) and 0xff) - ((q shr shift) and 0xff)))
        }
        return worst
    }

    /** The node's pixels: the host view drawn into a bitmap, cut to the node's bounds. */
    private fun capture(tag: String): Bitmap {
        compose.waitForIdle()
        val view = checkNotNull(host)
        val whole = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        compose.runOnUiThread { view.draw(android.graphics.Canvas(whole)) }
        val bounds = compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot
        val left = bounds.left.toInt().coerceIn(0, view.width - 1); val top = bounds.top.toInt().coerceIn(0, view.height - 1)
        return Bitmap.createBitmap(whole, left, top, (bounds.width.toInt()).coerceIn(1, view.width - left), (bounds.height.toInt()).coerceIn(1, view.height - top))
    }

    // --- 1. Tab pills -------------------------------------------------------------------------------

    @Test
    fun `pressing a tab draws no grey box under the finger, and the release selects it`() {
        var selected by androidx.compose.runtime.mutableStateOf(1)
        compose.setContent {
            host = androidx.compose.ui.platform.LocalView.current
            LightlyTheme(dark = false) {
                androidx.compose.foundation.layout.Box(androidx.compose.ui.Modifier.background(androidx.compose.ui.graphics.Color.White)) {
                    OptionTabs(listOf(1 to "One", 2 to "Two"), selected, { selected = it }, tagPrefix = "press")
                }
            }
        }
        compose.waitForIdle()
        val before = capture("press-two")
        compose.onNodeWithTag("press-two").performTouchInput { down(center) }
        compose.mainClock.advanceTimeBy(300)
        val pressed = capture("press-two")
        assertEquals(0, maxDifference(before, pressed), "the press shows nothing until the pill")
        compose.onNodeWithTag("press-two").performTouchInput { up() }
        compose.waitForIdle()
        assertEquals(2, selected)
    }

    // --- 2. Remove brush ------------------------------------------------------------------------------

    @Test
    fun `Remove draws the brush only while brushing, never after the stroke was removed`() {
        val vm = editor(inpainter = UnchangedInpainter()); show(vm)
        vm.selectTool(EditorTool.EDIT); vm.selectEditSub(EditSub.REMOVE)
        compose.waitForIdle()
        val untouched = capture(EditTags.REMOVE_MARKS)
        compose.onNodeWithTag(EditTags.REMOVE_MARKS).performTouchInput {
            down(center)
            repeat(6) { moveBy(Offset(8f, 4f)) }
        }
        compose.waitForIdle()
        assertTrue(maxDifference(untouched, capture(EditTags.REMOVE_MARKS)) > 40, "the stroke under the finger is shown")
        compose.onNodeWithTag(EditTags.REMOVE_STROKE).assertExists()
        compose.onNodeWithTag(EditTags.REMOVE_MARKS).performTouchInput { up() }
        settle(vm) {
            val ui = vm.uiState.value
            ui.edit.removeOp == RemoveOp.IDLE && ui.session!!.current.tools.edit.remove.strokes.size == 1 && vm.settledRevision >= vm.requestedRevision
        }
        compose.waitForIdle()
        // The removed stroke is pixels of the preview now (here unchanged by the stand-in model), never a red mark on top.
        compose.onNodeWithTag(EditTags.REMOVE_STROKE).assertDoesNotExist()
    }

    // --- 3. Text handles ------------------------------------------------------------------------------

    private fun addText(vm: EditorViewModel): com.lightlylabs.lightly.session.TextLayer {
        vm.selectTool(EditorTool.TEXT)
        vm.openAddText(); vm.finishTextSheet("Summer")
        settle(vm)
        compose.waitForIdle()
        return vm.uiState.value.session!!.current.tools.text.layers.single()
    }

    @Test
    fun `the corner handle drag follows the finger without a render per move and commits one step`() {
        val vm = editor(); show(vm)
        val layer = addText(vm)
        val steps = vm.uiState.value.session!!.history.entries.size
        renders.set(0)
        compose.onNodeWithTag(TextTags.HANDLE).performTouchInput {
            down(center)
            repeat(12) { moveBy(Offset(3f, 2f)) }
        }
        compose.waitForIdle()
        // Mid-gesture: drawn live over the photo, nothing recorded, at most the one render without the layer.
        compose.onNodeWithTag(TextTags.LIVE).assertExists()
        assertEquals(layer.id, vm.uiState.value.text.liveLayerId)
        assertEquals(steps, vm.uiState.value.session!!.history.entries.size)
        assertTrue(renders.get() <= 1, "renders during the drag: ${renders.get()}")
        compose.onNodeWithTag(TextTags.HANDLE).performTouchInput { up() }
        settle(vm)
        assertEquals(false, vm.uiState.value.previewFailed, "the committed text rendered")
        settle(vm) { vm.uiState.value.text.liveLayerId == null }
        compose.waitForIdle()
        assertEquals(steps + 1, vm.uiState.value.session!!.history.entries.size)
        val resized = vm.uiState.value.session!!.current.tools.text.layers.single()
        assertTrue(resized.size > layer.size, "dragging outwards grows the text: ${layer.size} → ${resized.size}")
        compose.onNodeWithTag(TextTags.LIVE).assertDoesNotExist()
    }

    @Test
    fun `a text at the photo's top edge keeps both handles whole inside the stage`() {
        val vm = editor(); show(vm)
        val layer = addText(vm)
        vm.commitTextLayer(TextEdits.moved(layer, 0.0, -0.5))
        settle(vm)
        compose.waitForIdle()
        val stage = compose.onNodeWithTag(EditorTags.STAGE).getBoundsInRoot()
        for (tag in listOf(TextTags.DELETE, TextTags.HANDLE)) {
            compose.onNodeWithTag(tag).assertIsDisplayed()
            val handle = compose.onNodeWithTag(tag).getBoundsInRoot()
            assertTrue(handle.top >= stage.top && handle.bottom <= stage.bottom && handle.left >= stage.left && handle.right <= stage.right, "$tag $handle in $stage")
        }
    }

    @Test
    fun `handles inside the stage sit exactly on the text box corners`() {
        val stage = Rect(-20f, -16f, 340f, 500f)
        assertEquals(100.0 to 120.0, TextStageArea.keepInside(100.0 to 120.0, stage, 11.0))
        assertEquals(100.0 to -5.0, TextStageArea.keepInside(100.0 to -40.0, stage, 11.0))
        assertEquals(329.0 to 489.0, TextStageArea.keepInside(400.0 to 600.0, stage, 11.0))
    }

    @Test
    fun `a gesture draft keeps the exact size and commits a whole number in range`() {
        val start = TextEdits.newLayer("00000001", "Hi")
        val draft = TextEdits.drafted(start, 0.0, 0.0, 1.013, 10.0)
        assertEquals(42 * 1.013, draft.exactSize, 1e-9)
        assertEquals(43, draft.layer.size)
        assertEquals(10.0, draft.layer.rotation, 1e-9)
        assertEquals(100.0, TextEdits.drafted(start, 0.0, 0.0, 9.0, 0.0).exactSize)
    }

    // --- 4. Background without a clear subject ---------------------------------------------------------

    @Test
    fun `no clear subject - Change background is greyed and not selectable, Focus and Blur shows the notice and Blur`() {
        val depth = DepthEstimator { FloatPlane(64, 48, FloatArray(64 * 48) { 0.5f }) }
        val vm = editor(segmenter = SubjectSegmenter { _, _, _ -> null }, depth = depth); show(vm)
        vm.selectTool(EditorTool.BACKGROUND)
        compose.waitUntil(10_000) { vm.uiState.value.separation is SeparationState.Finished }
        compose.waitForIdle()
        // Owner amendment 2026-10-11 (second; mockup bg-no-subject): the tab is disabled (40 %, semantics disabled) and a
        // tap on it changes nothing; Focus & Blur stays the selected tab.
        compose.onNodeWithTag("background-mode-change-background").assertIsNotEnabled().assertIsNotSelected()
        compose.onNodeWithTag("background-mode-focus-&-blur").assertIsSelected()
        vm.selectBackgroundSub(BackgroundSub.CHANGE)
        compose.waitForIdle()
        assertEquals(BackgroundSub.FOCUS, vm.uiState.value.background.sub)
        compose.onNodeWithText("No clear subject found.", substring = true).assertIsDisplayed()
        compose.onNodeWithText("Change background needs a person or object in front. You can still blur by tapping where to focus.", substring = true).assertExists()
        compose.onNodeWithTag(BackgroundTags.slider("blur")).assertExists()
        compose.onNodeWithTag("replacement-kind-image").assertDoesNotExist()
        compose.onNodeWithTag(BackgroundTags.slider("depthOfField")).assertDoesNotExist()
    }

    @Test
    fun `with a subject, Change background › Image is two rows of tiles filling the row four across, column by column, the dashed + tile last`() {
        assertEquals(BackgroundOptions.IMAGES.map { BackgroundImageTile.Bundled(it.first, it.second) } + BackgroundImageTile.ChoosePhoto, BackgroundImageTile.all(hasImportedPhoto = false))
        assertEquals(listOf(BackgroundImageTile.Imported, BackgroundImageTile.ChoosePhoto), BackgroundImageTile.all(hasImportedPhoto = true).takeLast(2))
        val depth = DepthEstimator { FloatPlane(64, 48, FloatArray(64 * 48) { 0.5f }) }
        val subject = SubjectSegmenter { _, w, h -> FloatPlane(w, h, FloatArray(w * h) { i -> if (i % w in w / 4 until 3 * w / 4) 1f else 0f }) }
        val vm = editor(segmenter = subject, depth = depth); show(vm)
        vm.selectTool(EditorTool.BACKGROUND)
        compose.waitUntil(10_000) { vm.uiState.value.separation is SeparationState.Finished }
        vm.selectBackgroundSub(BackgroundSub.CHANGE)
        compose.waitForIdle()
        compose.onNodeWithTag("background-mode-change-background").assertIsEnabled().assertIsSelected()
        val first = compose.onNodeWithTag("background-image-landscape_01").getBoundsInRoot()
        val second = compose.onNodeWithTag("background-image-sunset_03").getBoundsInRoot()
        val third = compose.onNodeWithTag("background-image-wellexposed_02").getBoundsInRoot()
        val plus = compose.onNodeWithTag("background-add-photo").getBoundsInRoot()
        val last = compose.onNodeWithTag("background-image-wellexposed_03").getBoundsInRoot()
        // Column-major: the second photo under the first (10 dp row gap), the third starts the next column (8 dp gap).
        assertNear(first.left, second.left); assertNear(first.bottom + 10.dp, second.top)
        assertNear(first.top, third.top); assertNear(first.right + 8.dp, third.left)
        // Owner amendment 2026-10-11 (mockup `grid-auto-columns: calc((100% - 24px) / 4)`): four tiles fill the panel's row,
        // square; the content is the grid less its 2 dp side padding.
        val grid = compose.onNodeWithTag("background-images").getBoundsInRoot()
        val tile = (grid.right - grid.left - 4.dp - 24.dp) / 4
        assertNear(tile, first.right - first.left); assertNear(tile, first.bottom - first.top)
        // The + tile's width only: the fixed-height panel clips its lower part until the panel is scrolled.
        assertNear(tile, plus.right - plus.left)
        assertNear(tile, backgroundImageTileSize(grid.right - grid.left))
        assertTrue(tile > 60.dp, "tiles fill the row: $tile")
        // The fourth column (the seventh photo) ends at the panel's content edge.
        // (Measured with the drawn tile, which snaps to whole pixels.)
        assertNear(first.left + (first.right - first.left + 8.dp) * 3, last.left)
        // Within a dp: each of the four tiles may round up to a whole pixel (91.75 dp draws as 92 at this density).
        assertTrue(kotlin.math.abs((grid.right - 2.dp - last.right).value) <= 1f, "fourth column ends at ${last.right}, content edge ${grid.right - 2.dp}")
        // Seven photos then +: + is under the seventh, in the fourth column.
        assertNear(last.left, plus.left); assertNear(last.bottom + 10.dp, plus.top)
    }

    private fun assertNear(expected: androidx.compose.ui.unit.Dp, actual: androidx.compose.ui.unit.Dp) =
        assertTrue(kotlin.math.abs((expected - actual).value) < 0.5f, "expected $expected, was $actual")

    // --- 5. Bundled backgrounds -------------------------------------------------------------------------

    @Test
    fun `Change background offers the mockup's seven photos in its order, from the folder iOS packages`() {
        val repo = java.io.File(checkNotNull(System.getProperty("lightly.renderingContract"))).parentFile.parentFile.parentFile
        val mockup = repo.resolve("docs/ui/directions/lightly-2-concept/index.html").readText()
        val listed = assertNotNull(Regex("""const BACKGROUNDS = \[([^\]]*)\]""").find(mockup)).groupValues[1]
        val approved = Regex("""'([a-z0-9_]+)'""").findAll(listed).map { it.groupValues[1] }.toList()
        assertEquals(7, approved.size)
        assertEquals(approved, BackgroundOptions.IMAGES.map { it.second })
        assertEquals(approved.map { "background.$it" }, BackgroundOptions.IMAGES.map { it.first })
        val photos = repo.resolve("docs/ui/assets/photos")
        for ((_, name) in BackgroundOptions.RENDERABLE_IMAGES) {
            assertTrue(photos.resolve("$name.jpg").isFile && photos.resolve("${name}_thumb.jpg").isFile, name)
        }
        assertNull(BackgroundOptions.IMAGES.firstOrNull { it.second == "backlit_02" }, "the retired photo is not offered")
    }
}

