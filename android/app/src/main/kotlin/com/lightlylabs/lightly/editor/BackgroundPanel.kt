package com.lightlylabs.lightly.editor

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
 * Prototype `backgroundPanel`: the Focus & Blur / Change background segment, then the state the
 * photo and this build allow ([BackgroundPanelState]) with the approved copy, verbatim.
 */
@Composable
fun BackgroundPanel(vm: EditorViewModel, ui: EditorUiState, roomy: Boolean) = Column(Modifier.fillMaxWidth()) {
    if (roomy) PanelTitle("Background")
    val tool = ui.session?.current?.tools?.background ?: return@Column
    val bg = ui.background
    val segment = if (bg.sub == BackgroundSub.CHANGE) BackgroundSub.CHANGE else BackgroundSub.FOCUS
    SegmentedControl(listOf(BackgroundSub.FOCUS to "Focus & Blur", BackgroundSub.CHANGE to "Change background"), segment, vm::selectBackgroundSub)
    ResetRow(vm, "background", if (bg.sub == BackgroundSub.CHANGE) "Change background" else if (bg.sub == BackgroundSub.REFINE) "Refine edges" else "Focus & Blur", bg.sub.name.lowercase())
    when (val state = BackgroundPanelState.of(bg, ui.separation, tool.replacement)) {
        BackgroundPanelState.NoSubject -> {
            Notice(LightlyIcons.Info, bold("No clear subject found.", " Change background needs a person or object in front. You can still blur by tapping where to focus."))
            FocusSlider(vm, ui, "Blur", "blur", tool.focus.blur, 0.0, 100.0)
        }
        BackgroundPanelState.Separating -> Notice(LightlyIcons.Info, AnnotatedString("Finding the subject…"), listOf("Cancel" to vm::cancelSeparation))
        // PROPOSED copy (owner approval pending, 2026-10-07): see BackgroundPanelState.EstimatingDepth.
        BackgroundPanelState.EstimatingDepth -> Notice(LightlyIcons.Info, AnnotatedString("Estimating depth…"), listOf("Cancel" to vm::cancelSeparation))
        BackgroundPanelState.Failed -> Notice(LightlyIcons.Warn, bold("Couldn't separate the subject.", " Your other edits are kept."), listOf("Try again" to vm::retrySeparation))
        // PROPOSED copy (owner approval pending, 2026-10-05): see BackgroundPanelState.DepthFailed.
        BackgroundPanelState.DepthFailed -> Notice(LightlyIcons.Warn, bold("Couldn't measure depth.", " Blur needs it. Change background still works."), listOf("Try again" to vm::retrySeparation))
        BackgroundPanelState.Refine -> RefineBody(vm, ui)
        is BackgroundPanelState.Change -> ChangeBody(vm, ui, tool, state.kind)
        BackgroundPanelState.Focus -> FocusBody(vm, ui, tool)
    }
}

@Composable
private fun bold(head: String, rest: String) = buildAnnotatedString {
    withStyle(SpanStyle(color = lightlyColors.ink, fontWeight = FontWeight.SemiBold)) { append(head) }
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
private fun FocusBody(vm: EditorViewModel, ui: EditorUiState, tool: BackgroundTool) {
    val focus = tool.focus
    OptionTabs(BackgroundOptions.STYLES, focus.style, vm::setFocusStyle, tagPrefix = "focus-style")
    when (focus.style) {
        com.lightlylabs.lightly.session.FocusStyle.LENS -> ChipRow {
            Text("Bokeh", style = lightlyTextStyle(color = lightlyColors.ink2), modifier = Modifier.widthIn(min = 72.dp))
            BackgroundOptions.BOKEH.forEach { (bokeh, name) ->
                val icon = when (name) { "round" -> LightlyIcons.Circle; "hex" -> LightlyIcons.Hex; "heart" -> LightlyIcons.Heart; else -> LightlyIcons.StarShape }
                OptChip(focus.bokeh == bokeh, "$name bokeh", { vm.setBokeh(bokeh) }, tag = "bokeh-$name") {
                    LightlyIcon(icon, size = 18.dp, tint = if (focus.bokeh == bokeh) lightlyColors.sel else lightlyColors.ink2)
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
    Row(Modifier.fillMaxWidth().padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        QuietSmallButton("Refine edges", { vm.selectBackgroundSub(BackgroundSub.REFINE) }, Modifier.testTagResource(BackgroundTags.REFINE), icon = LightlyIcons.Brush)
        Text("Tap the photo to set focus.", style = lightlyTextStyle(13.sp, color = lightlyColors.ink3), modifier = Modifier.padding(horizontal = 8.dp))
    }
}

@Composable
private fun RefineBody(vm: EditorViewModel, ui: EditorUiState) {
    PanelNote("Brush over the edge to add to or remove from the subject.")
    SegmentedControl(listOf(BrushMode.ADD to "Add", BrushMode.ERASE to "Remove"), ui.background.brush, vm::setBrushMode, icons = mapOf(BrushMode.ADD to LightlyIcons.Brush, BrushMode.ERASE to LightlyIcons.Erase))
    // The prototype's brush size is a UI-only value (`ui.brushSize`, 40); strokes store their own radius.
    SliderRow("Brush size", ui.background.brushSize.toDouble(), 0.0, 100.0, onDrag = { vm.setBrushSize(it.toInt()) }, onRelease = { vm.setBrushSize(it.toInt()) }, tag = BackgroundTags.slider("brushSize"))
    Row(Modifier.fillMaxWidth().padding(horizontal = 10.dp), horizontalArrangement = Arrangement.End) {
        QuietSmallButton("Done", { vm.selectBackgroundSub(BackgroundSub.FOCUS) }, large = true)
    }
}

@Composable
private fun ChangeBody(vm: EditorViewModel, ui: EditorUiState, tool: BackgroundTool, kind: ReplacementKind) {
    val replaced = tool.replacement
    OptionTabs(ReplacementKind.entries.map { it to it.label }, kind, vm::selectReplacementKind, tagPrefix = "replacement-kind")
    when (kind) {
        ReplacementKind.IMAGE -> ChipRow {
            BackgroundOptions.IMAGES.forEach { (id, file) ->
                val on = (replaced as? Replacement.Image)?.image == AssetRef.Bundled(id)
                BackgroundThumb(file, on) { vm.chooseBackgroundImage(id) }
            }
            AddTile("Choose a photo", vm::chooseBackgroundPhoto, tag = "background-add-photo") { LightlyIcon(LightlyIcons.Plus, tint = lightlyColors.ink2) }
        }
        ReplacementKind.COLOUR -> ChipRow {
            BackgroundOptions.SWATCHES.forEach { hex ->
                Swatch({ SolidColor(colourOf(hex)) }, (replaced as? Replacement.Colour)?.colour == hex, "Colour $hex", { vm.chooseBackgroundColour(hex) }, tag = "swatch-$hex", colourName = SwatchNames.of(hex))
            }
        }
        ReplacementKind.GRADIENT -> ChipRow {
            BackgroundOptions.GRADIENTS.forEachIndexed { index, (angle, stops) ->
                val on = (replaced as? Replacement.Gradient)?.let { g -> g.angle == angle && g.stops.map { it.colour } == stops } == true
                Swatch({ size -> cssLinearGradient(angle, stops.map(::colourOf), size.width, size.height) }, on, "Gradient", { vm.chooseBackgroundGradient(index) }, tag = "gradient-$index", width = 52.dp, cornerRadius = 10.dp)
            }
        }
    }
    if (kind == ReplacementKind.IMAGE && replaced is Replacement.Image) {
        FocusSlider(vm, ui, "Scale", "scale", replaced.scale, 100.0, 200.0)
        PanelNote("Drag the photo to position the background.")
    }
    if (replaced != null) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 6.dp)) {
            QuietSmallButton("Remove background change", vm::removeBackgroundChange, Modifier.testTagResource(BackgroundTags.REMOVE))
        }
        PanelNote("Focus & Blur still works on the new background.")
    }
}

/** `.thumbopt`: a 64 dp bundled background photo, selection ring 2 dp. */
@Composable
private fun BackgroundThumb(file: String, selected: Boolean, onClick: () -> Unit) {
    val context = LocalContext.current
    val bitmap: ImageBitmap? = remember(file) {
        runCatching { context.assets.open("backgrounds/${file}_thumb.jpg").use { BitmapFactory.decodeStream(it)?.asImageBitmap() } }.getOrNull()
    }
    val shape = RoundedCornerShape(10.dp)
    Box(
        Modifier
            .size(64.dp)
            .clip(shape)
            .clickable(role = Role.RadioButton, onClick = onClick)
            .semantics { contentDescription = "Background image"; this.selected = selected }
            .testTagResource("background-image-$file"),
    ) {
        if (bitmap != null) Image(bitmap, null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize().clip(shape))
        // `.thumbopt` border (2 px, transparent unless selected) is drawn over the photo, as CSS does.
        if (selected) Box(Modifier.fillMaxSize().border(2.dp, lightlyColors.sel, shape))
    }
}
