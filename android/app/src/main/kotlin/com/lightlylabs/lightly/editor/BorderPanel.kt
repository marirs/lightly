package com.lightlylabs.lightly.editor

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.shell.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.unit.dp
import com.lightlylabs.lightly.session.BorderType

object BorderOptions {
    val TABS = listOf(BorderType.NONE to "None", BorderType.SOLID to "Solid", BorderType.FRAME to "Photo Frame", BorderType.POLAROID to "Polaroid", BorderType.PAPER to "Paper")
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
    ResetRow(vm, "border", "Border")
    when (tab) {
        BorderType.NONE -> PanelNote("No border. Your preferred border in Preferences is ${vm.preferredBorderName}; it is never added automatically.")
        BorderType.SOLID -> {
            ColourControl("Border colour", border.colour, ui.original, "border-colour", vm::setBorderColour, previewPhoto = ui.preview, preview = { vm.previewColour("border-colour", it) }, cancel = vm::cancelPhotoGesturePreview)
            BorderSlider(vm, ui, "Width", "width", border.width, 1.0, 15.0)
        }
        BorderType.FRAME -> {
            PanelNote("Frame", bottom = 0.dp)
            ColourControl("Frame colour", border.colour, ui.original, "border-colour", vm::setBorderColour, previewPhoto = ui.preview, preview = { vm.previewColour("border-colour", it) }, cancel = vm::cancelPhotoGesturePreview)
            BorderSlider(vm, ui, "Frame width", "frameWidth", border.width, 1.0, 10.0)
            PanelNote("Mat", bottom = 0.dp)
            ColourControl("Mat colour", border.mat, ui.original, "border-mat", vm::setBorderMat, previewPhoto = ui.preview, preview = { vm.previewColour("border-mat", it) }, cancel = vm::cancelPhotoGesturePreview)
            BorderSlider(vm, ui, "Spacing", "spacing", border.spacing, 0.0, 12.0)
        }
        BorderType.PAPER -> {
            ChipRow {
                listOf("clean", "deckled", "torn").forEach { finish ->
                    Column(Modifier.width(92.dp).border(if(border.paperFinish == finish) 2.dp else 0.dp, if(border.paperFinish == finish) lightlyColors.sel else Color.Transparent, RoundedCornerShape(9.dp)).clickable { vm.setPaperFinish(finish) }.padding(5.dp)) {
                        Canvas(Modifier.fillMaxWidth().height(56.dp).background(lightlyColors.bg2, RoundedCornerShape(8.dp))) {
                            val amplitude = when(finish) { "clean" -> 0f; "deckled" -> 1.dp.toPx(); else -> 3.dp.toPx() }
                            val inset = 4.dp.toPx(); val path = Path(); path.moveTo(inset,inset)
                            var x = inset
                            while(x < size.width-inset) { path.lineTo(x, inset+amplitude*com.lightlylabs.lightly.develop.PaperBorder.noise(x.toDouble()*0.8,0.0).toFloat()); x++ }
                            path.lineTo(size.width-inset,size.height-inset)
                            while(x >= inset) { path.lineTo(x,size.height-inset-amplitude*com.lightlylabs.lightly.develop.PaperBorder.noise(x.toDouble()*0.8,17.0).toFloat()); x-- }
                            path.close(); drawPath(path,Color(0xFFE8E0D1))
                        }
                        Spacer(Modifier.height(8.dp)); Text(finish.replaceFirstChar { it.uppercase() },style=lightlyTextStyle(13.sp,color=lightlyColors.ink))
                    }
                }
            }
            ColourControl("Paper colour", border.colour, ui.original, "paper-colour", vm::setBorderColour, previewPhoto = ui.preview, preview = { vm.previewColour("paper-colour", it) }, cancel = vm::cancelPhotoGesturePreview)
            BorderSlider(vm, ui, "Width", "width", border.width, 1.0, 15.0)
            BorderSlider(vm, ui, "Texture", "texture", border.texture, 0.0, 100.0)
        }
        BorderType.POLAROID -> {
            ColourControl("Border colour", border.colour, ui.original, "border-colour", vm::setBorderColour, previewPhoto = ui.preview, preview = { vm.previewColour("border-colour", it) }, cancel = vm::cancelPhotoGesturePreview)
            PanelNote("A wider bottom margin, as on an instant print.")

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
