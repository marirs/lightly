package com.lightlylabs.lightly.editor

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.semantics.Role
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
            PanelNote("Drag the corners to crop. Pinch to zoom.")
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
    fun on(s: EffectsSub) = when (s) { EffectsSub.LEAK -> fx.lightLeak.enabled; EffectsSub.GRAIN -> fx.grain.enabled; EffectsSub.VIGNETTE -> fx.vignette.enabled }
    OptionTabs(EffectsSub.entries.map { it to it.label }, sub, vm::selectEffectsSub, dotted = ::on, tagPrefix = "effects-tab")
    // The approved notice sits between the tabs and the body.
    if (sub != EffectsSub.LEAK && on(sub) && vm.presetHasOwn(sub, ui)) {
        Notice(LightlyIcons.Info, AnnotatedString("The applied preset already includes its own ${if (sub == EffectsSub.GRAIN) "grain" else "vignette"}. This one is added to it, not replaced."))
    }
    OnOffRow(on(sub)) { vm.toggleEffect(sub) }
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
    }
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
private fun OnOffRow(on: Boolean, onToggle: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .toggleable(value = on, role = Role.Switch, onValueChange = { onToggle() })
            .testTagResource("effects-on-off")
            .padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(if (on) "On" else "Off", style = lightlyTextStyle(15.sp, color = lightlyColors.ink), modifier = Modifier.weight(1f))
        com.lightlylabs.lightly.shell.ToggleKnob(on)
    }
}
