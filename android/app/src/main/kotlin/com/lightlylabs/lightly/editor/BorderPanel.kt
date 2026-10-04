package com.lightlylabs.lightly.editor

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.lightlylabs.lightly.session.BorderType
import com.lightlylabs.lightly.shell.ToggleKnob
import com.lightlylabs.lightly.shell.lightlyColors
import com.lightlylabs.lightly.shell.lightlyTextStyle
import com.lightlylabs.lightly.shell.testTagResource

object BorderOptions {
    val TABS = listOf(BorderType.NONE to "None", BorderType.SOLID to "Solid", BorderType.FRAME to "Photo Frame", BorderType.POLAROID to "Polaroid")
    val SOLID = listOf("#FFFFFF", "#F4F1EC", "#111111", "#3C4A55", "#C9A27E")
    val FRAME = listOf("#111111", "#5A4636", "#C9C2B8", "#FFFFFF")
    val MAT = listOf("#F4F1EC", "#FFFFFF", "#1F2328")
    val POLAROID = listOf("#FFFFFF", "#F4F1EC", "#111111")
}

/** Prototype `borderPanel`: None, Solid, Photo Frame, Polaroid with the approved swatches, sliders and copy verbatim. */
@Composable
fun BorderPanel(vm: EditorViewModel, ui: EditorUiState, roomy: Boolean) = Column(Modifier.fillMaxWidth()) {
    if (roomy) PanelTitle("Border")
    val border = ui.session?.current?.tools?.border ?: return@Column
    val tab = vm.borderTab(ui)
    OptionTabs(BorderOptions.TABS, tab, vm::chooseBorder, tagPrefix = "border-tab")
    when (tab) {
        BorderType.NONE -> PanelNote("No border. Your preferred border in Preferences is ${vm.preferredBorderName}; it is never added automatically.")
        BorderType.SOLID -> {
            Swatches(BorderOptions.SOLID, border.colour, vm::setBorderColour, "border-colour")
            BorderSlider(vm, ui, "Width", "width", border.width, 1.0, 15.0)
        }
        BorderType.FRAME -> {
            PanelNote("Frame", bottom = 0.dp)
            Swatches(BorderOptions.FRAME, border.colour, vm::setBorderColour, "border-colour")
            BorderSlider(vm, ui, "Frame width", "frameWidth", border.width, 1.0, 10.0)
            PanelNote("Mat", bottom = 0.dp)
            Swatches(BorderOptions.MAT, border.mat, vm::setBorderMat, "border-mat")
            BorderSlider(vm, ui, "Spacing", "spacing", border.spacing, 0.0, 12.0)
        }
        BorderType.POLAROID -> {
            Swatches(BorderOptions.POLAROID, border.colour, vm::setBorderColour, "border-colour")
            PanelNote("A wider bottom margin, as on an instant print.")
            // `<button class="listrow" style="border:0;width:100%">`: the label and the approved switch.
            val on = vm.signatureOnMargin(ui)
            Row(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = 52.dp)
                    .toggleable(value = on, role = Role.Switch, onValueChange = { vm.toggleSignatureOnMargin() })
                    .testTagResource("border-signature-on-margin")
                    .padding(horizontal = 18.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Signature on the margin", style = lightlyTextStyle(color = lightlyColors.ink), modifier = Modifier.weight(1f))
                ToggleKnob(on)
            }
        }
    }
}

/** `swatches(path, cur, list)`: a `.chiprow` of `.sw`, the recipe's colour marked (`cur === c`). */
@Composable
private fun Swatches(colours: List<String>, selected: String, onChoose: (String) -> Unit, tag: String) = ChipRow {
    colours.forEach { hex -> Swatch({ SolidColor(colourOf(hex)) }, selected == hex, "Colour", { onChoose(hex) }, tag = "$tag-$hex", colourName = SwatchNames.of(hex)) }
}

@Composable
private fun BorderSlider(vm: EditorViewModel, ui: EditorUiState, label: String, field: String, committed: Double, min: Double, max: Double) {
    val drag = ui.border.sliderDrag?.takeIf { it.first == field }?.second
    SliderRow(label, drag ?: committed, min, max, onDrag = { vm.onBorderSlider(field, it) }, onRelease = { vm.onBorderSliderRelease(field, it) }, tag = "border-slider-$field")
}
