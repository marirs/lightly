package com.lightlylabs.lightly.editor

import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.remember
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.Animatable
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.draw.drawBehind
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.border
import androidx.compose.ui.layout.layout
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.session.NormalisedRect
import com.lightlylabs.lightly.shell.LightlyIcon
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
 * (only with more than one face), the six tabs and the tab's sliders and note, all copy verbatim.
 */
@Composable
fun PortraitPanel(vm: EditorViewModel, ui: EditorUiState, roomy: Boolean, wrapped: Boolean) = Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(4.dp)) {
    // Lightly 2 `portraitPanel`, a 4 dp column: the faces (several faces only), the tabs, the reset row, sliders, notes.
    val faces = vm.usableFaces
    val tool = ui.session?.current?.tools?.portrait ?: return@Column
    if (faces.isEmpty()) {
        Notice(LightlyIcons.Info, boldLead("No face can be edited in this photo.", " Faces are too small, turned away or too dark. Portrait controls need a clear face."))
        return@Column
    }
    val selected = ui.portrait.selectedFace.coerceIn(0, faces.size - 1)
    if (faces.size > 1) {
        // The faces. Owner amendments (2026-10-14): no "Each face keeps its own settings." note; each chip is a
        // person icon instead of "Face N", the chosen one highlighted; a face with changes shows the edited dot (as the
        // tabs do) instead of the "· 4" count. TalkBack still reads "Face N" and "Edited".
        Row(Modifier.padding(bottom = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                faces.forEachIndexed { index, face ->
                    val edited = PortraitEdits.changeCount(PortraitEdits.editFor(tool, face)) > 0
                    val description = if (edited) "Face ${index + 1}, Edited" else "Face ${index + 1}"
                    OptChip(index == selected, description, { vm.selectPortraitFace(index) }, PortraitTags.face(index)) {
                        LightlyIcon(LightlyIcons.Portrait, size = 16.dp)
                        if (edited) Box(Modifier.size(5.dp).background(lightlyColors.edited, CircleShape))
                    }
                }
            }
        }
    }
    val tabs = PortraitTab.entries.map { it to it.label }
    val edit0 = PortraitEdits.editFor(tool, faces[selected])
    // An orange dot on the tabs holding changes for this face (Sunglasses: while the face wears a pair).
    OptionTabs(tabs, ui.portrait.tab, vm::selectPortraitTab, tagPrefix = "portrait-tab",
        dotted = { tab ->
            if (tab == PortraitTab.SUNGLASSES) edit0.sunglasses?.pair != null
            else PortraitOptions.sliders(tab).any { slider -> PortraitEdits.value(edit0, slider.field) != PortraitEdits.value(PortraitEdits.neutral(faces[selected].box), slider.field) }
        })
    ResetRow(vm, "portrait", ui.portrait.tab.label, ui.portrait.tab.name.lowercase())
    if (ui.portrait.tab == PortraitTab.SUNGLASSES) {
        SunglassesBody(vm, ui, PortraitEdits.editFor(tool, faces[selected]))
        return@Column
    }
    val edit = PortraitEdits.editFor(tool, faces[selected])
    for (slider in PortraitOptions.sliders(ui.portrait.tab)) {
        val value = vm.portraitDragValue(slider.field) ?: PortraitEdits.value(edit, slider.field)
        SliderRow(slider.label, value, slider.min, slider.max, { vm.onPortraitSlider(slider.field, it) }, { vm.onPortraitSliderRelease(slider.field, it) }, PortraitTags.slider(slider.field))
    }
    PortraitOptions.note(ui.portrait.tab, hasMouth = faces[selected].mouthCorners != null)?.let { PanelNote(it) }
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
 * Portrait's face targets on the photo. Owner amendments (2026-10-14): nothing stays drawn on a face — no ring, no
 * "Face N" tag, no dim marks ("you can do it invisibly"). With several faces, choosing one (its chip or a tap on it)
 * flashes its outline briefly so the person sees which face is chosen. Each usable face is an invisible, tappable area
 * that chooses it, with its TalkBack label.
 */
@Composable
fun PortraitMarks(vm: EditorViewModel, ui: EditorUiState) {
    if (ui.tool != EditorTool.PORTRAIT || ui.showsOriginal) return
    val usable = ui.people?.usableFaces ?: return
    if (usable.isEmpty()) return
    val toFrame: (NormalisedRect) -> FrameRect = { r -> frameRect(vm, ui, r) }
    val selected = ui.portrait.selectedFace.coerceIn(0, usable.size - 1)
    val flash = remember { Animatable(0f) }
    LaunchedEffect(ui.portrait.faceFlash) {
        if (ui.portrait.faceFlash == 0) return@LaunchedEffect
        flash.snapTo(1f)
        kotlinx.coroutines.delay(FACE_FLASH_HOLD_MS)
        flash.animateTo(0f, tween(FACE_FLASH_FADE_MS))
    }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        usable.forEachIndexed { index, face ->
            FaceTarget(toFrame(face.ring), maxWidth.value, maxHeight.value, isSelected = index == selected,
                description = "Face ${index + 1}", testTag = PortraitTags.ring(index)) { vm.selectPortraitFace(index) }
        }
        if (usable.size > 1 && flash.value > 0f) FaceFlash(toFrame(usable[selected].ring), maxWidth.value, maxHeight.value, flash.value)
    }
}

/** Fully visible for this long, then fades out (iOS FaceRingsMark.flashHold / flashFade). */
private const val FACE_FLASH_HOLD_MS = 600L
private const val FACE_FLASH_FADE_MS = 500

/** The approved `.faceRing` look at [alpha]: a white ellipse with a 1 dp dark hairline just outside it. */
@Composable
private fun FaceFlash(r: FrameRect, boxWidthDp: Float, boxHeightDp: Float, alpha: Float) {
    Box(
        Modifier
            .offset((r.x * boxWidthDp).toFloat().dp, (r.y * boxHeightDp).toFloat().dp)
            .size(max(1f, (r.width * boxWidthDp).toFloat()).dp, max(1f, (r.height * boxHeightDp).toFloat()).dp)
            .drawBehind {
                val px = 1.dp.toPx()
                drawOval(Color.Black.copy(alpha = 0.2f * alpha), topLeft = Offset(-px / 2, -px / 2), size = Size(size.width + px, size.height + px), style = Stroke(px))
                val ring = 1.5.dp.toPx()
                drawOval(Color.White.copy(alpha = 0.95f * alpha), topLeft = Offset(ring / 2, ring / 2), size = Size(size.width - ring, size.height - ring), style = Stroke(ring))
            },
    )
}

/**
 * Prototype `marksFor` with no usable face: dim rings on the people's faces. The faces that cannot be edited are
 * those marks; pose detections are used only when no face was found (someone seen from behind), so a false pose
 * detection elsewhere in the photo (the lamp in the bar photo, 2026-10-05) gets no ring. Same rule as iOS
 * `PeopleAnalysis.unusableMarks`.
 */
internal fun unusableMarks(people: com.lightlylabs.lightly.vision.PeopleAnalysis): List<NormalisedRect> = when {
    people.usableFaces.isNotEmpty() -> emptyList()
    // Heads from the person matte when it found people (2026-10-06): on the bar photo the detectors' boxes lay on the
    // bottles and the disco ball, while the matte holds the two people the prototype rings (PersonHeads).
    people.heads.isNotEmpty() -> people.heads
    else -> people.faces.map(DetectedFace::box).ifEmpty { people.people }
}

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
private fun FaceTarget(r: FrameRect, boxWidthDp: Float, boxHeightDp: Float, isSelected: Boolean, description: String, testTag: String, onClick: () -> Unit) {
    val left = (r.x * boxWidthDp).toFloat()
    val top = (r.y * boxHeightDp).toFloat()
    Box(
        Modifier
            .offset(left.dp, top.dp)
            .size(max(1f, (r.width * boxWidthDp).toFloat()).dp, max(1f, (r.height * boxHeightDp).toFloat()).dp)
            .clip(androidx.compose.foundation.shape.CircleShape)
            .clickable(role = Role.Button, indication = null, interactionSource = null, onClick = onClick)
            .semantics { contentDescription = description; selected = isSelected }
            .testTagResource(testTag),
    )
}

/**
 * Portrait › Sunglasses (owner-approved design `docs/ui/proposals/portrait-sunglasses-v2.html`, 2026-10-13), as iOS
 * `SunglassesControls`: 1 · Add a pair (pairs, Lenses, Darkness, Size); 2 · Glasses found (the notice, the same controls
 * without Size, as the design shows); 3 · side faces as 1; 4 · eyes not visible (the notice, the pairs dimmed on None).
 */
@Composable
private fun SunglassesBody(vm: EditorViewModel, ui: EditorUiState, edit: com.lightlylabs.lightly.session.FaceEdit) {
    val glasses = edit.sunglasses ?: com.lightlylabs.lightly.session.Sunglasses.NONE
    val faceIndex = ui.portrait.selectedFace.coerceIn(0, (vm.usableFaces.size - 1).coerceAtLeast(0))
    when (val state = vm.sunglassesState(ui)) {
        SunglassesState.EYES_NOT_VISIBLE -> {
            Notice(LightlyIcons.Info, boldLead("The eyes need to be visible.", " The eyes are covered or the face is too small. Other faces in the photo can still have sunglasses."))
            SunglassesPairs(vm, selected = null, enabled = false, faceIndex = faceIndex)
        }
        SunglassesState.GLASSES_FOUND -> {
            Notice(LightlyIcons.Info, boldLead("Glasses found.", " Choose a pair to replace them; their own glasses are taken out first."))
            SunglassesPairs(vm, selected = glasses.pair, enabled = true, faceIndex = faceIndex)
            SunglassesLenses(vm, glasses, showsSize = false)
        }
        else -> {
            SunglassesPairs(vm, selected = glasses.pair, enabled = state == SunglassesState.READY, faceIndex = faceIndex)
            SunglassesLenses(vm, glasses, showsSize = true)
        }
    }
}

/** The pairs row (design `styles`): None, then the pack's pairs, scrolled so the chosen one shows. */
@Composable
private fun SunglassesPairs(vm: EditorViewModel, selected: String?, enabled: Boolean, faceIndex: Int) {
    val pairs = vm.sunglassesPairs
    val scroll = androidx.compose.foundation.rememberScrollState()
    val index = selected?.let { id -> pairs.indexOfFirst { it.id == id }.takeIf { it >= 0 }?.plus(1) } ?: 0
    val density = androidx.compose.ui.platform.LocalDensity.current
    androidx.compose.runtime.LaunchedEffect(index) {
        // The tile before the chosen one at the leading edge (ChipRow's `scrolled()`): 66 dp tiles, 8 dp apart.
        scroll.animateScrollTo(with(density) { (maxOf(0, index - 1) * 74).dp.roundToPx() })
    }
    Box(Modifier.then(if (enabled) Modifier else Modifier.alpha(0.4f))) {
        ChipRow(spacing = 8.dp, rowScroll = scroll) {
            PairTile("None", null, selected == null, enabled, "sunglasses-pair-none") { vm.setSunglassesPair(null, faceIndex) }
            pairs.forEach { pair ->
                PairTile(pair.name, vm.sunglassesThumbnail(pair), selected == pair.id, enabled, "sunglasses-pair-${pair.name.lowercase()}") {
                    vm.setSunglassesPair(pair.id, faceIndex)
                }
            }
        }
    }
}

/** One pair (design `.st`): 66 × 54 dp, 14 dp corners, the picture above the 10.5 sp name; 1 dp hairline or 2 dp selection border. */
@Composable
private fun PairTile(title: String, thumbnail: android.graphics.Bitmap?, selected: Boolean, enabled: Boolean, tag: String, onClick: () -> Unit) {
    val colors = lightlyColors
    val shape = RoundedCornerShape(14.dp)
    Column(
        Modifier.size(66.dp, 54.dp).clip(shape)
            .border(if (selected) 2.dp else 1.dp, if (selected) colors.sel else colors.hair, shape)
            .clickable(enabled = enabled, role = Role.RadioButton, onClick = onClick)
            .semantics { contentDescription = title; this.selected = selected }
            .testTagResource(tag),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterVertically),
    ) {
        // Dark mode only (owner choice 2026-10-19; iOS PairTile): a light backing so black frames stay visible on dark tiles.
        val backing = if (thumbnail != null && colors.isDark)
            Modifier.background(Color(0xFFF3F3F0).copy(alpha = 0.9f), RoundedCornerShape(7.dp)) else Modifier
        Box(Modifier.size(56.dp, 26.dp).then(backing).padding(2.dp), contentAlignment = Alignment.Center) {
            if (thumbnail != null) {
                androidx.compose.foundation.Image(thumbnail.asImageBitmap(), contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
            } else {
                Box(Modifier.size(32.dp, 1.5.dp).background(colors.ink3))
            }
        }
        Text(title, style = lightlyTextStyle(10.5.sp, FontWeight.SemiBold, if (selected) colors.ink else colors.ink2), maxLines = 1)
    }
}

/** Lenses (design `chips` with their dots), Darkness, and Size unless [showsSize] is false. */
@Composable
private fun SunglassesLenses(vm: EditorViewModel, glasses: com.lightlylabs.lightly.session.Sunglasses, showsSize: Boolean) {
    val colors = lightlyColors
    Text("Lenses", style = lightlyTextStyle(11.5.sp, FontWeight.SemiBold, colors.ink2), modifier = Modifier.padding(top = 6.dp))
    ChipRow(spacing = 6.dp) {
        LENSES.forEach { (lens, title, brush) ->
            OptChip(glasses.lens == lens, title, { vm.setSunglassesLens(lens) }, "sunglasses-lens-${title.lowercase()}") {
                Box(Modifier.size(12.dp).clip(androidx.compose.foundation.shape.CircleShape).background(brush))
                Text(title, maxLines = 1)
            }
        }
    }
    for (slider in listOfNotNull(PortraitOptions.SUNGLASSES_DARKNESS, PortraitOptions.SUNGLASSES_SIZE.takeIf { showsSize })) {
        val value = vm.portraitDragValue(slider.field) ?: if (slider.field == "sunglasses.darkness") glasses.darkness else glasses.size
        SliderRow(slider.label, value, slider.min, slider.max, { vm.onPortraitSlider(slider.field, it) }, { vm.onPortraitSliderRelease(slider.field, it) }, PortraitTags.slider(slider.field))
    }
}

/** The approved lens chips and their dots: Dark, Brown, Green, Gradient, Mirror. */
private val LENSES: List<Triple<com.lightlylabs.lightly.session.SunglassesLens, String, Brush>> = listOf(
    Triple(com.lightlylabs.lightly.session.SunglassesLens.DARK, "Dark", SolidColor(Color(0xFF2A2E33))),
    Triple(com.lightlylabs.lightly.session.SunglassesLens.BROWN, "Brown", SolidColor(Color(0xFF6B4A2F))),
    Triple(com.lightlylabs.lightly.session.SunglassesLens.GREEN, "Green", SolidColor(Color(0xFF3F5440))),
    Triple(com.lightlylabs.lightly.session.SunglassesLens.GRADIENT, "Gradient", Brush.verticalGradient(listOf(Color(0xFF2A2E33), Color(0xFFC9C4BB)))),
    Triple(com.lightlylabs.lightly.session.SunglassesLens.MIRROR, "Mirror", Brush.linearGradient(listOf(Color(0xFF7FB7FF), Color(0xFF2B5EA8)))),
)
