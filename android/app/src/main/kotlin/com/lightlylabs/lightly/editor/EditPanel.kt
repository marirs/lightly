package com.lightlylabs.lightly.editor

import androidx.compose.foundation.layout.Arrangement

import androidx.compose.foundation.shape.RoundedCornerShape

import androidx.compose.foundation.layout.Spacer

import androidx.compose.foundation.layout.Box

import androidx.compose.foundation.layout.Column
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.draw.clip
import androidx.compose.runtime.remember
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.clickable
import androidx.compose.foundation.border
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.shell.LightlyIcon
import com.lightlylabs.lightly.shell.LightlyIcons
import com.lightlylabs.lightly.shell.lightlyColors
import com.lightlylabs.lightly.shell.lightlyTextStyle
import com.lightlylabs.lightly.shell.testTagResource

/** Stable tags for tests and captures. */
object EditTags {
    const val UNDO_STROKE = "edit-undo-stroke"
    const val TRY_AGAIN = "edit-try-again"
    const val CANCEL = "edit-cancel"
    fun slider(field: String) = "edit-slider-$field"
    fun aspect(label: String) = "edit-aspect-$label"
    fun geometry(action: String) = "edit-geometry-$action"
}

/** Prototype `editPanel`: Crop, Rotate, Straighten, Perspective, Adjust and Remove, with the approved copy verbatim. */
@Composable
fun EditPanel(vm: EditorViewModel, ui: EditorUiState, roomy: Boolean) = Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
    // Lightly 2 `editPanel`, a 6 dp column: the tabs, the reset row, the tab's controls.
    val edit = ui.session?.current?.tools?.edit ?: return@Column
    OptionTabs(EditSub.entries.map { it to it.label }, ui.edit.sub, vm::selectEditSub, tagPrefix = "edit-tab")
    ResetRow(vm, "edit", ui.edit.sub.label, ui.edit.sub.name.lowercase())
    when (ui.edit.sub) {
        // Inline free crop (owner, 2026-10-11): the frame is on the photo; the panel only says how to use it. No aspect
        // presets (owner: not asked for).
        EditSub.CROP -> PanelNote("Drag the corners or edges. Drag inside to move. Pinch to resize.")
        // Rotate: a 2×2 grid, 8 dp gaps, of 46 dp outlined buttons (16 dp corners), an 18 dp icon and a 13 sp semibold
        // label; a flip that is on shows in the accent colour.
        EditSub.ROTATE -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            val geometry = edit.geometry
            listOf(
                listOf(Triple(LightlyIcons.RotateLeft, "Rotate left", false) to { vm.rotate(-1) }, Triple(LightlyIcons.RotateRight, "Rotate right", false) to { vm.rotate(1) }),
                listOf(Triple(LightlyIcons.FlipHorizontal, "Flip horizontal", geometry.flipHorizontal) to vm::flipHorizontal,
                    Triple(LightlyIcons.FlipVertical, "Flip vertical", geometry.flipVertical) to vm::flipVertical),
            ).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    row.forEach { (spec, action) ->
                        val (icon, label, on) = spec
                        val ink = if (on) lightlyColors.sel else lightlyColors.ink
                        Row(
                            Modifier.weight(1f).heightIn(min = 46.dp).clip(RoundedCornerShape(16.dp)).border(1.dp, if (on) lightlyColors.sel else lightlyColors.hair, RoundedCornerShape(16.dp))
                                .clickable(role = Role.Button, onClick = action).semantics { selected = on }
                                .testTagResource(EditTags.geometry(label.lowercase().replace(' ', '-'))),
                            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically,
                        ) {
                            LightlyIcon(icon, size = 18.dp, tint = ink)
                            Text(label, style = com.lightlylabs.lightly.shell.l2TextStyle(13.sp, FontWeight.SemiBold, ink), maxLines = 1)
                        }
                    }
                }
            }
        }
        EditSub.STRAIGHTEN -> {
            EditSlider(vm, ui, "Angle", "straighten", edit.geometry.straighten, -45.0, 45.0)
            PanelNote("The photo is zoomed slightly so no empty corners show.")
        }
        EditSub.PERSPECTIVE -> {
            EditSlider(vm, ui, "Vertical", "perspectiveVertical", edit.geometry.perspective.vertical, -100.0, 100.0)
            EditSlider(vm, ui, "Horizontal", "perspectiveHorizontal", edit.geometry.perspective.horizontal, -100.0, 100.0)
        }
        EditSub.ADJUST -> {
            val a = edit.adjust
            // Owner (2026-10-11): the same tab row as every other sub-menu (was a segmented control).
            OptionTabs(AdjustGroup.entries.map { it to it.label }, ui.edit.group, vm::selectAdjustGroup, tagPrefix = "edit-group")
            when (ui.edit.group) {
                AdjustGroup.LIGHT -> {
                    EditSlider(vm, ui, "Exposure", "exposure", a.exposure, -100.0, 100.0)
                    EditSlider(vm, ui, "Contrast", "contrast", a.contrast, -100.0, 100.0)
                    EditSlider(vm, ui, "Highlights", "highlights", a.highlights, -100.0, 100.0)
                    EditSlider(vm, ui, "Shadows", "shadows", a.shadows, -100.0, 100.0)
                }
                AdjustGroup.COLOUR -> {
                    EditSlider(vm, ui, "Temperature", "temp", a.temp, -100.0, 100.0)
                    EditSlider(vm, ui, "Tint", "tint", a.tint, -100.0, 100.0)
                    EditSlider(vm, ui, "Saturation", "saturation", a.saturation, -100.0, 100.0)
                    EditSlider(vm, ui, "Vibrance", "vibrance", a.vibrance, -100.0, 100.0)
                }
                AdjustGroup.DETAIL -> {
                    EditSlider(vm, ui, "Sharpness", "sharpness", a.sharpness, 0.0, 100.0)
                    EditSlider(vm, ui, "Clarity", "clarity", a.clarity, -100.0, 100.0)
                    EditSlider(vm, ui, "Noise reduction", "noise", a.noise, 0.0, 100.0)
                }
            }
        }
        EditSub.REMOVE -> RemoveBody(vm, ui, hasStrokes = edit.remove.strokes.isNotEmpty())
    }
}

@Composable
private fun RemoveBody(vm: EditorViewModel, ui: EditorUiState, hasStrokes: Boolean) {
    when (ui.edit.removeOp) {
        RemoveOp.REMOVING -> Notice(LightlyIcons.Info, AnnotatedString("Removing…"), listOf("Cancel" to vm::cancelRemove))
        RemoveOp.FAILED -> Notice(LightlyIcons.Warn, boldLead("Couldn't remove that area.", " Try a smaller stroke. Your other edits are kept."), listOf("Try again" to vm::retryRemove))
        RemoveOp.IDLE -> {
            // The prototype's brush size is a UI-only value (`ui.brushSize`, 35); strokes store their own radius.
            SliderRow("Brush size", ui.edit.brushSize.toDouble(), 0.0, 100.0, onDrag = { vm.setRemoveBrushSize(it.toInt()) }, onRelease = { vm.setRemoveBrushSize(it.toInt()) }, tag = EditTags.slider("brushSize"))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                QuietSmallButton("Undo stroke", { if (hasStrokes) vm.undoStroke() }, Modifier.testTagResource(EditTags.UNDO_STROKE), dimmed = !hasStrokes)
                PanelNote("Brush over anything you want removed.")
            }
        }
    }
}

@Composable
internal fun boldLead(head: String, rest: String) = buildAnnotatedString {
    withStyle(SpanStyle(color = lightlyColors.ink, fontWeight = FontWeight.Bold)) { append(head) }
    append(rest)
}

/** A slider bound to an Edit field: shows the drag value while dragging, commits on release. */
@Composable
private fun EditSlider(vm: EditorViewModel, ui: EditorUiState, label: String, field: String, committed: Double, min: Double, max: Double) {
    val drag = ui.edit.sliderDrag?.takeIf { it.first == field }?.second
    SliderRow(label, drag ?: committed, min, max, onDrag = { vm.onEditSlider(field, it) }, onRelease = { vm.onEditSliderRelease(field, it) }, tag = EditTags.slider(field))
}

/** Prototype `effectsPanel`: the three tabs (dot when on), the On/Off row, the controls and the preset notice. */
@Composable
fun EffectsPanel(vm: EditorViewModel, ui: EditorUiState, roomy: Boolean) = Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(5.dp)) {
    // Lightly 2 `effectsPanel`, a 5 dp column: tabs (dots on effects in use), reset row, conflict notice, controls.
    val fx = ui.session?.current?.tools?.effects ?: return@Column
    val sub = ui.effects.sub
    fun on(s: EffectsSub) = when (s) {
        EffectsSub.LEAK -> fx.lightLeak.enabled; EffectsSub.GRAIN -> fx.grain.enabled; EffectsSub.VIGNETTE -> fx.vignette.enabled
        EffectsSub.SELECTIVE -> fx.selectiveColour != null
    }
    OptionTabs(EffectsSub.entries.map { it to it.label }, sub, vm::selectEffectsSub, dotted = ::on, tagPrefix = "effects-tab")
    ResetRow(vm, "effects", sub.label, sub.name.lowercase())
    // The approved notice sits between the tabs and the body.
    if ((sub == EffectsSub.GRAIN || sub == EffectsSub.VIGNETTE) && on(sub) && vm.presetHasOwn(sub, ui)) {
        Notice(LightlyIcons.Info, AnnotatedString("The applied preset already includes its own ${if (sub == EffectsSub.GRAIN) "grain" else "vignette"}. This one is added to it, not replaced."))
    }
    // Selective Colour has no On switch: a kept colour applies it (reference: docs/ui/proposals/selective-colour at 330cf5b; status in its README).
    when (sub) {
        EffectsSub.LEAK -> {
            ChipRow(spacing = 6.dp) {
                EditOptions.LEAK_STYLES.forEach { (style, label) ->
                    val selected = fx.lightLeak.enabled && fx.lightLeak.style == style
                    OptChip(selected, label, { vm.setLeakStyle(style) }, tag = "leak-${style.name.lowercase()}") { Text(label, maxLines = 1) }
                }
            }
            EffectsSlider(vm, ui, "Intensity", "leakIntensity", fx.lightLeak.intensity, 0.0, 100.0)
            EffectsSlider(vm, ui, "Rotation", "leakRotation", fx.lightLeak.rotation, -180.0, 180.0)
            PanelNote("Drag on the photo to move the leak.")
        }
        EffectsSub.GRAIN -> {
            ChipRow(spacing = 6.dp) {
                EditOptions.GRAIN_STYLES.forEach { (style, label) ->
                    val selected = fx.grain.enabled && fx.grain.style == style
                    OptChip(selected, label, { vm.setGrainStyle(style) }, tag = "grain-${style.name.lowercase()}") { Text(label, maxLines = 1) }
                }
            }
            EffectsSlider(vm, ui, "Amount", "grainAmount", fx.grain.amount, 0.0, 100.0)
            EffectsSlider(vm, ui, "Size", "grainSize", fx.grain.size, 0.0, 100.0)
            EffectsSlider(vm, ui, "Roughness", "grainRoughness", fx.grain.roughness, 0.0, 100.0)
        }
        EffectsSub.VIGNETTE -> {
            EffectsSlider(vm, ui, "Amount", "vignetteAmount", fx.vignette.amount, 0.0, 100.0)
            EffectsSlider(vm, ui, "Size", "vignetteSize", fx.vignette.size, 0.0, 100.0)
            EffectsSlider(vm, ui, "Softness", "vignetteSoftness", fx.vignette.softness, 0.0, 100.0)
        }
        EffectsSub.SELECTIVE -> SelectiveColourBody(vm, ui, fx.selectiveColour)
    }
}

/**
 * Effects › Selective Colour, as in docs/ui/proposals/selective-colour at 330cf5b (status in its README): nothing kept,
 * one instruction; then the kept colours (28 dp dots in 48 dp targets; with more than one, a small × removes just that
 * colour), (+) to add another (the next tap on the photo) and Clear on one row; Range and Strength below.
 */
/**
 * Selective Colour: nothing kept, the picker icon and "Tap a colour in the photo to keep it." (14 sp ink2, 44 dp row);
 * then the kept colours (30 dp dots with a 2 dp sheet gap and a 1 dp line; × badges with several), the (+) circle (dashed
 * ink3, solid accent while adding) and Clear at the end; the hint while adding; Range and Strength.
 */
@Composable
private fun SelectiveColourBody(vm: EditorViewModel, ui: EditorUiState, selective: com.lightlylabs.lightly.session.SelectiveColourTool?) {
    val colors = lightlyColors
    if (selective == null && !ui.effects.addingColour) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 44.dp).semantics(mergeDescendants = true) {}.testTag("effects-selective-hint"),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            LightlyIcon(LightlyIcons.Picker, size = 20.dp, tint = colors.ink2)
            Text("Tap a colour in the photo to keep it.", style = com.lightlylabs.lightly.shell.l2TextStyle(14.sp, color = colors.ink2))
        }
        return
    }
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        val kept = selective?.colours.orEmpty()
        val removable = kept.size > 1
        kept.forEachIndexed { index, k -> KeptColourDot(k, removable, index) { vm.removeSelectiveColour(index) } }
        AddColourButton(adding = ui.effects.addingColour, enabled = kept.size < EditorViewModel.MAX_KEPT_COLOURS, onClick = vm::toggleAddingColour)
        Spacer(Modifier.weight(1f))
        com.lightlylabs.lightly.shell.LinkButton("Clear", vm::clearSelectiveColour, tag = "effects-selective-clear")
    }
    if (ui.effects.addingColour) PanelNote("Tap another colour in the photo.")
    if (selective != null) {
        EffectsSlider(vm, ui, "Range", "selectiveRange", selective.range, 0.0, 100.0)
        EffectsSlider(vm, ui, "Strength", "selectiveStrength", selective.strength, 0.0, 100.0)
    }
}

@Composable
private fun KeptColourDot(kept: com.lightlylabs.lightly.session.KeptColourRecipe, removable: Boolean, index: Int, onRemove: () -> Unit) {
    val colour = remember(kept) { displayColour(kept.oklab) }
    val colors = lightlyColors
    val target = Modifier.size(width = 36.dp, height = 44.dp)
    val modifier = if (removable) target.clickable(onClickLabel = "Remove colour ${index + 1}", role = Role.Button, onClick = onRemove)
        .semantics { contentDescription = "Remove colour ${index + 1}" }.testTag("effects-selective-remove-$index")
        else target.semantics { contentDescription = "Kept colour" }.testTag("effects-selective-colour-$index")
    Box(modifier, contentAlignment = Alignment.Center) {
        Box(Modifier.size(36.dp).border(1.dp, colors.hair, CircleShape).padding(1.dp).border(2.dp, colors.sheet, CircleShape).padding(2.dp).clip(CircleShape).background(colour))
        if (removable) {
            Box(
                Modifier.align(Alignment.Center).offset(x = 15.dp, y = (-15).dp).size(16.dp).clip(CircleShape).background(colors.ink),
                contentAlignment = Alignment.Center,
            ) { LightlyIcon(LightlyIcons.Close, size = 10.dp, tint = colors.bg) }
        }
    }
}

@Composable
private fun AddColourButton(adding: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val colors = lightlyColors
    val tint = if (adding) colors.sel else colors.ink2
    Box(
        Modifier.size(width = 36.dp, height = 44.dp).clickable(enabled = enabled, onClickLabel = "Add another colour", role = Role.Button, onClick = onClick)
            .semantics { contentDescription = "Add another colour"; selected = adding }.testTag("effects-selective-add"),
        contentAlignment = Alignment.Center,
    ) {
        androidx.compose.foundation.Canvas(Modifier.size(30.dp)) {
            val w = 1.5.dp.toPx()
            drawCircle(if (adding) colors.sel else colors.ink3, radius = size.minDimension / 2 - w / 2,
                style = androidx.compose.ui.graphics.drawscope.Stroke(w, pathEffect = if (adding) null else androidx.compose.ui.graphics.PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 2.dp.toPx()))))
        }
        LightlyIcon(LightlyIcons.Plus, size = 16.dp, tint = tint)
    }
}

/** A kept colour as shown on its dot: its OKLab in sRGB. */
private fun displayColour(oklab: List<Double>): androidx.compose.ui.graphics.Color {
    val linear = DoubleArray(3)
    com.lightlylabs.lightly.develop.ColourMath.oklabToLinear(oklab[0], oklab[1], oklab[2], linear)
    fun encode(v: Double) = com.lightlylabs.lightly.develop.ColourMath.linearToSrgb(v).coerceIn(0.0, 1.0).toFloat()
    return androidx.compose.ui.graphics.Color(encode(linear[0]), encode(linear[1]), encode(linear[2]))
}

@Composable
private fun EffectsSlider(vm: EditorViewModel, ui: EditorUiState, label: String, field: String, committed: Double, min: Double, max: Double) {
    val drag = ui.effects.sliderDrag?.takeIf { it.first == field }?.second
    val fx = ui.session?.current?.tools?.effects
    val shown = when {
        field == "leakIntensity" && fx?.lightLeak?.enabled != true -> 0.0
        field == "grainAmount" && fx?.grain?.enabled != true -> 0.0
        field == "vignetteAmount" && fx?.vignette?.enabled != true -> 0.0
        else -> committed
    }
    SliderRow(label, drag ?: shown, min, max, onDrag = { vm.onEffectsSlider(field, it) }, onRelease = { vm.onEffectsSliderRelease(field, it) }, tag = "effects-slider-$field")
}

/**
 * `<button class="listrow" style="border:0;min-height:44px;width:100%">`: "On"/"Off" and the approved
 * switch at the end. The whole row toggles; semantics are a Switch.
 */
@Composable
private fun OnOffRow(on: Boolean, name: String, onToggle: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .toggleable(value = on, role = Role.Switch, onValueChange = { onToggle() })
            // TalkBack names the effect ("Vignette, switch, on"); the row itself shows only On/Off (as iOS).
            .semantics { contentDescription = name }
            .testTagResource("effects-on-off")
            .padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(if (on) "On" else "Off", style = lightlyTextStyle(15.sp, color = lightlyColors.ink), modifier = Modifier.weight(1f))
        com.lightlylabs.lightly.shell.ToggleKnob(on)
    }
}
