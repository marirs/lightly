package com.lightlylabs.lightly.editor

import androidx.compose.ui.draw.drawBehind

import androidx.compose.foundation.layout.heightIn

import androidx.compose.foundation.layout.width

import androidx.compose.foundation.background

import com.lightlylabs.lightly.shell.l2TextStyle

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.session.AssetRef
import com.lightlylabs.lightly.session.BackgroundTool
import com.lightlylabs.lightly.session.Replacement
import com.lightlylabs.lightly.shell.LightlyIcon
import com.lightlylabs.lightly.shell.LightlyIcons
import com.lightlylabs.lightly.shell.SegmentedControl
import com.lightlylabs.lightly.shell.lightlyColors
import com.lightlylabs.lightly.shell.lightlyTextStyle
import com.lightlylabs.lightly.shell.testTagResource

/** Stable tags for tests and captures. */
object BackgroundTags {
    const val TRY_AGAIN = "background-try-again"
    const val CANCEL = "background-cancel"
    const val REFINE = "background-refine"
    const val REMOVE = "background-remove-change"
    fun slider(field: String) = "background-slider-$field"
}

/**
 * Lightly 2 `backgroundPanel`: the Focus & Blur / Change background switch, then the state's content: Focus & Blur in a
 * 4 dp column, Change background and Refine edges in 8 dp, notices in 12 dp; the reset row follows the style or kind tabs.
 */
@Composable
fun BackgroundPanel(vm: EditorViewModel, ui: EditorUiState, roomy: Boolean) {
    val tool = ui.session?.current?.tools?.background ?: return
    val bg = ui.background
    val state = BackgroundPanelState.of(bg, ui.separation, tool.replacement)
    val gap = when (state) { BackgroundPanelState.Focus -> 4.dp; BackgroundPanelState.Refine, is BackgroundPanelState.Change -> 8.dp; else -> 12.dp }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(gap)) {
        val segment = if (bg.sub == BackgroundSub.CHANGE) BackgroundSub.CHANGE else BackgroundSub.FOCUS
        // Owner (2026-10-11): the same tab row as every other sub-menu (was a segmented control).
        OptionTabs(listOf(BackgroundSub.FOCUS to "Focus & Blur", BackgroundSub.CHANGE to "Change background"), segment, vm::selectBackgroundSub, tagPrefix = "background-mode")
        val reset: @Composable () -> Unit = {
            ResetRow(vm, "background", if (bg.sub == BackgroundSub.CHANGE) "Change background" else if (bg.sub == BackgroundSub.REFINE) "Refine edges" else "Focus & Blur", bg.sub.name.lowercase())
        }
        when (state) {
            BackgroundPanelState.NoSubject -> {
                Notice(LightlyIcons.Info, bold("No clear subject found.", " Change background needs a person or object in front. You can still blur by tapping where to focus."))
                FocusSlider(vm, ui, "Blur", "blur", tool.focus.blur, 0.0, 100.0)
            }
            BackgroundPanelState.Separating -> Notice(LightlyIcons.Info, AnnotatedString("Finding the subject…"), listOf("Cancel" to vm::cancelSeparation))
            BackgroundPanelState.EstimatingDepth -> Notice(LightlyIcons.Info, AnnotatedString("Estimating depth…"), listOf("Cancel" to vm::cancelSeparation))
            BackgroundPanelState.Failed -> { reset(); Notice(LightlyIcons.Warn, bold("Couldn't separate the subject.", " Your other edits are kept."), listOf("Try again" to vm::retrySeparation)) }
            BackgroundPanelState.DepthFailed -> { reset(); Notice(LightlyIcons.Warn, bold("Couldn't measure depth.", " Blur needs it. Change background still works."), listOf("Try again" to vm::retrySeparation)) }
            BackgroundPanelState.Refine -> { reset(); RefineBody(vm, ui) }
            is BackgroundPanelState.Change -> ChangeBody(vm, ui, tool, state.kind, reset)
            BackgroundPanelState.Focus -> FocusBody(vm, ui, tool, reset)
        }
    }
}

@Composable
private fun bold(head: String, rest: String) = buildAnnotatedString {
    withStyle(SpanStyle(color = lightlyColors.ink, fontWeight = FontWeight.Bold)) { append(head) }
    append(rest)
}

/** A slider bound to a recipe field: shows the drag value while dragging, commits on release. */
@Composable
private fun FocusSlider(vm: EditorViewModel, ui: EditorUiState, label: String, field: String, committed: Double, min: Double, max: Double, display: (Double) -> Double = { it }, store: (Double) -> Double = { it }) {
    val drag = ui.background.sliderDrag?.takeIf { it.first == field }?.second
    SliderRow(
        label, display(drag ?: committed), min, max,
        onDrag = { vm.onBackgroundSlider(field, store(it)) },
        onRelease = { vm.onBackgroundSliderRelease(field, store(it)) },
        tag = BackgroundTags.slider(field),
    )
}

@Composable
private fun FocusBody(vm: EditorViewModel, ui: EditorUiState, tool: BackgroundTool, reset: @Composable () -> Unit) {
    val focus = tool.focus
    val colors = lightlyColors
    OptionTabs(BackgroundOptions.STYLES, focus.style, vm::setFocusStyle, tagPrefix = "focus-style")
    reset()
    when (focus.style) {
        // "Bokeh" (92 dp, 13 sp semibold ink2), then four 44×36 dp shape buttons, 14 dp corners, 8 dp apart.
        com.lightlylabs.lightly.session.FocusStyle.LENS -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Bokeh", style = l2TextStyle(13.sp, FontWeight.SemiBold, colors.ink2), modifier = Modifier.width(92.dp))
            BackgroundOptions.BOKEH.forEach { (bokeh, name) ->
                val icon = when (name) { "round" -> LightlyIcons.Circle; "hex" -> LightlyIcons.Hex; "heart" -> LightlyIcons.Heart; else -> LightlyIcons.StarShape }
                val on = focus.bokeh == bokeh
                val shape = RoundedCornerShape(14.dp)
                Box(
                    Modifier.heightIn(min = 44.dp).clickable(role = Role.RadioButton) { vm.setBokeh(bokeh) }
                        .semantics { contentDescription = "$name bokeh"; selected = on }.testTagResource("bokeh-$name"),
                    contentAlignment = Alignment.Center,
                ) {
                    Box(Modifier.size(width = 44.dp, height = 36.dp).clip(shape).background(if (on) colors.segmentOn else androidx.compose.ui.graphics.Color.Transparent)
                        .then(if (on) Modifier else Modifier.border(1.dp, colors.hair, shape)), contentAlignment = Alignment.Center) {
                        LightlyIcon(icon, size = 18.dp, tint = if (on) colors.onInk else colors.ink2)
                    }
                }
            }
        }
        com.lightlylabs.lightly.session.FocusStyle.SOFT -> FocusSlider(vm, ui, "Glow", "styleAmount", focus.styleAmount, 0.0, 100.0)
        com.lightlylabs.lightly.session.FocusStyle.SWIRL -> FocusSlider(vm, ui, "Swirl", "styleAmount", focus.styleAmount, 0.0, 100.0)
        com.lightlylabs.lightly.session.FocusStyle.MOTION -> FocusSlider(vm, ui, "Direction", "styleAmount", focus.styleAmount, -180.0, 180.0,
            display = { it * 3.6 - 180 }, store = { (it + 180) / 3.6 })
    }
    FocusSlider(vm, ui, "Blur", "blur", focus.blur, 0.0, 100.0)
    FocusSlider(vm, ui, "Focus depth", "depthOfField", focus.depthOfField, 0.0, 100.0)
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        QuietSmallButton("Refine edges", { vm.selectBackgroundSub(BackgroundSub.REFINE) }, Modifier.testTagResource(BackgroundTags.REFINE), icon = LightlyIcons.Brush, accent = true)
        PanelNote("Tap the photo to set focus.")
    }
}

@Composable
private fun RefineBody(vm: EditorViewModel, ui: EditorUiState) {
    PanelNote("Brush over the edge to add to or remove from the subject.")
    SegmentedControl(listOf(BrushMode.ADD to "Add", BrushMode.ERASE to "Remove"), ui.background.brush, vm::setBrushMode, icons = mapOf(BrushMode.ADD to LightlyIcons.Brush, BrushMode.ERASE to LightlyIcons.Erase))
    // The brush size is a UI-only value (`ui.brushSize`, 40); strokes store their own radius.
    SliderRow("Brush size", ui.background.brushSize.toDouble(), 0.0, 100.0, onDrag = { vm.setBrushSize(it.toInt()) }, onRelease = { vm.setBrushSize(it.toInt()) }, tag = BackgroundTags.slider("brushSize"))
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        QuietSmallButton("Done", { vm.selectBackgroundSub(BackgroundSub.FOCUS) })
    }
}

@Composable
private fun ChangeBody(vm: EditorViewModel, ui: EditorUiState, tool: BackgroundTool, kind: ReplacementKind, reset: @Composable () -> Unit) {
    val replaced = tool.replacement
    OptionTabs(ReplacementKind.entries.map { it to it.label }, kind, vm::selectReplacementKind, tagPrefix = "replacement-kind")
    reset()
    when (kind) {
        // The (+) tile first, then the bundled backgrounds: 60 dp, 16 dp corners.
        ReplacementKind.IMAGE -> ChipRow {
            AddTile("Choose a photo", vm::chooseBackgroundPhoto, tag = "background-add-photo") { LightlyIcon(LightlyIcons.Plus, tint = lightlyColors.ink2) }
            BackgroundOptions.IMAGES.forEach { (id, file) ->
                val on = (replaced as? Replacement.Image)?.image == AssetRef.Bundled(id)
                BackgroundThumb(file, on) { vm.chooseBackgroundImage(id) }
            }
        }
        ReplacementKind.COLOUR -> ColourControl("Background colour", (replaced as? Replacement.Colour)?.colour ?: "#F4F1EC", ui.original, "background-colour", vm::chooseBackgroundColour, previewPhoto = ui.preview, preview = { vm.previewColour("background-colour", it) }, cancel = vm::cancelPhotoGesturePreview)
        ReplacementKind.GRADIENT -> Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            BackgroundOptions.GRADIENTS.forEachIndexed { index, (angle, stops) ->
                val on = (replaced as? Replacement.Gradient)?.let { g -> g.angle == angle && g.stops.map { it.colour } == stops } == true
                Swatch({ size -> cssLinearGradient(angle, stops.map(::colourOf), size.width, size.height) }, on, "Gradient ${index + 1}", { vm.chooseBackgroundGradient(index) }, tag = "gradient-$index")
            }
        }
    }
    if (kind == ReplacementKind.GRADIENT && replaced is Replacement.Gradient) {
        replaced.stops.forEachIndexed { index, stop ->
            ColourControl("Colour ${index + 1}", stop.colour, ui.original, "gradient-colour-$index", { vm.gradientColour(index, it, false) },
                previewPhoto = ui.preview, preview = { vm.gradientColour(index, it, true) }, cancel = vm::cancelPhotoGesturePreview)
        }
    }
    if (kind == ReplacementKind.IMAGE && replaced is Replacement.Image) {
        FocusSlider(vm, ui, "Scale", "scale", replaced.scale, 100.0, 200.0)
        PanelNote("Drag the photo to position the background.")
    }
    if (replaced != null) {
        QuietSmallButton("Remove background change", vm::removeBackgroundChange, Modifier.testTagResource(BackgroundTags.REMOVE))
        PanelNote("Focus & Blur still works on the new background.")
    }
}

/** A background choice: 60 dp, 16 dp corners; when chosen, a 2 dp sheet-coloured gap and a 2 dp accent ring outside it. */
@Composable
private fun BackgroundThumb(file: String, selected: Boolean, onClick: () -> Unit) {
    val context = LocalContext.current
    val colors = lightlyColors
    val bitmap: ImageBitmap? = remember(file) {
        runCatching { context.assets.open("backgrounds/${file}_thumb.jpg").use { BitmapFactory.decodeStream(it)?.asImageBitmap() } }.getOrNull()
    }
    val shape = RoundedCornerShape(16.dp)
    Box(
        Modifier
            .size(60.dp)
            .drawBehind {
                if (selected) {
                    drawRoundRect(colors.sheet, androidx.compose.ui.geometry.Offset(-2.dp.toPx(), -2.dp.toPx()), androidx.compose.ui.geometry.Size(size.width + 4.dp.toPx(), size.height + 4.dp.toPx()),
                        androidx.compose.ui.geometry.CornerRadius(18.dp.toPx()), style = androidx.compose.ui.graphics.drawscope.Stroke(2.dp.toPx()))
                    drawRoundRect(colors.sel, androidx.compose.ui.geometry.Offset(-3.dp.toPx(), -3.dp.toPx()), androidx.compose.ui.geometry.Size(size.width + 6.dp.toPx(), size.height + 6.dp.toPx()),
                        androidx.compose.ui.geometry.CornerRadius(20.dp.toPx()), style = androidx.compose.ui.graphics.drawscope.Stroke(2.dp.toPx()))
                }
            }
            .clip(shape)
            .clickable(role = Role.RadioButton, onClick = onClick)
            .semantics { contentDescription = "Background image"; this.selected = selected }
            .testTagResource("background-image-$file"),
    ) {
        if (bitmap != null) Image(bitmap, null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
    }
}
