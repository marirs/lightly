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
import androidx.compose.ui.Alignment
import com.lightlylabs.lightly.session.BorderType

object BorderOptions {
    // Owner, 2026-10-12: Paper is no longer offered (it did not look real); an edit saved with it still renders and
    // still opens on its controls below.
    val TABS = listOf(BorderType.NONE to "None", BorderType.SOLID to "Solid", BorderType.FRAME to "Photo Frame", BorderType.POLAROID to "Polaroid")
    val SOLID = listOf("#FFFFFF", "#F4F1EC", "#111111", "#3C4A55", "#C9A27E")
    val FRAME = listOf("#111111", "#5A4636", "#C9C2B8", "#FFFFFF")
    val MAT = listOf("#F4F1EC", "#FFFFFF", "#1F2328")
    val POLAROID = listOf("#FFFFFF", "#F4F1EC", "#111111")
}

/** Lightly 2 `borderPanel`, a 6 dp column: the tabs, the reset row (with a border), the type's controls; every colour is the strip. */
@Composable
fun BorderPanel(vm: EditorViewModel, ui: EditorUiState, roomy: Boolean) = Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
    val border = ui.session?.current?.tools?.border ?: return@Column
    val tab = vm.borderTab(ui)
    OptionTabs(BorderOptions.TABS, tab, vm::chooseBorder, tagPrefix = "border-tab")
    if (tab != BorderType.NONE) ResetRow(vm, "border", "Border")
    when (tab) {
        BorderType.NONE -> Unit
        BorderType.SOLID -> {
            ColourControl("Border colour", border.colour, ui.original, "border-colour", vm::setBorderColour, previewPhoto = ui.preview, preview = { vm.previewColour("border-colour", it) }, cancel = vm::cancelPhotoGesturePreview)
            BorderSlider(vm, ui, "Width", "width", border.width, 1.0, 15.0)
        }
        BorderType.FRAME -> {
            ColourControl("Frame colour", border.colour, ui.original, "border-colour", vm::setBorderColour, previewPhoto = ui.preview, preview = { vm.previewColour("border-colour", it) }, cancel = vm::cancelPhotoGesturePreview)
            BorderSlider(vm, ui, "Frame width", "frameWidth", border.width, 1.0, 10.0)
            ColourControl("Mat colour", border.mat, ui.original, "border-mat", vm::setBorderMat, previewPhoto = ui.preview, preview = { vm.previewColour("border-mat", it) }, cancel = vm::cancelPhotoGesturePreview)
            BorderSlider(vm, ui, "Spacing", "spacing", border.spacing, 0.0, 12.0)
        }
        // Paper: the finishes (92×64 dp chip-filled tiles, 14 dp corners, a 64×40 dp sample; selected with a 2 dp accent
        // ring; 12.5 sp label, bold ink when selected), 12 dp apart; then the paper colour, Width and Texture.
        BorderType.PAPER -> {
            ChipRow(spacing = 12.dp) {
                listOf("clean", "deckled", "torn").forEach { finish ->
                    val on = border.paperFinish == finish
                    Column(Modifier.clickable { vm.setPaperFinish(finish) }.testTagResource("border-paper-$finish").padding(3.dp),
                        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        Box(Modifier.size(width = 92.dp, height = 64.dp).background(lightlyColors.chip, RoundedCornerShape(14.dp))
                            .then(if (on) Modifier.border(2.dp, lightlyColors.sel, RoundedCornerShape(14.dp)) else Modifier), contentAlignment = Alignment.Center) {
                            Canvas(Modifier.size(width = 64.dp, height = 40.dp)) {
                                val fill = Color(0xFFECE8DF)
                                if (finish == "clean") drawRoundRect(fill, cornerRadius = androidx.compose.ui.geometry.CornerRadius(2.dp.toPx()))
                                else {
                                    val pts = if (finish == "deckled") PAPER_DECKLED else PAPER_TORN
                                    val path = Path()
                                    pts.forEachIndexed { i, (px, py) -> val x = size.width * px / 100f; val y = size.height * py / 100f; if (i == 0) path.moveTo(x, y) else path.lineTo(x, y) }
                                    path.close(); drawPath(path, fill)
                                }
                            }
                        }
                        Text(finish.replaceFirstChar { it.uppercase() }, style = l2TextStyle(12.5.sp, if (on) androidx.compose.ui.text.font.FontWeight.Bold else androidx.compose.ui.text.font.FontWeight.Medium, if (on) lightlyColors.ink else lightlyColors.ink2))
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

/** The mockup's `paperEdge` outlines (percent of the sample). */
private val PAPER_DECKLED = listOf(0f to 3f, 6f to 0f, 14f to 2f, 24f to 0f, 35f to 3f, 47f to 0f, 58f to 2f, 70f to 0f, 82f to 3f, 92f to 0f, 100f to 2f, 98f to 14f, 100f to 30f, 97f to 47f, 100f to 63f, 98f to 80f, 100f to 97f, 90f to 100f, 78f to 97f, 66f to 100f, 52f to 98f, 40f to 100f, 27f to 97f, 15f to 100f, 4f to 98f, 0f to 100f, 2f to 82f, 0f to 64f, 3f to 46f, 0f to 30f, 2f to 14f)
private val PAPER_TORN = listOf(0f to 0f, 18f to 4f, 30f to 0f, 52f to 5f, 68f to 1f, 86f to 6f, 100f to 0f, 96f to 22f, 100f to 44f, 95f to 70f, 100f to 100f, 76f to 95f, 58f to 100f, 36f to 94f, 18f to 100f, 0f to 96f, 4f to 74f, 0f to 50f, 5f to 26f)

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
