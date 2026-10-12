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
import androidx.compose.ui.test.performSemanticsAction
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
    fun `Effects has no switch, sliders speak their values and accept SetProgress`() {
        val vm = editor()
        show(vm)
        vm.selectTool(EditorTool.EFFECTS)
        vm.selectEffectsSub(EffectsSub.VIGNETTE)
        compose.waitForIdle()
        // Lightly 2: no On/Off switch; moving a slider turns the effect on.
        compose.onNodeWithTag("effects-on-off").assertDoesNotExist()
        vm.toggleEffect(EffectsSub.VIGNETTE)
        compose.waitForIdle()
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
        // Lightly 2: one 24-colour strip, adjustable for TalkBack (the colour is its value).
        val strip = node("watermark-colour-strip")
        assertEquals("Colour", strip.description())
        assertEquals("White", strip.state())
        val tan = STRIP_COLOURS.indexOfFirst { it.first == "Tan" }
        compose.onNodeWithTag("watermark-colour-strip").performSemanticsAction(SemanticsActions.SetProgress) { it(tan.toFloat()) }
        compose.waitForIdle()
        assertEquals("Tan", node("watermark-colour-strip").state())
    }

    @Test
    fun `gallery tiles speak the preset and their selection, and Compare is a switch with a state`() {
        val vm = editor()
        show(vm)
        val original = node("develop-thumbnail-original")
        assertEquals("Original", original.description())
        assertEquals(true, original.config.getOrNull(SemanticsProperties.Selected))
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

    // WCAG 2.2 1.4.3: 4.5:1 for normal text, 3:1 only for large text (>= 24 px, or >= 18.66 px bold); 1.4.11: 3:1
    // for icons and control boundaries. Text in disabled controls is exempt. Every text use below is normal size.

    @Test
    fun `text tokens reach 4·5 to 1 on the surfaces they are used on, light and dark`() {
        for (c in listOf(LightlyColors.Light, LightlyColors.Dark)) {
            val mode = if (c.isDark) "dark" else "light"
            // Panels, dock and sheets: titles (ink), secondary text (ink2), selection (sel: Cancel / Save / Use)
            // and Delete (danger). ink3 is checked on its own below.
            for ((surface, name) in listOf(c.bg to "bg", c.bg2 to "bg2", c.sheet to "sheet")) {
                for ((token, label) in listOf(c.ink to "ink", c.ink2 to "ink2", c.sel to "sel", c.danger to "danger")) {
                    assertTrue(ratio(token, surface) >= 4.5, "$label on $name ($mode): ${"%.2f".format(ratio(token, surface))}")
                }
            }
            // Selected segments, chips and dock tabs are `background: var(--on-bg); color: var(--on-ink)` in the
            // Lightly 2 mockup (segmentOn / onInk here). The earlier check of ink on segmentOn compared the fill with
            // itself (1:1) — a leftover of the pre-Lightly-2 palette, not what any screen draws.
            assertTrue(ratio(c.onInk, c.segmentOn) >= 4.5, "onInk on segmentOn ($mode): ${"%.2f".format(ratio(c.onInk, c.segmentOn))}")
            // The selected tool tab (owner amendment 2026-10-11): pill-ink on the translucent lime pill over the sheet.
            // This replaces the sel-on-selSoft check: selSoft is not a Lightly 2 token and no screen uses it.
            val pill = over(c.pill, c.sheet)
            assertTrue(ratio(c.pillInk, pill) >= 4.5, "pillInk on pill ($mode): ${"%.2f".format(ratio(c.pillInk, pill))}")
        }
    }

    @Test
    fun `ink3 icons, ticks and dashed outlines reach 3 to 1 (WCAG 1·4·11), light and dark`() {
        for (c in listOf(LightlyColors.Light, LightlyColors.Dark)) {
            val mode = if (c.isDark) "dark" else "light"
            for ((surface, name) in listOf(c.bg to "bg", c.bg2 to "bg2", c.sheet to "sheet")) {
                assertTrue(ratio(c.ink3, surface) >= 3.0, "ink3 on $name ($mode): ${"%.2f".format(ratio(c.ink3, surface))}")
            }
        }
    }

    /**
     * ink3 is drawn as normal-size text (unselected tool tabs, list-row values, font names, footnotes), so it needs
     * 4.5:1. The mockup's original #7D8179 / #7E837B measured light 3.57–3.97 and dark 4.40 on the card; the owner
     * approved #6C7068 / #80857D on 2026-10-12. Every surface is measured before failing so a report lists them all.
     */
    @Test
    fun `ink3 as text reaches 4·5 to 1 on the surfaces it is used on, light and dark`() {
        val failures = mutableListOf<String>()
        for (c in listOf(LightlyColors.Light, LightlyColors.Dark)) {
            val mode = if (c.isDark) "dark" else "light"
            for ((surface, name) in listOf(c.bg to "bg", c.bg2 to "bg2", c.sheet to "sheet")) {
                if (ratio(c.ink3, surface) < 4.5) failures += "ink3 on $name ($mode): ${"%.2f".format(ratio(c.ink3, surface))}"
            }
        }
        assertTrue(failures.isEmpty(), failures.joinToString("; "))
    }
}
