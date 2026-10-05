package com.lightlylabs.lightly.editor

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlin.math.hypot
import kotlin.math.max

/**
 * Edit's and Effects' marks on the photo (prototype `marksFor`), drawn inside the photo box:
 * - Crop: `.cropframe` (inset 6 %, 1.5 px white border, the rest darkened rgba(0,0,0,.42), four 18 px
 *   corner handles with 3 px borders, the thirds grid); dragging a corner crops, pinching zooms.
 * - Straighten, Perspective: `.grid3` over the photo.
 * - Remove: each stroke as `.stroke` (rgba(235,60,60,.42), round ends); brushing removes; "Removing…"
 *   centred over the photo with Cancel.
 * - Light Leaks: dragging on the photo moves the leak.
 */
@Composable
fun EditMarks(vm: EditorViewModel, ui: EditorUiState) {
    if (ui.showsOriginal) return
    when (ui.tool) {
        EditorTool.EDIT -> when (ui.edit.sub) {
            EditSub.CROP -> CropFrame(vm)
            EditSub.STRAIGHTEN, EditSub.PERSPECTIVE -> Canvas(Modifier.fillMaxSize()) { thirdsGrid(Offset.Zero, size) }
            EditSub.REMOVE -> RemoveMarks(vm, ui)
            else -> Unit
        }
        EditorTool.EFFECTS -> when {
            ui.effects.sub == EffectsSub.LEAK -> LeakDrag(vm)
            vm.picksOnTap(ui) -> SelectiveColourTap(vm)
        }
        EditorTool.WATERMARK -> ui.session?.current?.tools?.let { tools ->
            // "Or drag the watermark on the photo": on the photo only (a watermark on the border is centred).
            if (tools.watermark.type != com.lightlylabs.lightly.session.WatermarkType.NONE && !WatermarkStage.isOnBorder(tools.watermark, tools.border.type)) WatermarkDrag(vm, WatermarkStage.anchor(tools.watermark))
        }
        else -> Unit
    }
}

private val GRID_LINE = Color(0x73FFFFFF) // rgba(255,255,255,.45)
private val CROP_SHADE = Color(0x6B000000) // rgba(0,0,0,.42)
private val STROKE_FILL = Color(0x6BEB3C3C) // rgba(235,60,60,.42)

/** `.grid3`: 1 px lines at the top of each third (0, ⅓, ⅔ of the box), both directions. */
private fun DrawScope.thirdsGrid(origin: Offset, box: Size) {
    val line = 1.dp.toPx()
    for (i in 0 until 3) {
        drawRect(GRID_LINE, Offset(origin.x, origin.y + box.height * i / 3f), Size(box.width, line))
        drawRect(GRID_LINE, Offset(origin.x + box.width * i / 3f, origin.y), Size(line, box.height))
    }
}

@Composable
private fun CropFrame(vm: EditorViewModel) {
    Canvas(
        Modifier
            .fillMaxSize()
            .pointerInput(Unit) { cropGestures(vm) }
            .semantics { contentDescription = "Drag the corners to crop. Pinch to zoom." },
    ) {
        val inset = Offset(size.width * 0.06f, size.height * 0.06f)
        val frame = Size(size.width * 0.88f, size.height * 0.88f)
        val border = 1.5.dp.toPx() // the CSS source value (floored widths, 0a5fe7d, are under review)
        // `box-shadow: 0 0 0 2000px`: everything outside the frame's border box, clipped by the photo.
        drawRect(CROP_SHADE, Offset.Zero, Size(size.width, inset.y))
        drawRect(CROP_SHADE, Offset(0f, inset.y + frame.height), Size(size.width, size.height - inset.y - frame.height))
        drawRect(CROP_SHADE, Offset(0f, inset.y), Size(inset.x, frame.height))
        drawRect(CROP_SHADE, Offset(inset.x + frame.width, inset.y), Size(size.width - inset.x - frame.width, frame.height))
        drawRect(Color.White, inset + Offset(border / 2, border / 2), Size(frame.width - border, frame.height - border), style = Stroke(border))
        // `.grid3` fills the frame's padding box (inside the border).
        thirdsGrid(inset + Offset(border, border), Size(frame.width - 2 * border, frame.height - 2 * border))
        // Handles: 18 px border-box squares at -3 px from the padding box, a 3 px border on the two outer sides.
        val handle = 18.dp.toPx()
        val thick = 3.dp.toPx()
        val left = inset.x + border - thick
        val top = inset.y + border - thick
        val right = inset.x + frame.width - border + thick - handle
        val bottom = inset.y + frame.height - border + thick - handle
        for ((x, y) in listOf(left to top, right to top, left to bottom, right to bottom)) {
            val atLeft = x == left
            val atTop = y == top
            drawRect(Color.White, Offset(x, if (atTop) y else y + handle - thick), Size(handle, thick))
            drawRect(Color.White, Offset(if (atLeft) x else x + handle - thick, y), Size(thick, handle))
        }
    }
}

/** One finger near a corner of the crop frame drags it; two fingers pinch. Each gesture is one step. */
private suspend fun PointerInputScope.cropGestures(vm: EditorViewModel) = awaitEachGesture {
    val down = awaitFirstDown()
    val w = size.width.toFloat()
    val h = size.height.toFloat()
    val corners = listOf(Offset(w * 0.06f, h * 0.06f), Offset(w * 0.94f, h * 0.06f), Offset(w * 0.06f, h * 0.94f), Offset(w * 0.94f, h * 0.94f))
    val corner = corners.indices.minBy { (corners[it] - down.position).getDistance() }.takeIf { (corners[it] - down.position).getDistance() <= 44.dp.toPx() }
    var last = down.position
    var startSpan = 0f
    var span = 0f
    while (true) {
        val event = awaitPointerEvent()
        val pressed = event.changes.filter { it.pressed }
        if (pressed.isEmpty()) break
        if (pressed.size >= 2) {
            val current = (pressed[0].position - pressed[1].position).getDistance()
            if (startSpan == 0f) startSpan = current
            span = current
        } else if (startSpan == 0f) {
            last = pressed[0].position
        }
        event.changes.forEach { it.consume() }
    }
    when {
        startSpan > 0f && span > 0f -> vm.pinchCrop((span / startSpan).toDouble())
        corner != null && last != down.position -> vm.dragCropCorner(corner, ((last.x - down.position.x) / w).toDouble(), ((last.y - down.position.y) / h).toDouble())
    }
}

@Composable
private fun RemoveMarks(vm: EditorViewModel, ui: EditorUiState) {
    val geometry = vm.displayGeometry(ui)
    val recipe = ui.session?.current
    val strokes = buildList {
        recipe?.tools?.edit?.remove?.strokes?.forEach { s -> add(s.points.map { it.x to it.y } to s.radius) }
        ui.edit.pendingStroke?.let { add(it.points to it.radius) }
    }
    Box(Modifier.fillMaxSize().pointerInput(ui.edit.removeOp) { if (ui.edit.removeOp != RemoveOp.REMOVING) brushGestures(vm) }.semantics { contentDescription = "Brush over anything you want removed" }) {
        if (geometry != null) Canvas(Modifier.fillMaxSize()) {
            // A source radius (fraction of the source long edge) in this box's pixels.
            val sourceLong = max(geometry.sourceWidth, geometry.sourceHeight).toFloat()
            val pxPerSource = size.width / geometry.frameWidth
            strokes.forEach { (points, radius) ->
                val frame = points.map { (x, y) -> geometry.frameFromSource(x, y).let { (fx, fy) -> Offset(fx.toFloat() * size.width, fy.toFloat() * size.height) } }
                val width = (2 * radius * sourceLong * pxPerSource).toFloat()
                if (frame.size == 1) {
                    drawCircle(STROKE_FILL, width / 2, frame[0])
                } else {
                    val path = Path().apply { moveTo(frame[0].x, frame[0].y); frame.drop(1).forEach { lineTo(it.x, it.y) } }
                    drawPath(path, STROKE_FILL, style = Stroke(width, cap = StrokeCap.Round, join = StrokeJoin.Round))
                }
            }
        }
        if (ui.edit.removeOp == RemoveOp.REMOVING) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            ProgressBox("Removing…", null, null, cancel = vm::cancelRemove)
        }
    }
}

/** A drag (or a tap: one dab) on the photo, in normalised frame coordinates. */
private suspend fun PointerInputScope.brushGestures(vm: EditorViewModel) = awaitEachGesture {
    val down = awaitFirstDown()
    val points = arrayListOf(down.position)
    while (true) {
        val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
        if (!change.pressed) break
        // Keep the stroke light: a new point every 4 px of travel.
        if (hypot(change.position.x - points.last().x, change.position.y - points.last().y) >= 4.dp.toPx()) points += change.position
        change.consume()
    }
    vm.removeStroke(points.map { (it.x / size.width).toDouble().coerceIn(0.0, 1.0) to (it.y / size.height).toDouble().coerceIn(0.0, 1.0) })
}

/** The watermark's anchor follows the finger from where it was (photo fractions); one step on release. */
@Composable
private fun WatermarkDrag(vm: EditorViewModel, start: Pair<Double, Double>) {
    Box(
        Modifier.fillMaxSize().pointerInput(start) {
            awaitEachGesture {
                val down = awaitFirstDown()
                var last = down.position
                var moved = false
                while (true) {
                    val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                    if (!change.pressed) break
                    last = change.position
                    moved = true
                    vm.dragWatermark(start, ((last.x - down.position.x) / size.width).toDouble(), ((last.y - down.position.y) / size.height).toDouble(), release = false)
                    change.consume()
                }
                if (moved) vm.dragWatermark(start, ((last.x - down.position.x) / size.width).toDouble(), ((last.y - down.position.y) / size.height).toDouble(), release = true)
            }
        }.semantics { contentDescription = "Drag the watermark on the photo" },
    )
}

/** Selective Colour: a tap keeps the colour under it (the first one, or after (+)). */
@Composable
private fun SelectiveColourTap(vm: EditorViewModel) {
    Box(
        Modifier.fillMaxSize().pointerInput(Unit) {
            detectTapGestures { offset ->
                vm.pickSelectiveColour((offset.x / size.width).toDouble().coerceIn(0.0, 1.0), (offset.y / size.height).toDouble().coerceIn(0.0, 1.0))
            }
        }.semantics { contentDescription = "Tap a colour in the photo to keep it" },
    )
}

@Composable
private fun LeakDrag(vm: EditorViewModel) {
    Box(
        Modifier.fillMaxSize().pointerInput(Unit) {
            awaitEachGesture {
                val down = awaitFirstDown()
                var position = down.position
                var moved = false
                while (true) {
                    val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                    if (!change.pressed) break
                    position = change.position
                    moved = true
                    vm.moveLeak((position.x / size.width).toDouble(), (position.y / size.height).toDouble(), release = false)
                    change.consume()
                }
                // A tap is not a drag: only a moved finger commits (one step).
                if (moved) vm.moveLeak((position.x / size.width).toDouble(), (position.y / size.height).toDouble(), release = true)
            }
        }.semantics { contentDescription = "Drag on the photo to move the leak" },
    )
}
