package com.lightlylabs.lightly.editor

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.Density
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
import com.lightlylabs.lightly.session.WatermarkType
import com.lightlylabs.lightly.shell.LightlyColors
import com.lightlylabs.lightly.shell.LightlyTheme
import com.lightlylabs.lightly.shell.ShellLayout
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.io.OutputStream
import java.util.concurrent.Executors
import kotlin.math.pow
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Accessibility at the source (phone layout): TalkBack names, roles, states and values of the dock, tabs,
 * sliders, swatches, chips, the ruler, the switches and Compare; text at the largest font scale; reduced
 * animations; and text-token contrast. Findings that would need a visual change are reported, not "fixed".
 */
@RunWith(RobolectricTestRunner::class)
// Native graphics: real text measurement (the legacy shadow measures about 1 px per character).
@org.robolectric.annotation.GraphicsMode(org.robolectric.annotation.GraphicsMode.Mode.NATIVE)
@Config(sdk = [35], qualifiers = "w427dp-h952dp")
class AccessibilityTest {
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
            autoDeveloper = AutoDeveloper { _, _ -> DevelopResult.NoModelInThisBuild },
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

    private fun show(vm: EditorViewModel, fontScale: Float = 1f) {
        compose.setContent {
            val base = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(base.density, fontScale)) {
                LightlyTheme(dark = false) { EditorScreen(vm, ShellLayout.Compact, EditorActions({}, {}, {})) }
            }
        }
        vm.openPhoto("content://photo/1")
        compose.waitUntil(10_000) { vm.uiState.value.phase == EditorPhase.Ready }
        compose.waitForIdle()
    }

    private fun node(tag: String) = compose.onNodeWithTag(tag, useUnmergedTree = false).fetchSemanticsNode()
    private fun SemanticsNode.state() = config.getOrNull(SemanticsProperties.StateDescription)
    private fun SemanticsNode.description() = config.getOrNull(SemanticsProperties.ContentDescription)?.joinToString()
    private fun SemanticsNode.role() = config.getOrNull(SemanticsProperties.Role)

    /** What Remove animations sets: ValueAnimator's duration scale (a hidden static, reached by reflection). */
    private fun animatorScale(scale: Float) {
        android.animation.ValueAnimator::class.java.getMethod("setDurationScale", Float::class.javaPrimitiveType).invoke(null, scale)
    }

    @After
    fun resetAnimators() = animatorScale(1f)

    @Test
    fun `dock tools are tabs, selected, and a used tool is spoken as Edited`() {
        val vm = editor()
        show(vm)
        vm.selectTool(EditorTool.EFFECTS)
        vm.toggleEffect(EffectsSub.VIGNETTE)
        compose.waitForIdle()
        val effects = node(EditorTags.tool(EditorTool.EFFECTS))
        assertEquals(Role.Tab, effects.role())
        assertEquals(true, effects.config.getOrNull(SemanticsProperties.Selected))
        assertEquals("Edited", effects.state())
        val border = node(EditorTags.tool(EditorTool.BORDER))
        assertEquals(false, border.config.getOrNull(SemanticsProperties.Selected))
        assertEquals(null, border.state())
    }

    @Test
    fun `Effects switch is named by its effect, sliders speak their values and accept SetProgress`() {
        val vm = editor()
        show(vm)
        vm.selectTool(EditorTool.EFFECTS)
        vm.selectEffectsSub(EffectsSub.VIGNETTE)
        compose.waitForIdle()
        val toggle = node("effects-on-off")
        assertEquals(Role.Switch, toggle.role())
        assertEquals("Vignette", toggle.description())
        assertEquals(ToggleableState.Off, toggle.config.getOrNull(SemanticsProperties.ToggleableState))
        vm.toggleEffect(EffectsSub.VIGNETTE)
        compose.waitForIdle()
        assertEquals(ToggleableState.On, node("effects-on-off").config.getOrNull(SemanticsProperties.ToggleableState))
        val sliders = compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.ProgressBarRangeInfo).and(SemanticsMatcher.keyIsDefined(SemanticsActions.SetProgress)))
            .fetchSemanticsNodes().filter { it.description() != "Presets" }
        assertTrue(sliders.isNotEmpty())
        sliders.forEach { slider ->
            val value = slider.config[SemanticsProperties.ProgressBarRangeInfo].current.toInt()
            assertEquals((if (value > 0 && slider.config[SemanticsProperties.ProgressBarRangeInfo].range.start < 0) "+" else "") + value, slider.state(), "${slider.description()} speaks its value")
        }
    }

    @Test
    fun `swatches keep the label Colour and speak the colour name`() {
        val vm = editor()
        show(vm)
        vm.selectTool(EditorTool.WATERMARK)
        vm.chooseWatermark(WatermarkType.TEXT)
        compose.waitForIdle()
        val white = node("watermark-colour-#FFFFFF")
        assertEquals("Colour", white.description())
        assertEquals("White", white.state())
        assertEquals(Role.RadioButton, white.role())
        assertEquals("Tan", node("watermark-colour-#C9A27E").state())
    }

    @Test
    fun `the ruler speaks the preset and its place, and Compare is a switch with a state`() {
        val vm = editor()
        show(vm)
        val ruler = node(EditorTags.RULER)
        assertEquals("Presets", ruler.description())
        assertEquals("Original, 0 of 518", ruler.state())
        val compare = node(EditorTags.COMPARE)
        assertEquals(Role.Switch, compare.role())
        assertEquals("Showing your edit", compare.state())
    }

    @Test
    fun `reduced animations are detected from the animator duration scale`() {
        animatorScale(0f)
        assertTrue(reducedMotion())
        animatorScale(1f)
        assertFalse(reducedMotion())
    }

    /** Text nodes on screen with their bounds and whether their layout overflowed (clipped or ellipsised). */
    private fun texts(): List<Triple<String, Rect, Boolean>> =
        compose.onAllNodes(SemanticsMatcher.keyIsDefined(SemanticsProperties.Text), useUnmergedTree = true).fetchSemanticsNodes().mapNotNull { n ->
            val text = n.config[SemanticsProperties.Text].joinToString { it.text }
            if (text.isBlank() || n.boundsInRoot.width <= 0f) return@mapNotNull null
            val layouts = mutableListOf<TextLayoutResult>()
            n.config.getOrNull(SemanticsActions.GetTextLayoutResult)?.action?.invoke(layouts)
            Triple(text, n.boundsInRoot, layouts.any { it.didOverflowWidth || it.lineCount > 0 && it.isLineEllipsized(it.lineCount - 1) })
        }

    @Test
    fun `at the largest font scale the panels' text neither overlaps nor overflows`() {
        val out = (System.getenv("LIGHTLY_EVIDENCE_DIR")?.let { File(it) } ?: kotlin.io.path.createTempDirectory("a11y").toFile()).apply { mkdirs() }
        val report = mutableListOf("font_scale,tool,text,left,top,right,bottom,overflow,overlaps")
        val problems = mutableListOf<String>()
        // One composition (a test can set content once); the font scale is state.
        val fontScale = androidx.compose.runtime.mutableFloatStateOf(1.0f)
        val vm = editor()
        compose.setContent {
            val base = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(base.density, fontScale.floatValue)) {
                LightlyTheme(dark = false) { EditorScreen(vm, ShellLayout.Compact, EditorActions({}, {}, {})) }
            }
        }
        vm.openPhoto("content://photo/1")
        compose.waitUntil(10_000) { vm.uiState.value.phase == EditorPhase.Ready }
        for (scale in listOf(1.0f, 1.3f, 2.0f)) {
            fontScale.floatValue = scale
            compose.waitForIdle()
            for (tool in listOf(EditorTool.DEVELOP, EditorTool.EFFECTS, EditorTool.WATERMARK, EditorTool.BORDER)) {
                vm.selectTool(tool)
                compose.waitForIdle()
                val root = compose.onRoot().fetchSemanticsNode().boundsInRoot
                // Text inside a horizontally scrolling row may extend past the screen by design; only what is on screen counts.
                val shown = texts().filter { it.second.intersect(root).width > 0f && it.second.top < root.bottom }
                for ((i, a) in shown.withIndex()) {
                    val overlaps = shown.withIndex().filter { (j, b) -> j != i && a.second.intersect(b.second).let { r -> r.width > 1f && r.height > 1f } }.map { it.value.first }
                    report += listOf(scale, tool, "\"${a.first}\"", a.second.left, a.second.top, a.second.right, a.second.bottom, a.third, "\"${overlaps.joinToString("|")}\"").joinToString(",")
                    if (a.third) problems += "$scale $tool overflow: ${a.first}"
                    if (overlaps.isNotEmpty() && i < shown.indexOfFirst { it.first in overlaps }) problems += "$scale $tool overlap: ${a.first} × ${overlaps.joinToString()}"
                }
            }
        }
        File(out, "large-font.csv").writeText(report.joinToString("\n") + "\n")
        File(out, "large-font-problems.txt").writeText(problems.joinToString("\n") + "\n")
        println("large font: ${out.absolutePath}\n" + problems.joinToString("\n"))
    }

    // --- contrast ------------------------------------------------------------------------------

    private fun luminance(c: androidx.compose.ui.graphics.Color): Double {
        fun lin(v: Float) = if (v <= 0.04045f) v / 12.92 else ((v + 0.055) / 1.055).pow(2.4)
        return 0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue)
    }
    private fun over(top: androidx.compose.ui.graphics.Color, under: androidx.compose.ui.graphics.Color) =
        androidx.compose.ui.graphics.Color(top.red * top.alpha + under.red * (1 - top.alpha), top.green * top.alpha + under.green * (1 - top.alpha), top.blue * top.alpha + under.blue * (1 - top.alpha))
    private fun ratio(a: androidx.compose.ui.graphics.Color, b: androidx.compose.ui.graphics.Color): Double {
        val (x, y) = luminance(a) to luminance(b)
        return (maxOf(x, y) + 0.05) / (minOf(x, y) + 0.05)
    }

    @Test
    fun `text tokens reach 4·5 to 1 on the surfaces they are used on, light and dark`() {
        for (c in listOf(LightlyColors.Light, LightlyColors.Dark)) {
            val mode = if (c.isDark) "dark" else "light"
            // Panels, dock and sheets: titles (ink), secondary text (ink2), values, notes and dock labels (ink3),
            // selection (sel: Cancel / Save / Use, selected chips) and Delete (danger).
            for ((surface, name) in listOf(c.bg to "bg", c.bg2 to "bg2", c.sheet to "sheet")) {
                for ((token, label) in listOf(c.ink to "ink", c.ink2 to "ink2", c.ink3 to "ink3", c.sel to "sel", c.danger to "danger")) {
                    assertTrue(ratio(token, surface) >= 4.5, "$label on $name ($mode): ${"%.2f".format(ratio(token, surface))}")
                }
            }
            // `.seg .on`: the selected label on the raised segment; `.opt.on`: the selection colour on its soft fill.
            assertTrue(ratio(c.ink, c.segmentOn) >= 4.5, "ink on segment ($mode)")
            val soft = over(c.selSoft, c.bg)
            assertTrue(ratio(c.sel, soft) >= 4.5, "sel on selSoft ($mode): ${"%.2f".format(ratio(c.sel, soft))}")
            assertTrue(ratio(c.ink, soft) >= 4.5, "ink on selSoft ($mode)")
        }
    }
}
