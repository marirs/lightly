package com.lightlylabs.lightly.editor

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.systemGestureExclusion
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
 * - Crop: `.cropframe` at the real crop rectangle over the uncropped frame (owner amendment 2026-10-05): border, thirds
 *   grid, four corner handles, the rest darkened; corners, edges and the inside drag (free crop).
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
            EditSub.CROP -> if (!ui.edit.cropPreview) CropFrame(vm)
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

/**
 * Free crop (owner amendment 2026-10-05, as iOS): the stage shows the straightened frame uncropped
 * ([EditorViewModel.isCropEditing]); the approved `.cropframe` (border, thirds grid, corner handles, the rest darkened) is
 * drawn at the real crop rectangle. Drag a corner or an edge to resize, inside to move; an aspect preset locks the ratio.
 * The drag shows the rectangle; its end is one undo step.
 */
@Composable
private fun CropFrame(vm: EditorViewModel) {
    val committed = vm.cropState()?.first ?: return
    var draft by remember { mutableStateOf<com.lightlylabs.lightly.session.NormalisedRect?>(null) }
    val rect = draft ?: committed
    Canvas(
        Modifier
            .fillMaxSize()
            .cropHandleGestureExclusion(rect)
            .pointerInput(Unit) { cropGestures(vm) { draft = it } }
            .semantics { contentDescription = "Drag a corner or an edge to crop. Drag inside to move." },
    ) {
        val inset = Offset(size.width * rect.x.toFloat(), size.height * rect.y.toFloat())
        val frame = Size(size.width * rect.width.toFloat(), size.height * rect.height.toFloat())
        val border = 1.dp.toPx()
        // `box-shadow: 0 0 0 2000px`: everything outside the frame, clipped by the photo.
        drawRect(CROP_SHADE, Offset.Zero, Size(size.width, inset.y))
        drawRect(CROP_SHADE, Offset(0f, inset.y + frame.height), Size(size.width, size.height - inset.y - frame.height))
        drawRect(CROP_SHADE, Offset(0f, inset.y), Size(inset.x, frame.height))
        drawRect(CROP_SHADE, Offset(inset.x + frame.width, inset.y), Size(size.width - inset.x - frame.width, frame.height))
        drawRect(Color.White, inset + Offset(border / 2, border / 2), Size(frame.width - border, frame.height - border), style = Stroke(border))
        thirdsGrid(inset + Offset(border, border), Size(frame.width - 2 * border, frame.height - 2 * border))
        // Handles: 18 px squares at the frame's corners, a 3 px border on the two outer sides.
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

/**
 * A photo as wide as the screen puts the left and right crop handles inside the system Back gesture zones (gesture
 * navigation), so dragging them closed the editor's dialog instead of cropping. The four corners and the middle of the
 * left and right edges are excluded from system gestures: 48 + 48 + 96 dp per side, within Android's 200 dp limit.
 */
private fun Modifier.cropHandleGestureExclusion(rect: com.lightlylabs.lightly.session.NormalisedRect): Modifier {
    return this
        .systemGestureExclusion { c -> handleZone(c.size, rect.x, rect.y, 48f) }
        .systemGestureExclusion { c -> handleZone(c.size, rect.x, rect.y + rect.height, 48f) }
        .systemGestureExclusion { c -> handleZone(c.size, rect.x + rect.width, rect.y, 48f) }
        .systemGestureExclusion { c -> handleZone(c.size, rect.x + rect.width, rect.y + rect.height, 48f) }
        .systemGestureExclusion { c -> handleZone(c.size, rect.x, rect.y + rect.height / 2, 96f) }
        .systemGestureExclusion { c -> handleZone(c.size, rect.x + rect.width, rect.y + rect.height / 2, 96f) }
}

/** A 48 dp wide, [heightDp] tall rectangle centred on the handle at fractions ([fx], [fy]) of the frame. */
private fun handleZone(size: androidx.compose.ui.unit.IntSize, fx: Double, fy: Double, heightDp: Float): androidx.compose.ui.geometry.Rect {
    val density = android.content.res.Resources.getSystem().displayMetrics.density
    val cx = (size.width * fx).toFloat()
    val cy = (size.height * fy).toFloat()
    val halfW = 24f * density
    val halfH = heightDp / 2 * density
    return androidx.compose.ui.geometry.Rect(cx - halfW, cy - halfH, cx + halfW, cy + halfH)
}

/** One finger: a corner, an edge or the inside of the crop rectangle (CropGeometry), previewed as [onDraft], committed at the end. */
private suspend fun PointerInputScope.cropGestures(vm: EditorViewModel, onDraft: (com.lightlylabs.lightly.session.NormalisedRect?) -> Unit) = awaitEachGesture {
    val down = awaitFirstDown()
    val (start, ratio, frameAspect) = vm.cropState() ?: return@awaitEachGesture
    val w = size.width.toFloat()
    val h = size.height.toFloat()
    val handle = CropGeometry.handle(down.position.x, down.position.y, start, w, h, reach = 22.dp.toPx()) ?: return@awaitEachGesture
    var last = down.position
    while (true) {
        val event = awaitPointerEvent()
        val pressed = event.changes.firstOrNull { it.id == down.id } ?: break
        if (!pressed.pressed) break
        last = pressed.position
        onDraft(CropGeometry.dragged(start, handle, ((last.x - down.position.x) / w).toDouble(), ((last.y - down.position.y) / h).toDouble(), ratio, frameAspect))
        event.changes.forEach { it.consume() }
    }
    onDraft(null)
    if (last != down.position) {
        vm.commitCrop(CropGeometry.dragged(start, handle, ((last.x - down.position.x) / w).toDouble(), ((last.y - down.position.y) / h).toDouble(), ratio, frameAspect))
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
