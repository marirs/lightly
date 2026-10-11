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
import kotlin.math.roundToInt
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.draw.clipToBounds
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
    /** The text under a gesture, drawn over the photo until its commit is rendered. */
    const val LIVE = "text-live"
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
 * The stage's bounds in window pixels (the photo stage clips there). The Text marks keep the ✕ and the corner handle
 * inside it and take touches over all of it, so a text near the photo's edge keeps both handles visible and draggable.
 */
internal val LocalStageWindowBounds = androidx.compose.runtime.staticCompositionLocalOf<androidx.compose.ui.geometry.Rect?> { null }

/**
 * The Text tool's marks on the photo (mockup `tx-selected`): the selected layer has a 1.5 dp dashed white outline 2 dp
 * outside its box, a 22 dp white circle with ✕ at the top-left (deletes the layer) and a 22 dp white circle at the
 * bottom-right (drag to resize and turn about the centre). Dragging inside a text moves it (centre kept in the frame);
 * two fingers on the selected text resize and turn it; a tap on a text selects it, a tap on empty photo deselects. Every
 * finished gesture is one undo step. Outside the Text tool texts are only pixels of the preview: nothing here is drawn.
 *
 * While a finger moves a text, the photo is rendered once without it and the text is drawn here with stage 11's own code
 * at the finger's exact size, every frame, until the preview containing the committed result is on screen (owner report
 * 2026-10-11: the handle resize stuttered while each move event waited for a full re-render).
 */
@Composable
fun TextMarks(vm: EditorViewModel, ui: EditorUiState, claim: TextGestureClaim) {
    if (ui.tool != EditorTool.TEXT || ui.showsOriginal) return
    val layers = ui.session?.current?.tools?.text?.layers ?: return
    // The text under a gesture as it moves: drawn here, with the outline and handles following it before the commit.
    var live by remember { mutableStateOf<TextDraft?>(null) }
    val selectedId = ui.text.selectedId
    val currentLayers by rememberUpdatedState(layers)
    val currentSelectedId by rememberUpdatedState(selectedId)
    val stageWindow by rememberUpdatedState(LocalStageWindowBounds.current)
    // The stage in this box's (unzoomed) pixels, refreshed whenever the photo moves or zooms under the marks.
    var stageInBox by remember { mutableStateOf<androidx.compose.ui.geometry.Rect?>(null) }
    BoxWithConstraints(Modifier.fillMaxSize().testTagResource(TextTags.MARKS).onGloballyPositioned { coordinates ->
        stageInBox = stageWindow?.let { TextStageArea.local(coordinates, it) }
    }) {
        val boxWidth = constraints.maxWidth.toDouble()
        val boxHeight = constraints.maxHeight.toDouble()
        val density = LocalDensity.current
        val handleRadius = with(density) { (HANDLE_SIZE / 2).toPx().toDouble() }
        // The photo box itself until the stage has been measured.
        val stage = stageInBox ?: androidx.compose.ui.geometry.Rect(0f, 0f, boxWidth.toFloat(), boxHeight.toFloat())
        val currentStage by rememberUpdatedState(stage)
        val drawn: TextDraft? = live ?: ui.text.settlingLayer?.takeIf { it.id == ui.text.liveLayerId }?.let(TextDraft::of)
        val shownSelected: TextDraft? = drawn?.takeIf { it.layer.id == selectedId } ?: layers.firstOrNull { it.id == selectedId }?.let(TextDraft::of)
        // The text being moved, over the photo where the preview leaves it out (clipped to the photo, as the render is).
        if (drawn != null) Canvas(Modifier.fillMaxSize().clipToBounds().testTagResource(TextTags.LIVE)) {
            drawIntoCanvas { canvas -> vm.textStage.draw(canvas.nativeCanvas, drawn.layer, size.width.toDouble(), size.height.toDouble(), drawn.exactSize) }
        }
        // Touches over the whole stage (not only the photo): a handle kept inside the stage may lie beside the photo.
        Box(
            Modifier
                .wrapContentSize(Alignment.TopStart, unbounded = true)
                .offset { androidx.compose.ui.unit.IntOffset(stage.left.roundToInt(), stage.top.roundToInt()) }
                .size(with(density) { stage.width.toDp() }, with(density) { stage.height.toDp() })
                .pointerInput(boxWidth, boxHeight) {
                    val handleReach = (HANDLE_SIZE / 2 + HANDLE_SLOP).toPx().toDouble()
                    awaitEachGesture {
                        val origin = currentStage.topLeft
                        val geometry = TextBoxGeometry(vm.textStage, boxWidth, boxHeight, BOX_PADDING_X.toPx().toDouble(), BOX_PADDING_Y.toPx().toDouble(),
                            keepHandle = { point -> TextStageArea.keepInside(point, currentStage, handleRadius) })
                        val down = awaitFirstDown(requireUnconsumed = false)
                        // Positions in the photo box's pixels from here on.
                        val downAt = down.position + origin
                        when (val hit = geometry.hitTest(currentLayers, currentSelectedId, downAt.x.toDouble(), downAt.y.toDouble(), handleReach)) {
                            TextHit.Empty -> {
                                // Not consumed: the stage still double-taps to zoom (or, beside the photo, cycles the theme).
                                val onPhoto = downAt.x in 0f..boxWidth.toFloat() && downAt.y in 0f..boxHeight.toFloat()
                                if (awaitTap(down, viewConfiguration.touchSlop) && onPhoto) vm.selectTextLayer(null)
                            }
                            is TextHit.Delete -> {
                                down.consume()
                                if (awaitTap(down, viewConfiguration.touchSlop)) vm.deleteTextLayer(hit.layer.id)
                            }
                            is TextHit.Handle -> {
                                claim.claim()
                                down.consume()
                                live = TextDraft.of(hit.layer)
                                vm.beginTextGesture(hit.layer.id)
                                val result = trackHandle(geometry, hit.layer, down, origin) { live = it }
                                claim.release()
                                vm.endTextGesture(result?.layer)
                                live = null
                            }
                            is TextHit.Body -> {
                                claim.claim()
                                down.consume()
                                if (hit.layer.id != currentSelectedId) vm.selectTextLayer(hit.layer.id)
                                live = TextDraft.of(hit.layer)
                                vm.beginTextGesture(hit.layer.id)
                                val result = trackBody(hit.layer, down, boxWidth, boxHeight, viewConfiguration.touchSlop) { live = it }
                                claim.release()
                                vm.endTextGesture(result?.layer)
                                live = null
                            }
                        }
                    }
                }
                .semantics { contentDescription = "Drag a text to move it. Drag its corner handle to resize or turn it." },
        )
        if (shownSelected != null) {
            val geometry = with(density) {
                TextBoxGeometry(vm.textStage, boxWidth, boxHeight, BOX_PADDING_X.toPx().toDouble(), BOX_PADDING_Y.toPx().toDouble(),
                    keepHandle = { point -> TextStageArea.keepInside(point, stage, handleRadius) })
            }
            SelectionOutline(geometry, shownSelected)
            val (deleteX, deleteY) = geometry.deleteHandle(shownSelected)
            val (handleX, handleY) = geometry.cornerHandle(shownSelected)
            val layerId = shownSelected.layer.id
            HandleCircle(deleteX, deleteY, shownSelected.layer.rotation, LightlyIcons.Close, "Delete text", TextTags.DELETE) { vm.deleteTextLayer(layerId) }
            HandleCircle(handleX, handleY, shownSelected.layer.rotation, LightlyIcons.Redo, "Resize or turn text", TextTags.HANDLE, onClick = null)
        }
    }
}

/** The stage rectangle in the photo box's pixels, and keeping a handle's centre inside it. */
internal object TextStageArea {
    /** [stageWindow] (window pixels) in [coordinates]' local pixels; the stage's zoom and pan are undone by the transform. */
    fun local(coordinates: androidx.compose.ui.layout.LayoutCoordinates, stageWindow: androidx.compose.ui.geometry.Rect): androidx.compose.ui.geometry.Rect {
        val topLeft = coordinates.windowToLocal(stageWindow.topLeft)
        val bottomRight = coordinates.windowToLocal(stageWindow.bottomRight)
        return androidx.compose.ui.geometry.Rect(minOf(topLeft.x, bottomRight.x), minOf(topLeft.y, bottomRight.y), maxOf(topLeft.x, bottomRight.x), maxOf(topLeft.y, bottomRight.y))
    }

    /**
     * The handle's centre moved just enough that the whole circle ([radius]) is inside [stage]. A handle on the photo or in
     * the stage's margin stays exactly on its corner; only a corner past the stage's edge is held at that edge.
     */
    fun keepInside(point: Pair<Double, Double>, stage: androidx.compose.ui.geometry.Rect, radius: Double): Pair<Double, Double> {
        fun keep(value: Double, low: Double, high: Double) = if (high < low) (low + high) / 2 else value.coerceIn(low, high)
        return keep(point.first, stage.left + radius, stage.right - radius) to keep(point.second, stage.top + radius, stage.bottom - radius)
    }
}

/** The dashed outline: 1.5 dp, rgba(255,255,255,.95), [OUTLINE_OFFSET] outside the box, turned with the text. */
@Composable
private fun SelectionOutline(geometry: TextBoxGeometry, draft: TextDraft) {
    Canvas(Modifier.fillMaxSize()) {
        val block = geometry.block(draft)
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

/**
 * Mockup `tx-selected` handle: a 22 dp white circle centred on ([x], [y]) px with a 12 dp #141513 icon and
 * `box-shadow: 0 1px 4px rgba(0,0,0,.4)` (a blurred shadow, 1 dp down: CSS blur 4 px is a Gaussian of σ 2 px), turned with
 * the text as the mockup's spans inside the rotated box are. Drawn above the photo, never clipped by it; the marks keep
 * the centre inside the stage.
 */
@Composable
private fun HandleCircle(x: Double, y: Double, rotation: Double, icon: androidx.compose.ui.graphics.vector.ImageVector, description: String, tag: String, onClick: (() -> Unit)?) {
    val density = LocalDensity.current
    val half = with(density) { (HANDLE_SIZE / 2).toPx() }
    Box(
        Modifier
            .offset { androidx.compose.ui.unit.IntOffset((x - half).roundToInt(), (y - half).roundToInt()) }
            .size(HANDLE_SIZE)
            .graphicsLayer { rotationZ = rotation.toFloat() }
            .drawBehind {
                val radius = size.minDimension / 2
                drawIntoCanvas { canvas ->
                    val sigma = 2.dp.toPx()
                    val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                        color = android.graphics.Color.WHITE
                        // Skia turns a shadow-layer radius r into σ = 0.57735 r + 0.5, so this is the CSS σ.
                        setShadowLayer(((sigma - 0.5f) / 0.57735f).coerceAtLeast(0.1f), 0f, 1.dp.toPx(), android.graphics.Color.argb(102, 0, 0, 0))
                    }
                    canvas.nativeCanvas.drawCircle(center.x, center.y, radius, paint)
                }
            }
            // The photo's gesture layer handles touches; this is the accessible action (TalkBack) and test hook.
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .semantics { contentDescription = description }
            .testTagResource(tag),
        contentAlignment = Alignment.Center,
    ) { LightlyIcon(icon, size = 12.dp, tint = Color(0xFF141513)) }
}

/** Stage 11's layout in the photo box's pixels, with the mockup's box padding, for drawing and hit testing. */
internal class TextBoxGeometry(
    private val stage: TextStage, private val boxWidth: Double, private val boxHeight: Double, val padX: Double, val padY: Double,
    /** Where a handle is drawn and touched for a corner at the given point (held inside the stage). */
    private val keepHandle: (Pair<Double, Double>) -> Pair<Double, Double> = { it },
) {
    fun block(layer: TextLayer): TextStage.Block = stage.block(layer, boxWidth, boxHeight)

    fun block(draft: TextDraft): TextStage.Block = stage.block(draft.layer, boxWidth, boxHeight, draft.exactSize)

    /** The padded box's top-left corner (mockup: the ✕ is centred on it, `left: -11px; top: -11px`). */
    fun topLeft(draft: TextDraft): Pair<Double, Double> = block(draft).let { TextStage.fromBlock(it, -(it.width / 2 + padX), -(it.height / 2 + padY)) }

    /** The padded box's bottom-right corner (mockup: the handle is centred on it, `right: -11px; bottom: -11px`). */
    fun bottomRight(draft: TextDraft): Pair<Double, Double> = block(draft).let { TextStage.fromBlock(it, it.width / 2 + padX, it.height / 2 + padY) }

    fun topLeft(layer: TextLayer) = topLeft(TextDraft.of(layer))

    fun bottomRight(layer: TextLayer) = bottomRight(TextDraft.of(layer))

    /** The ✕ as drawn: on its corner, held inside the stage. */
    fun deleteHandle(draft: TextDraft) = keepHandle(topLeft(draft))

    /** The resize handle as drawn: on its corner, held inside the stage. */
    fun cornerHandle(draft: TextDraft) = keepHandle(bottomRight(draft))

    /** The handles of the selected layer first, then its box, then the topmost other box; else empty photo. */
    fun hitTest(layers: List<TextLayer>, selectedId: String?, x: Double, y: Double, handleReach: Double): TextHit {
        val selected = layers.firstOrNull { it.id == selectedId }
        if (selected != null) {
            val (dx, dy) = deleteHandle(TextDraft.of(selected))
            if (hypot(x - dx, y - dy) <= handleReach) return TextHit.Delete(selected)
            val (hx, hy) = cornerHandle(TextDraft.of(selected))
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

/**
 * The corner handle: the finger's distance from the centre scales the size, its angle about the centre turns the text.
 * Touch positions are in the gesture layer's pixels; [origin] is that layer's top-left in the photo box.
 */
private suspend fun AwaitPointerEventScope.trackHandle(geometry: TextBoxGeometry, start: TextLayer, down: PointerInputChange, origin: Offset, onDraft: (TextDraft) -> Unit): TextDraft? {
    val block = geometry.block(start)
    val downAt = down.position + origin
    val startDistance = hypot(downAt.x - block.centreX, downAt.y - block.centreY).coerceAtLeast(1.0)
    val startAngle = Math.toDegrees(atan2(downAt.y - block.centreY, downAt.x - block.centreX))
    var current: TextDraft? = null
    while (true) {
        val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
        if (!change.pressed) break
        val at = change.position + origin
        val distance = hypot(at.x - block.centreX, at.y - block.centreY)
        val angle = Math.toDegrees(atan2(at.y - block.centreY, at.x - block.centreX))
        // y points down, so a growing atan2 angle is a clockwise turn, as the recipe's rotation.
        val next = TextEdits.drafted(start, 0.0, 0.0, distance / startDistance, angle - startAngle)
        change.consume()
        if (next != current) { current = next; onDraft(next) }
    }
    return current?.takeIf { it.layer != start }
}

/**
 * Inside a text: one finger moves it (fractions of the photo, centre kept in the frame); a second finger resizes and turns
 * it about its centre (pinch and twist). The whole gesture is one change.
 */
private suspend fun AwaitPointerEventScope.trackBody(start: TextLayer, down: PointerInputChange, boxWidth: Double, boxHeight: Double, slop: Float, onDraft: (TextDraft) -> Unit): TextDraft? {
    var current = TextDraft.of(start)
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
        val next = TextEdits.drafted(start, moved.x / boxWidth, moved.y / boxHeight, scale, turn)
        if (next != current) { current = next; onDraft(next) }
    }
    return current.takeIf { it.layer != start }
}
