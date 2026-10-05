package com.lightlylabs.lightly.editor

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.layout
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.session.NormalisedRect
import com.lightlylabs.lightly.shell.LightlyIcons
import com.lightlylabs.lightly.shell.lightlyColors
import com.lightlylabs.lightly.shell.lightlyTextStyle
import com.lightlylabs.lightly.shell.testTagResource
import com.lightlylabs.lightly.vision.DetectedFace
import kotlin.math.max

/** Stable tags for tests and captures. */
object PortraitTags {
    fun face(index: Int) = "portrait-face-${index + 1}"
    fun ring(index: Int) = "portrait-ring-${index + 1}"
    fun slider(field: String) = "portrait-slider-$field"
}

/**
 * Prototype `portraitPanel`: "No face can be edited" when no face is usable; otherwise the face strip
 * (only with more than one face), the five tabs and the tab's sliders and note, all copy verbatim.
 */
@Composable
fun PortraitPanel(vm: EditorViewModel, ui: EditorUiState, roomy: Boolean, wrapped: Boolean) = Column(Modifier.fillMaxWidth()) {
    if (roomy) PanelTitle("Portrait")
    val faces = vm.usableFaces
    val tool = ui.session?.current?.tools?.portrait ?: return@Column
    if (faces.isEmpty()) {
        Notice(LightlyIcons.Info, boldLead("No face can be edited in this photo.", " Faces are too small, turned away or too dark. Portrait controls need a clear face."))
        return@Column
    }
    val selected = ui.portrait.selectedFace.coerceIn(0, faces.size - 1)
    if (faces.size > 1) {
        ChipRow {
            faces.forEachIndexed { index, face ->
                val count = PortraitEdits.changeCount(PortraitEdits.editFor(tool, face))
                val label = if (count > 0) "Face ${index + 1} · $count" else "Face ${index + 1}"
                OptChip(index == selected, label, { vm.selectPortraitFace(index) }, PortraitTags.face(index)) {
                    Text(label, style = lightlyTextStyle(15.sp, color = if (index == selected) lightlyColors.sel else lightlyColors.ink2), maxLines = 1)
                }
            }
            // `<span class="note">` inside the chip row: the note's own padding (6 18) applies to the span.
            Text("Each face keeps its own settings.", style = lightlyTextStyle(13.sp, color = lightlyColors.ink3), maxLines = 1,
                modifier = Modifier.padding(horizontal = 18.dp, vertical = 6.dp))
        }
    }
    val tabs = PortraitTab.entries.map { it to it.label }
    if (wrapped) WrappedPortraitTabs(tabs, ui.portrait.tab, vm::selectPortraitTab) else OptionTabs(tabs, ui.portrait.tab, vm::selectPortraitTab, tagPrefix = "portrait-tab")
    val edit = PortraitEdits.editFor(tool, faces[selected])
    for (slider in PortraitOptions.sliders(ui.portrait.tab)) {
        val value = vm.portraitDragValue(slider.field) ?: PortraitEdits.value(edit, slider.field)
        SliderRow(slider.label, value, 0.0, 100.0, { vm.onPortraitSlider(slider.field, it) }, { vm.onPortraitSliderRelease(slider.field, it) }, PortraitTags.slider(slider.field))
    }
    PortraitOptions.note(ui.portrait.tab)?.let { PanelNote(it) }
}

/** `.wrapped .tabs` (the wide tablet layout): the tabs wrap onto more rows (row-gap 0), with no fade. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WrappedPortraitTabs(items: List<Pair<PortraitTab, String>>, selected: PortraitTab, onSelect: (PortraitTab) -> Unit) {
    val colors = lightlyColors
    FlowRow(Modifier.fillMaxWidth().padding(horizontal = 18.dp), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
        items.forEach { (value, label) ->
            val on = value == selected
            Box(
                Modifier.heightIn(min = 44.dp).widthIn(min = 44.dp).clickable(role = Role.Tab) { onSelect(value) }
                    .semantics { this.selected = on }.testTagResource("portrait-tab-${label.lowercase().replace(' ', '-')}"),
                contentAlignment = Alignment.Center,
            ) {
                Text(label, style = lightlyTextStyle(15.sp, if (on) FontWeight.SemiBold else FontWeight.Normal, if (on) colors.ink else colors.ink2), maxLines = 1)
            }
        }
    }
}

/**
 * Portrait's marks on the photo (prototype `marksFor`): a `.faceRing` on each usable face, the chosen
 * one solid and the others dashed at 75 %, each a button that chooses its face, with a "Face N" tag
 * below it when there are several. With no usable face but people present, dashed rings mark them.
 */
@Composable
fun PortraitMarks(vm: EditorViewModel, ui: EditorUiState) {
    if (ui.tool != EditorTool.PORTRAIT || ui.showsOriginal) return
    val people = ui.people ?: return
    val usable = people.usableFaces
    val toFrame: (NormalisedRect) -> FrameRect = { r -> frameRect(vm, ui, r) }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        if (usable.isNotEmpty()) {
            val selected = ui.portrait.selectedFace.coerceIn(0, usable.size - 1)
            usable.forEachIndexed { index, face ->
                FaceRing(toFrame(face.ring), maxWidth.value, maxHeight.value, dim = index != selected, tag = if (usable.size > 1) "Face ${index + 1}" else null,
                    description = "Face ${index + 1}", testTag = PortraitTags.ring(index)) { vm.selectPortraitFace(index) }
            }
        } else {
            unusableMarks(people).forEach { rect ->
                FaceRing(toFrame(rect), maxWidth.value, maxHeight.value, dim = true, tag = null, description = null, testTag = null, onClick = null)
            }
        }
    }
}

/**
 * Prototype `marksFor` with no usable face: dim rings on the people's faces. The faces that cannot be edited are
 * those marks; pose detections are used only when no face was found (someone seen from behind), so a false pose
 * detection elsewhere in the photo (the lamp in the bar photo, 2026-10-05) gets no ring. Same rule as iOS
 * `PeopleAnalysis.unusableMarks`.
 */
internal fun unusableMarks(people: com.lightlylabs.lightly.vision.PeopleAnalysis): List<NormalisedRect> =
    if (people.usableFaces.isNotEmpty()) emptyList() else people.faces.map(DetectedFace::box).ifEmpty { people.people }

/** A rect on the displayed frame, normalised, that may extend past it (rings are drawn, never stored). */
data class FrameRect(val x: Double, val y: Double, val width: Double, val height: Double)

/** A source-coordinate rect on the displayed frame (through Edit's geometry), as its bounding box. */
private fun frameRect(vm: EditorViewModel, ui: EditorUiState, r: NormalisedRect): FrameRect {
    val geometry = vm.displayGeometry(ui) ?: return FrameRect(r.x, r.y, r.width, r.height)
    val corners = listOf(r.x to r.y, r.x + r.width to r.y, r.x to r.y + r.height, r.x + r.width to r.y + r.height).map { (x, y) -> geometry.frameFromSource(x, y) }
    val x0 = corners.minOf { it.first }
    val y0 = corners.minOf { it.second }
    return FrameRect(x0, y0, corners.maxOf { it.first } - x0, corners.maxOf { it.second } - y0)
}

@Composable
private fun FaceRing(r: FrameRect, boxWidthDp: Float, boxHeightDp: Float, dim: Boolean, tag: String?, description: String?, testTag: String?, onClick: (() -> Unit)?) {
    val opacity = if (dim) 0.75f else 1f
    val left = (r.x * boxWidthDp).toFloat()
    val top = (r.y * boxHeightDp).toFloat()
    val width = max(1f, (r.width * boxWidthDp).toFloat())
    val height = max(1f, (r.height * boxHeightDp).toFloat())
    Box(
        Modifier
            .offset(left.dp, top.dp)
            .size(width.dp, height.dp)
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .then(if (description != null) Modifier.semantics { contentDescription = description; selected = !dim } else Modifier)
            .then(if (testTag != null) Modifier.testTagResource(testTag) else Modifier)
            .drawBehind {
                // `box-shadow: 0 0 0 1px rgba(0,0,0,.2)`: a 1 dp dark ring just outside the border box.
                val px = 1.dp.toPx()
                // `.dim { opacity:.75 }` on the whole ring and its tag. Applied to each colour, not as a layer:
                // a layer's alpha is drawn through an offscreen buffer the size of the ring, which clipped the tag.
                drawOval(Color(0x33000000).copy(alpha = 0.2f * opacity), topLeft = androidx.compose.ui.geometry.Offset(-px / 2, -px / 2),
                    size = androidx.compose.ui.geometry.Size(size.width + px, size.height + px), style = Stroke(px))
                // `.faceRing { border:1.5px solid rgba(255,255,255,.95) }`, floored to 1 px as Chrome renders it;
                // `.dim` is dashed (Chrome's 3/2 dp dash pattern, as the signature sheets).
                drawOval(Color.White.copy(alpha = 0.95f * opacity), topLeft = androidx.compose.ui.geometry.Offset(px / 2, px / 2),
                    size = androidx.compose.ui.geometry.Size(size.width - px, size.height - px),
                    style = Stroke(px, pathEffect = if (dim) PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 2.dp.toPx())) else null))
            },
    ) {
        if (tag != null) {
            // `.tag`: centred under the ring, 6 px below it; 12 px white on rgba(0,0,0,.55), padding 2 8, radius 8.
            Box(
                Modifier
                    .align(Alignment.BottomCenter)
                    .wrapContentSize(unbounded = true)
                    .layout { measurable, constraints ->
                        val placeable = measurable.measure(constraints.copy(minWidth = 0, minHeight = 0))
                        layout(placeable.width, placeable.height) { placeable.place(0, placeable.height + 6.dp.roundToPx()) }
                    }
                    .background(Color.Black.copy(alpha = 0.55f * opacity), RoundedCornerShape(8.dp))
                    .padding(horizontal = 8.dp, vertical = 2.dp),
            ) {
                Text(tag, style = lightlyTextStyle(com.lightlylabs.lightly.shell.fixedTextSize(12f), color = Color.White.copy(alpha = opacity)), maxLines = 1)
            }
        }
    }
}
