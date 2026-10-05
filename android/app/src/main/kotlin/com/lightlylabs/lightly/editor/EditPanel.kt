package com.lightlylabs.lightly.editor

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
fun EditPanel(vm: EditorViewModel, ui: EditorUiState, roomy: Boolean) = Column(Modifier.fillMaxWidth()) {
    if (roomy) PanelTitle("Edit")
    val edit = ui.session?.current?.tools?.edit ?: return@Column
    OptionTabs(EditSub.entries.map { it to it.label }, ui.edit.sub, vm::selectEditSub, tagPrefix = "edit-tab")
    when (ui.edit.sub) {
        EditSub.CROP -> {
            ChipRow {
                EditOptions.ASPECTS.forEach { (aspect, label) ->
                    val on = edit.geometry.crop.aspect == aspect
                    OptChip(on, label, { vm.setCropAspect(aspect) }, tag = EditTags.aspect(label)) {
                        Text(label, style = lightlyTextStyle(color = if (on) lightlyColors.sel else lightlyColors.ink2), maxLines = 1)
                    }
                }
            }
            PanelNote("Drag a corner or an edge to crop. Drag inside to move.")
        }
        EditSub.ROTATE -> ChipRow {
            listOf(
                Triple(LightlyIcons.RotateLeft, "Rotate left", { vm.rotate(-1) }),
                Triple(LightlyIcons.RotateRight, "Rotate right", { vm.rotate(1) }),
                Triple(LightlyIcons.FlipHorizontal, "Flip horizontal", vm::flipHorizontal),
                Triple(LightlyIcons.FlipVertical, "Flip vertical", vm::flipVertical),
            ).forEach { (icon, label, action) ->
                // Prototype: plain `.opt` buttons (never shown selected).
                OptChip(false, label, action, tag = EditTags.geometry(label.lowercase().replace(' ', '-'))) {
                    LightlyIcon(icon, size = 18.dp, tint = lightlyColors.ink2)
                    Text(label, style = lightlyTextStyle(color = lightlyColors.ink2), maxLines = 1)
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
            OptionTabs(AdjustGroup.entries.map { it to it.label }, ui.edit.group, vm::selectAdjustGroup, tagPrefix = "adjust-group")
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
            Row(Modifier.fillMaxWidth().padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                // `disabled style="opacity:.4"` without strokes.
                QuietSmallButton("Undo stroke", { if (hasStrokes) vm.undoStroke() }, Modifier.alpha(if (hasStrokes) 1f else 0.4f).testTagResource(EditTags.UNDO_STROKE))
                PanelNote("Brush over anything you want removed.")
            }
        }
    }
}

@Composable
internal fun boldLead(head: String, rest: String) = buildAnnotatedString {
    withStyle(SpanStyle(color = lightlyColors.ink, fontWeight = FontWeight.SemiBold)) { append(head) }
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
fun EffectsPanel(vm: EditorViewModel, ui: EditorUiState, roomy: Boolean) = Column(Modifier.fillMaxWidth()) {
    if (roomy) PanelTitle("Effects")
    val fx = ui.session?.current?.tools?.effects ?: return@Column
    val sub = ui.effects.sub
    fun on(s: EffectsSub) = when (s) {
        EffectsSub.LEAK -> fx.lightLeak.enabled; EffectsSub.GRAIN -> fx.grain.enabled; EffectsSub.VIGNETTE -> fx.vignette.enabled
        EffectsSub.SELECTIVE -> fx.selectiveColour != null
    }
    OptionTabs(EffectsSub.entries.map { it to it.label }, sub, vm::selectEffectsSub, dotted = ::on, tagPrefix = "effects-tab")
    // The approved notice sits between the tabs and the body.
    if ((sub == EffectsSub.GRAIN || sub == EffectsSub.VIGNETTE) && on(sub) && vm.presetHasOwn(sub, ui)) {
        Notice(LightlyIcons.Info, AnnotatedString("The applied preset already includes its own ${if (sub == EffectsSub.GRAIN) "grain" else "vignette"}. This one is added to it, not replaced."))
    }
    // Selective Colour has no On switch: a kept colour applies it (reference: docs/ui/proposals/selective-colour at 330cf5b; status in its README).
    if (sub != EffectsSub.SELECTIVE) OnOffRow(on(sub), name = sub.label) { vm.toggleEffect(sub) }
    when (sub) {
        EffectsSub.LEAK -> {
            ChipRow {
                EditOptions.LEAK_STYLES.forEach { (style, label) ->
                    val selected = fx.lightLeak.style == style
                    OptChip(selected, label, { vm.setLeakStyle(style) }, tag = "leak-${style.name.lowercase()}") {
                        Text(label, style = lightlyTextStyle(color = if (selected) lightlyColors.sel else lightlyColors.ink2), maxLines = 1)
                    }
                }
            }
            EffectsSlider(vm, ui, "Intensity", "leakIntensity", fx.lightLeak.intensity, 0.0, 100.0)
            EffectsSlider(vm, ui, "Rotation", "leakRotation", fx.lightLeak.rotation, -180.0, 180.0)
            PanelNote("Drag on the photo to move the leak.")
        }
        EffectsSub.GRAIN -> {
            ChipRow {
                EditOptions.GRAIN_STYLES.forEach { (style, label) ->
                    val selected = fx.grain.style == style
                    OptChip(selected, label, { vm.setGrainStyle(style) }, tag = "grain-${style.name.lowercase()}") {
                        Text(label, style = lightlyTextStyle(color = if (selected) lightlyColors.sel else lightlyColors.ink2), maxLines = 1)
                    }
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
@Composable
private fun SelectiveColourBody(vm: EditorViewModel, ui: EditorUiState, selective: com.lightlylabs.lightly.session.SelectiveColourTool?) {
    if (selective == null) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 14.dp).semantics(mergeDescendants = true) {}.testTag("effects-selective-hint"),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        ) {
            LightlyIcon(LightlyIcons.Picker, size = 20.dp, tint = lightlyColors.ink2)
            androidx.compose.foundation.layout.Spacer(Modifier.size(10.dp))
            Text("Tap a colour in the photo to keep it.", style = lightlyTextStyle(15.sp, color = lightlyColors.ink2))
        }
        return
    }
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(start = 8.dp, top = 6.dp, end = 8.dp),
        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
    ) {
        val removable = selective.colours.size > 1
        selective.colours.forEachIndexed { index, kept -> KeptColourDot(kept, removable, index) { vm.removeSelectiveColour(index) } }
        AddColourButton(adding = ui.effects.addingColour, enabled = selective.colours.size < EditorViewModel.MAX_KEPT_COLOURS, onClick = vm::toggleAddingColour)
        QuietSmallButton("Clear", vm::clearSelectiveColour, Modifier.testTag("effects-selective-clear"))
    }
    if (ui.effects.addingColour) PanelNote("Tap another colour in the photo.")
    EffectsSlider(vm, ui, "Range", "selectiveRange", selective.range, 0.0, 100.0)
    EffectsSlider(vm, ui, "Strength", "selectiveStrength", selective.strength, 0.0, 100.0)
}

@Composable
private fun KeptColourDot(kept: com.lightlylabs.lightly.session.KeptColourRecipe, removable: Boolean, index: Int, onRemove: () -> Unit) {
    val colour = remember(kept) { displayColour(kept.oklab) }
    val target = Modifier.size(48.dp)
    val modifier = if (removable) target.clickable(onClickLabel = "Remove colour ${index + 1}", role = Role.Button, onClick = onRemove)
        .semantics { contentDescription = "Remove colour ${index + 1}" }.testTag("effects-selective-remove-$index")
        else target.semantics { contentDescription = "Kept colour" }.testTag("effects-selective-colour-$index")
    androidx.compose.foundation.layout.Box(modifier, contentAlignment = androidx.compose.ui.Alignment.Center) {
        androidx.compose.foundation.layout.Box(Modifier.size(28.dp).clip(CircleShape).background(colour).border(1.dp, lightlyColors.hair, CircleShape))
        if (removable) {
            androidx.compose.foundation.layout.Box(
                Modifier.align(androidx.compose.ui.Alignment.Center).offset(x = 12.dp, y = (-12).dp).size(16.dp).clip(CircleShape).background(lightlyColors.ink),
                contentAlignment = androidx.compose.ui.Alignment.Center,
            ) { LightlyIcon(LightlyIcons.Close, size = 10.dp, tint = lightlyColors.bg) }
        }
    }
}

@Composable
private fun AddColourButton(adding: Boolean, enabled: Boolean, onClick: () -> Unit) {
    val tint = if (adding) lightlyColors.sel else lightlyColors.ink2
    androidx.compose.foundation.layout.Box(
        Modifier.size(48.dp).clickable(enabled = enabled, onClickLabel = "Add another colour", role = Role.Button, onClick = onClick)
            .semantics { contentDescription = "Add another colour"; selected = adding }.testTag("effects-selective-add"),
        contentAlignment = androidx.compose.ui.Alignment.Center,
    ) {
        val stroke = androidx.compose.ui.graphics.drawscope.Stroke(width = 2f, pathEffect = if (adding) null else androidx.compose.ui.graphics.PathEffect.dashPathEffect(floatArrayOf(6f, 6f)))
        androidx.compose.foundation.Canvas(Modifier.size(28.dp)) { drawCircle(tint, radius = size.minDimension / 2 - 1f, style = stroke) }
        LightlyIcon(LightlyIcons.Plus, size = 15.dp, tint = tint)
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
    SliderRow(label, drag ?: committed, min, max, onDrag = { vm.onEffectsSlider(field, it) }, onRelease = { vm.onEffectsSliderRelease(field, it) }, tag = "effects-slider-$field")
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
