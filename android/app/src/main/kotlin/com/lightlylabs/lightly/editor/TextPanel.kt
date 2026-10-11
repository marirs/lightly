package com.lightlylabs.lightly.editor

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateRotation
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.AwaitPointerEventScope
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.session.TextFont
import com.lightlylabs.lightly.session.TextLayer
import com.lightlylabs.lightly.shell.LightlyIcon
import com.lightlylabs.lightly.shell.LightlyIcons
import com.lightlylabs.lightly.shell.l2TextStyle
import com.lightlylabs.lightly.shell.lightlyColors
import com.lightlylabs.lightly.shell.testTagResource
import kotlin.math.atan2
import kotlin.math.hypot

/** Stable tags for tests and captures. */
object TextTags {
    const val ADD_TEXT = "text-add"
    const val ADD_CHIP = "text-add-chip"
    const val INPUT = "text-input"
    const val SHEET = "text-sheet"
    const val DELETE = "text-delete"
    const val HANDLE = "text-handle"
    const val MARKS = "text-marks"
    fun layer(index: Int) = "text-layer-${index + 1}"
    fun font(font: TextFont) = "text-font-${font.family.lowercase().replace(' ', '-')}"
    fun slider(field: String) = "text-slider-$field"
}

/**
 * Lightly 2 `textPanel` (owner amendment 2026-10-11). Without layers, a 10 dp column: the dashed "Add text" button and the
 * note. With layers, an 8 dp column: the layer chips and "+ Add", the input box (the selected layer's text in its font;
 * it opens the text sheet), the fonts, Size, the colour strip and Opacity. The text sheet adds or edits a layer.
 */
@Composable
fun TextPanel(vm: EditorViewModel, ui: EditorUiState) {
    val tool = ui.session?.current?.tools?.text ?: return
    if (tool.layers.isEmpty()) {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            AddTextButton(vm::openAddText)
            PanelNote(TextOptions.EMPTY_NOTE)
        }
    } else {
        val selected = vm.selectedTextLayer(ui)
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            ChipRow(spacing = 8.dp) {
                tool.layers.forEachIndexed { index, layer ->
                    LayerChip(layer.text, on = layer.id == selected?.id, tag = TextTags.layer(index)) { vm.selectTextLayer(layer.id) }
                }
                LayerChip(TextOptions.ADD, on = false, tag = TextTags.ADD_CHIP, leadingPlus = true, onClick = vm::openAddText)
            }
            // v3 differs (unspecified state, reported): with layers but none selected (a tap on empty photo deselects),
            // only the chips show; the controls below act on a selected layer.
            if (selected != null) SelectedLayerControls(vm, ui, selected)
        }
    }
    TextSheetHost(vm, ui)
}

@Composable
private fun SelectedLayerControls(vm: EditorViewModel, ui: EditorUiState, layer: TextLayer) {
    InputBox(layer.text, vm.composeTextFont(layer.font), vm::openEditText)
    ChipRow { TextOptions.FONTS.forEach { font -> FontTile(font, vm.composeTextFont(font), on = font == layer.font) { vm.chooseTextFont(font) } } }
    TextSlider(ui, "Size", "size", layer.size.toDouble(), TextLayer.MIN_SIZE.toDouble(), TextLayer.MAX_SIZE.toDouble(), vm)
    ColourControl("Colour", layer.colour, ui.original, "text-colour", vm::setTextColour, previewPhoto = ui.preview,
        preview = { vm.previewColour("text-colour", it) }, cancel = vm::cancelPhotoGesturePreview)
    TextSlider(ui, "Opacity", "opacity", layer.opacity, 0.0, 100.0, vm)
}

@Composable
private fun TextSlider(ui: EditorUiState, label: String, field: String, committed: Double, min: Double, max: Double, vm: EditorViewModel) {
    val drag = ui.text.sliderDrag?.takeIf { it.first == field }?.second
    SliderRow(label, drag ?: committed, min, max, onDrag = { vm.onTextSlider(field, it) }, onRelease = { vm.onTextSliderRelease(field, it) }, tag = TextTags.slider(field))
}

/** The text sheet: "Text" with Cancel and Done; it adds a layer or edits the selected one (up to 120 characters). */
@Composable
private fun TextSheetHost(vm: EditorViewModel, ui: EditorUiState) {
    val sheet = ui.text.sheet ?: return
    val initial = (sheet as? TextSheet.Editing)?.let { editing -> ui.session?.current?.tools?.text?.layers?.firstOrNull { it.id == editing.layerId }?.text }.orEmpty()
    TextEntrySheet(TextOptions.SHEET_TITLE, initial, maxLength = TextLayer.MAX_TEXT_LENGTH, tagPrefix = TextTags.SHEET,
        onDone = vm::finishTextSheet, onCancel = vm::closeTextSheet)
}

/** "Add text": 56 dp, 18 dp corners, a 1.5 dp dashed hairline, chip fill, the plus (18 dp) and 15 sp bold ink, 8 dp apart. */
@Composable
private fun AddTextButton(onClick: () -> Unit) {
    val colors = lightlyColors
    val shape = RoundedCornerShape(18.dp)
    Row(
        Modifier.fillMaxWidth().height(56.dp).clip(shape).background(colors.chip, shape)
            .drawBehind {
                drawRoundRect(colors.hair, cornerRadius = CornerRadius(18.dp.toPx()),
                    style = Stroke(1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx()))))
            }
            .clickable(role = Role.Button, onClick = onClick)
            .testTagResource(TextTags.ADD_TEXT),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        LightlyIcon(LightlyIcons.Plus, size = 18.dp, tint = colors.ink)
        Text(TextOptions.ADD_TEXT, style = l2TextStyle(15.sp, FontWeight.Bold, colors.ink), maxLines = 1)
    }
}

/**
 * A layer chip: 36 dp, 12 dp padding, 18 dp corners, 13 sp semibold, the layer's text on one line (truncated). Selected:
 * the lime pill (`--pill`, `--pill-ink`, no border); otherwise transparent, ink2, a hairline. "+ Add" is the unselected
 * style with a 14 dp plus, 4 dp before its label.
 */
@Composable
private fun LayerChip(label: String, on: Boolean, tag: String, leadingPlus: Boolean = false, onClick: () -> Unit) {
    val colors = lightlyColors
    val shape = RoundedCornerShape(18.dp)
    val ink = if (on) colors.pillInk else colors.ink2
    Row(
        Modifier.height(36.dp).widthIn(max = 200.dp).clip(shape)
            .then(if (on) Modifier.background(colors.pill, shape) else Modifier.border(1.dp, colors.hair, shape))
            .clickable(role = if (leadingPlus) Role.Button else Role.RadioButton, onClick = onClick)
            .semantics { if (!leadingPlus) selected = on; contentDescription = if (leadingPlus) "Add text" else label }
            .testTagResource(tag)
            .padding(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leadingPlus) LightlyIcon(LightlyIcons.Plus, size = 14.dp, tint = ink)
        // One line: a multi-line text shows its lines joined by spaces.
        Text(label.replace('\n', ' '), style = l2TextStyle(13.sp, FontWeight.SemiBold, ink), maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** The input box: at least 50 dp, 16 dp corners, chip fill, hairline, 14 dp sides, the text at 17 sp in its font, the pencil (18 dp). */
@Composable
private fun InputBox(text: String, font: androidx.compose.ui.text.font.FontFamily, onClick: () -> Unit) {
    val colors = lightlyColors
    val shape = RoundedCornerShape(16.dp)
    Row(
        Modifier.fillMaxWidth().heightIn(min = 50.dp).clip(shape).background(colors.chip).border(1.dp, colors.hair, shape)
            .clickable(role = Role.Button, onClick = onClick).semantics { contentDescription = "Edit text" }
            .testTagResource(TextTags.INPUT).padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text.replace('\n', ' '), modifier = Modifier.weight(1f), style = TextStyle(fontFamily = font, fontSize = 17.sp, color = colors.ink),
            maxLines = 1, overflow = TextOverflow.Ellipsis)
        LightlyIcon(LightlyIcons.Pencil, size = 18.dp, tint = colors.ink)
    }
}

/**
 * A font tile: at least 96×58 dp, 16 dp corners, "Aa" at 20 sp in the font over the font's name (10.5 sp ink3, one line),
 * 2 dp apart; selected with a 2 dp accent border, otherwise a hairline.
 */
@Composable
private fun FontTile(font: TextFont, family: androidx.compose.ui.text.font.FontFamily, on: Boolean, onClick: () -> Unit) {
    val colors = lightlyColors
    val shape = RoundedCornerShape(16.dp)
    Column(
        Modifier.widthIn(min = 96.dp).heightIn(min = 58.dp).clip(shape)
            .border(if (on) 2.dp else 1.dp, if (on) colors.sel else colors.hair, shape)
            .clickable(role = Role.RadioButton, onClick = onClick)
            .semantics { contentDescription = font.family; selected = on }
            .testTagResource(TextTags.font(font))
            .padding(horizontal = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
    ) {
        Text("Aa", style = TextStyle(fontFamily = family, fontSize = 20.sp, color = colors.ink), maxLines = 1)
        Text(font.family, style = TextStyle(fontSize = com.lightlylabs.lightly.shell.fixedTextSize(10.5f), color = colors.ink3), maxLines = 1, softWrap = false)
    }
}

// --- on the photo ---------------------------------------------------------------------------------

/**
 * Whether a gesture that began on a text box owns the pointers. The stage's inspection pinch reads it from the Initial
 * pass, so the second finger of a pinch on the selected text resizes and turns the text instead of zooming the photo.
 */
class TextGestureClaim {
    @Volatile private var claimed = false
    fun ownsPointers(): Boolean = claimed
    fun claim() { claimed = true }
    fun release() { claimed = false }
}

/** What a finger landed on, in the photo box's pixels. */
internal sealed interface TextHit {
    data class Delete(val layer: TextLayer) : TextHit
    data class Handle(val layer: TextLayer) : TextHit
    data class Body(val layer: TextLayer) : TextHit
    data object Empty : TextHit
}

/** The mockup's text box: `padding: 4px 10px` around the text block; the outline 2 dp outside that (`outline-offset`). */
private val BOX_PADDING_X = 10.dp
private val BOX_PADDING_Y = 4.dp
private val OUTLINE_OFFSET = 2.dp
private val HANDLE_SIZE = 22.dp

/** Extra reach around the 22 dp handles, so they are comfortable touch targets. */
private val HANDLE_SLOP = 10.dp

/**
 * The Text tool's marks on the photo (mockup `tx-selected`): the selected layer has a 1.5 dp dashed white outline 2 dp
 * outside its box, a 22 dp white circle with ✕ at the top-left (deletes the layer) and a 22 dp white circle at the
 * bottom-right (drag to resize and turn about the centre). Dragging inside a text moves it (centre kept in the frame);
 * two fingers on the selected text resize and turn it; a tap on a text selects it, a tap on empty photo deselects. Every
 * finished gesture is one undo step. Outside the Text tool texts are only pixels of the preview: nothing here is drawn.
 */
@Composable
fun TextMarks(vm: EditorViewModel, ui: EditorUiState, claim: TextGestureClaim) {
    if (ui.tool != EditorTool.TEXT || ui.showsOriginal) return
    val layers = ui.session?.current?.tools?.text?.layers ?: return
    // The layer under a gesture as it moves (the outline and handles follow the finger before the commit).
    var live by remember { mutableStateOf<TextLayer?>(null) }
    val selectedId = ui.text.selectedId
    val currentLayers by rememberUpdatedState(layers)
    val currentSelectedId by rememberUpdatedState(selectedId)
    BoxWithConstraints(Modifier.fillMaxSize().testTagResource(TextTags.MARKS)) {
        val boxWidth = constraints.maxWidth.toDouble()
        val boxHeight = constraints.maxHeight.toDouble()
        val density = LocalDensity.current
        val shownSelected = (live?.takeIf { it.id == selectedId } ?: layers.firstOrNull { it.id == selectedId })
        Box(
            Modifier.fillMaxSize().pointerInput(boxWidth, boxHeight) {
                val geometry = TextBoxGeometry(vm.textStage, boxWidth, boxHeight, BOX_PADDING_X.toPx().toDouble(), BOX_PADDING_Y.toPx().toDouble())
                val handleReach = (HANDLE_SIZE / 2 + HANDLE_SLOP).toPx().toDouble()
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val hit = geometry.hitTest(currentLayers, currentSelectedId, down.position.x.toDouble(), down.position.y.toDouble(), handleReach)
                    when (hit) {
                        TextHit.Empty -> {
                            // Not consumed: the stage still double-taps to zoom. A plain tap deselects.
                            if (awaitTap(down, viewConfiguration.touchSlop)) vm.selectTextLayer(null)
                        }
                        is TextHit.Delete -> {
                            down.consume()
                            if (awaitTap(down, viewConfiguration.touchSlop)) vm.deleteTextLayer(hit.layer.id)
                        }
                        is TextHit.Handle -> {
                            claim.claim()
                            down.consume()
                            val result = trackHandle(geometry, hit.layer, down) { live = it; vm.previewTextLayer(it) }
                            claim.release()
                            live = null
                            if (result != null) vm.commitTextLayer(result)
                        }
                        is TextHit.Body -> {
                            claim.claim()
                            down.consume()
                            if (hit.layer.id != currentSelectedId) vm.selectTextLayer(hit.layer.id)
                            val result = trackBody(hit.layer, down, boxWidth, boxHeight, viewConfiguration.touchSlop) { live = it; vm.previewTextLayer(it) }
                            claim.release()
                            live = null
                            if (result != null) vm.commitTextLayer(result)
                        }
                    }
                }
            }.semantics { contentDescription = "Drag a text to move it. Drag its corner handle to resize or turn it." },
        )
        if (shownSelected != null) {
            val geometry = with(density) { TextBoxGeometry(vm.textStage, boxWidth, boxHeight, BOX_PADDING_X.toPx().toDouble(), BOX_PADDING_Y.toPx().toDouble()) }
            SelectionOutline(geometry, shownSelected)
            val (deleteX, deleteY) = geometry.topLeft(shownSelected)
            val (handleX, handleY) = geometry.bottomRight(shownSelected)
            HandleCircle(deleteX, deleteY, shownSelected.rotation, LightlyIcons.Close, "Delete text", TextTags.DELETE) { vm.deleteTextLayer(shownSelected.id) }
            HandleCircle(handleX, handleY, shownSelected.rotation, LightlyIcons.Redo, "Resize or turn text", TextTags.HANDLE, onClick = null)
        }
    }
}

/** The dashed outline: 1.5 dp, rgba(255,255,255,.95), [OUTLINE_OFFSET] outside the box, turned with the text. */
@Composable
private fun SelectionOutline(geometry: TextBoxGeometry, layer: TextLayer) {
    Canvas(Modifier.fillMaxSize()) {
        val block = geometry.block(layer)
        val offset = OUTLINE_OFFSET.toPx()
        val stroke = 1.5.dp.toPx()
        val halfWidth = (block.width / 2 + geometry.padX).toFloat() + offset + stroke / 2
        val halfHeight = (block.height / 2 + geometry.padY).toFloat() + offset + stroke / 2
        val centre = Offset(block.centreX.toFloat(), block.centreY.toFloat())
        rotate(block.rotation.toFloat(), pivot = centre) {
            drawRect(Color.White.copy(alpha = 0.95f), topLeft = centre - Offset(halfWidth, halfHeight), size = Size(halfWidth * 2, halfHeight * 2),
                style = Stroke(stroke, pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 2.dp.toPx()))))
        }
    }
}

/** A 22 dp white circle centred on ([x], [y]) px with a 12 dp #141513 icon, `box-shadow: 0 1px 4px rgba(0,0,0,.4)`. */
@Composable
private fun HandleCircle(x: Double, y: Double, rotation: Double, icon: androidx.compose.ui.graphics.vector.ImageVector, description: String, tag: String, onClick: (() -> Unit)?) {
    val density = LocalDensity.current
    val half = with(density) { (HANDLE_SIZE / 2).toPx() }
    Box(
        Modifier
            .offset(with(density) { (x - half).toFloat().toDp() }, with(density) { (y - half).toFloat().toDp() })
            .size(HANDLE_SIZE)
            .graphicsLayer { rotationZ = rotation.toFloat() }
            .drawBehind {
                drawCircle(Color.Black.copy(alpha = 0.2f), size.minDimension / 2 + 1.dp.toPx(), center + Offset(0f, 1.dp.toPx()))
                drawCircle(Color.White, size.minDimension / 2)
            }
            // The photo's gesture layer handles touches; this is the accessible action (TalkBack) and test hook.
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .semantics { contentDescription = description }
            .testTagResource(tag)
            .clip(CircleShape),
        contentAlignment = Alignment.Center,
    ) { LightlyIcon(icon, size = 12.dp, tint = Color(0xFF141513)) }
}

/** Stage 11's layout in the photo box's pixels, with the mockup's box padding, for drawing and hit testing. */
internal class TextBoxGeometry(private val stage: TextStage, private val boxWidth: Double, private val boxHeight: Double, val padX: Double, val padY: Double) {
    fun block(layer: TextLayer): TextStage.Block = stage.block(layer, boxWidth, boxHeight)

    fun topLeft(layer: TextLayer): Pair<Double, Double> = block(layer).let { TextStage.fromBlock(it, -(it.width / 2 + padX), -(it.height / 2 + padY)) }

    fun bottomRight(layer: TextLayer): Pair<Double, Double> = block(layer).let { TextStage.fromBlock(it, it.width / 2 + padX, it.height / 2 + padY) }

    /** The handles of the selected layer first, then its box, then the topmost other box; else empty photo. */
    fun hitTest(layers: List<TextLayer>, selectedId: String?, x: Double, y: Double, handleReach: Double): TextHit {
        val selected = layers.firstOrNull { it.id == selectedId }
        if (selected != null) {
            val (dx, dy) = topLeft(selected)
            if (hypot(x - dx, y - dy) <= handleReach) return TextHit.Delete(selected)
            val (hx, hy) = bottomRight(selected)
            if (hypot(x - hx, y - hy) <= handleReach) return TextHit.Handle(selected)
            if (TextStage.contains(block(selected), x, y, padX, padY)) return TextHit.Body(selected)
        }
        return layers.asReversed().firstOrNull { TextStage.contains(block(it), x, y, padX, padY) }?.let { TextHit.Body(it) } ?: TextHit.Empty
    }
}

/** Waits for the finger to lift; true when it was a tap (it never moved past the slop and was not cancelled). */
private suspend fun AwaitPointerEventScope.awaitTap(down: PointerInputChange, slop: Float): Boolean {
    while (true) {
        val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: return false
        if ((change.position - down.position).getDistance() > slop) return false
        if (!change.pressed) return true
    }
}

/** The corner handle: the finger's distance from the centre scales the size, its angle about the centre turns the text. */
private suspend fun AwaitPointerEventScope.trackHandle(geometry: TextBoxGeometry, start: TextLayer, down: PointerInputChange, preview: (TextLayer) -> Unit): TextLayer? {
    val block = geometry.block(start)
    val startDistance = hypot(down.position.x - block.centreX, down.position.y - block.centreY).coerceAtLeast(1.0)
    val startAngle = Math.toDegrees(atan2(down.position.y - block.centreY, down.position.x - block.centreX))
    var current: TextLayer? = null
    while (true) {
        val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
        if (!change.pressed) break
        val distance = hypot(change.position.x - block.centreX, change.position.y - block.centreY)
        val angle = Math.toDegrees(atan2(change.position.y - block.centreY, change.position.x - block.centreX))
        // y points down, so a growing atan2 angle is a clockwise turn, as the recipe's rotation.
        val next = TextEdits.scaledAndTurned(start, distance / startDistance, angle - startAngle)
        change.consume()
        if (next != current) { current = next; preview(next) }
    }
    return current?.takeIf { it != start }
}

/**
 * Inside a text: one finger moves it (fractions of the photo, centre kept in the frame); a second finger resizes and turns
 * it about its centre (pinch and twist). The whole gesture is one change.
 */
private suspend fun AwaitPointerEventScope.trackBody(start: TextLayer, down: PointerInputChange, boxWidth: Double, boxHeight: Double, slop: Float, preview: (TextLayer) -> Unit): TextLayer? {
    var current = start
    var scale = 1.0
    var turn = 0.0
    var moving = false
    var pinched = false
    var trackedId = down.id
    var dragAnchor = down.position
    var moved = Offset.Zero
    while (true) {
        val event = awaitPointerEvent()
        val pressed = event.changes.filter { it.pressed }
        if (pressed.isEmpty()) break
        if (pressed.size >= 2) {
            pinched = true
            scale *= event.calculateZoom()
            turn += event.calculateRotation()
        } else {
            val tracked = pressed.firstOrNull { it.id == trackedId }
            val finger = tracked ?: pressed.first()
            // After a pinch (or when the first finger lifted), the move continues from where the remaining finger is now.
            if (pinched || tracked == null) { trackedId = finger.id; dragAnchor = finger.position - moved; pinched = false }
            val total = finger.position - dragAnchor
            if (!moving && total.getDistance() > slop) moving = true
            if (moving) moved = total
        }
        event.changes.forEach { it.consume() }
        val next = TextEdits.scaledAndTurned(TextEdits.moved(start, moved.x / boxWidth, moved.y / boxHeight), scale, turn)
        if (next != current) { current = next; preview(next) }
    }
    return current.takeIf { it != start }
}
