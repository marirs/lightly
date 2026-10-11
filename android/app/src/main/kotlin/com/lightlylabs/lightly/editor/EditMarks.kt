package com.lightlylabs.lightly.editor

import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.systemGestureExclusion
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.clickable
import com.lightlylabs.lightly.shell.testTagResource
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
 * - Remove: the stroke under the finger as `.stroke` (rgba(235,60,60,.42), round ends) while brushing; release removes; "Removing…"
 *   centred over the photo with Cancel.
 * - Light Leaks: dragging on the photo moves the leak.
 */
@Composable
fun EditMarks(vm: EditorViewModel, ui: EditorUiState) {
    if (ui.showsOriginal) return
    when (ui.tool) {
        EditorTool.EDIT -> when (ui.edit.sub) {
            // The frame while cropping; on the cropped photo a tap brings it back (owner, 2026-10-11).
            EditSub.CROP -> if (vm.isCropEditing(ui)) CropFrame(vm, ui) else Box(
                Modifier.fillMaxSize()
                    .clickable(interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, indication = null, onClick = vm::adjustCrop)
                    .semantics { contentDescription = "Adjust the crop" }
                    .testTagResource("edit-crop-adjust"),
            )
            EditSub.STRAIGHTEN, EditSub.PERSPECTIVE -> Canvas(Modifier.fillMaxSize()) { thirdsGrid(Offset.Zero, size) }
            EditSub.REMOVE -> RemoveMarks(vm, ui)
            else -> Unit
        }
        EditorTool.EFFECTS -> when {
            ui.effects.sub == EffectsSub.LEAK -> LeakDrag(vm)
            vm.picksOnTap(ui) -> SelectiveColourTap(vm)
        }
        EditorTool.WATERMARK -> ui.session?.current?.tools?.let { tools ->
            // Placement covers the complete output canvas, including any border.
            if (tools.watermark.type != com.lightlylabs.lightly.session.WatermarkType.NONE) WatermarkDrag(vm, WatermarkStage.anchor(tools.watermark))
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
 * Inline crop (owner, 2026-10-11, as iOS): the stage shows the straightened frame uncropped
 * ([EditorViewModel.isCropEditing]) with the crop frame on it: the outside dimmed (50 % black, 35 % while adjusting), a
 * 1 dp white border, 3 dp white L handles on the corners and bars on the middle of each edge (inside the frame, with a
 * soft shadow), and the thirds grid only while a drag or pinch is under way. Drag a corner or an edge to resize, inside
 * to move, pinch to resize; a fixed aspect keeps its shape. Lifting the finger applies it (one undo step).
 */
@Composable
private fun CropFrame(vm: EditorViewModel, ui: EditorUiState) {
    val committed = vm.cropState()?.first ?: return
    val adjusting = ui.edit.cropDraft != null
    val rect = ui.edit.cropDraft ?: committed
    Canvas(
        Modifier
            .fillMaxSize()
            .cropHandleGestureExclusion(rect)
            .semantics { contentDescription = "Drag a corner or an edge to crop. Drag inside to move." },
    ) {
        val inset = Offset(size.width * rect.x.toFloat(), size.height * rect.y.toFloat())
        val frame = Size(size.width * rect.width.toFloat(), size.height * rect.height.toFloat())
        val shade = Color.Black.copy(alpha = if (adjusting) 0.35f else 0.5f)
        drawRect(shade, Offset.Zero, Size(size.width, inset.y))
        drawRect(shade, Offset(0f, inset.y + frame.height), Size(size.width, size.height - inset.y - frame.height))
        drawRect(shade, Offset(0f, inset.y), Size(inset.x, frame.height))
        drawRect(shade, Offset(inset.x + frame.width, inset.y), Size(size.width - inset.x - frame.width, frame.height))
        if (adjusting) thirdsGrid(inset, frame)
        val border = 1.dp.toPx()
        drawRect(Color.White.copy(alpha = 0.9f), inset + Offset(border / 2, border / 2), Size(frame.width - border, frame.height - border), style = Stroke(border))
        val thick = 3.dp.toPx()
        val arm = minOf(20.dp.toPx(), frame.width / 3, frame.height / 3)
        val bar = minOf(24.dp.toPx(), frame.width / 3, frame.height / 3)
        val shadow = Color.Black.copy(alpha = 0.25f)
        fun handle(topLeft: Offset, s: Size) {
            drawRect(shadow, topLeft + Offset(0f, 1.dp.toPx()), s)
            drawRect(Color.White, topLeft, s)
        }
        val l = inset.x; val t = inset.y; val r = inset.x + frame.width; val b = inset.y + frame.height
        for ((x, y) in listOf(l to t, r to t, l to b, r to b)) {
            val atLeft = x == l; val atTop = y == t
            handle(Offset(if (atLeft) x else x - arm, if (atTop) y else y - thick), Size(arm, thick))
            handle(Offset(if (atLeft) x else x - thick, if (atTop) y else y - arm), Size(thick, arm))
        }
        handle(Offset(inset.x + frame.width / 2 - bar / 2, t), Size(bar, thick))
        handle(Offset(inset.x + frame.width / 2 - bar / 2, b - thick), Size(bar, thick))
        handle(Offset(l, inset.y + frame.height / 2 - bar / 2), Size(thick, bar))
        handle(Offset(r - thick, inset.y + frame.height / 2 - bar / 2), Size(thick, bar))
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
/** Crop touches over the whole stage; [photo] is the photo's rect as shown (zoom included), in this box's pixels. */
@Composable
fun CropTouches(vm: EditorViewModel, photo: androidx.compose.ui.geometry.Rect) {
    val current by androidx.compose.runtime.rememberUpdatedState(photo)
    Box(Modifier.fillMaxSize().pointerInput(Unit) {
        cropGestures(vm, { current }, onDraft = { if (it != null) vm.previewCrop(it) }, onEnd = vm::finishCropDrag)
    })
}

private suspend fun PointerInputScope.cropGestures(
    vm: EditorViewModel,
    photoRect: () -> androidx.compose.ui.geometry.Rect,
    onDraft: (com.lightlylabs.lightly.session.NormalisedRect?) -> Unit,
    onEnd: (com.lightlylabs.lightly.session.NormalisedRect?) -> Unit,
) = awaitEachGesture {
    val down = awaitFirstDown()
    val (start, ratio, frameAspect) = vm.cropState() ?: return@awaitEachGesture
    val photo = photoRect()
    val w = photo.width.coerceAtLeast(1f)
    val h = photo.height.coerceAtLeast(1f)
    val handle = CropGeometry.handle(down.position.x - photo.left, down.position.y - photo.top, start, w, h, reach = 22.dp.toPx()) ?: return@awaitEachGesture
    var last = down.position
    var pinching = false
    var pinched = start
    while (true) {
        val event = awaitPointerEvent()
        if (event.changes.count { it.pressed } > 1) {
            pinching = true
            pinched = CropGeometry.scaled(pinched, event.calculateZoom().toDouble())
            onDraft(pinched)
            event.changes.forEach { it.consume() }
            continue
        }
        if (pinching) {
            event.changes.forEach { it.consume() }
            if (event.changes.none { it.pressed }) break
            continue
        }
        val pressed = event.changes.firstOrNull { it.id == down.id } ?: break
        if (pressed.isConsumed) { onEnd(null); return@awaitEachGesture }
        if (!pressed.pressed) break
        last = pressed.position
        onDraft(CropGeometry.dragged(start, handle, ((last.x - down.position.x) / w).toDouble(), ((last.y - down.position.y) / h).toDouble(), ratio, frameAspect))
        event.changes.forEach { it.consume() }
    }
    // Lifting the finger applies the crop (one undo step); a tap without movement changes nothing.
    if (pinching) onEnd(pinched)
    else if (last != down.position) onEnd(CropGeometry.dragged(start, handle, ((last.x - down.position.x) / w).toDouble(), ((last.y - down.position.y) / h).toDouble(), ratio, frameAspect))
    else onEnd(null)
}

/**
 * Remove's mark is the stroke being brushed, and only while the finger is down (mockup `ed-remove` shows the stroke under
 * the brush; `ed-removing` and `ed-remove-failed` show none). Owner report 2026-10-11: the applied strokes stayed drawn in
 * red on top of the photo after their objects were removed ("the brush is still present on the top"), and the stroke being
 * removed stayed drawn under "Removing…". The recipe's strokes are pixels of the preview now, never marks.
 */
@Composable
private fun RemoveMarks(vm: EditorViewModel, ui: EditorUiState) {
    val geometry = vm.displayGeometry(ui)
    // The finger's path in this box's pixels while brushing; empty otherwise.
    val brushing = remember { androidx.compose.runtime.mutableStateListOf<Offset>() }
    val removing = ui.edit.removeOp == RemoveOp.REMOVING
    Box(Modifier.fillMaxSize().testTagResource(EditTags.REMOVE_MARKS).pointerInput(removing) {
        if (!removing) brushGestures(onPath = { path -> brushing.clear(); brushing.addAll(path) }, onEnd = { path ->
            brushing.clear()
            vm.removeStroke(path.map { (it.x / size.width).toDouble().coerceIn(0.0, 1.0) to (it.y / size.height).toDouble().coerceIn(0.0, 1.0) })
        })
    }.semantics { contentDescription = "Brush over anything you want removed" }) {
        if (geometry != null && brushing.isNotEmpty()) Canvas(Modifier.fillMaxSize().testTagResource(EditTags.REMOVE_STROKE)) {
            // The brush radius (a fraction of the source long edge) in this box's pixels: the width the stroke will remove.
            val sourceLong = max(geometry.sourceWidth, geometry.sourceHeight).toFloat()
            val pxPerSource = size.width / geometry.frameWidth
            val width = (2 * EditOptions.brushRadius(ui.edit.brushSize) * sourceLong * pxPerSource).toFloat()
            if (brushing.size == 1) {
                drawCircle(STROKE_FILL, width / 2, brushing[0])
            } else {
                val path = Path().apply { moveTo(brushing[0].x, brushing[0].y); brushing.drop(1).forEach { lineTo(it.x, it.y) } }
                drawPath(path, STROKE_FILL, style = Stroke(width, cap = StrokeCap.Round, join = StrokeJoin.Round))
            }
        }
        if (removing) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            ProgressBox("Removing…", null, null, cancel = vm::cancelRemove)
        }
    }
}

/**
 * A drag (or a tap: one dab) on the photo in this box's pixels: [onPath] with the path so far as the finger moves, [onEnd]
 * with the whole path on release. A gesture taken over by another handler (the inspection pinch) ends with an empty path.
 */
private suspend fun PointerInputScope.brushGestures(onPath: (List<Offset>) -> Unit, onEnd: (List<Offset>) -> Unit) = awaitEachGesture {
    val down = awaitFirstDown()
    val points = arrayListOf(down.position)
    onPath(points.toList())
    while (true) {
        val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
        if (change.isConsumed) { onPath(emptyList()); return@awaitEachGesture }
        if (!change.pressed) break
        // Keep the stroke light: a new point every 4 px of travel.
        if (hypot(change.position.x - points.last().x, change.position.y - points.last().y) >= 4.dp.toPx()) {
            points += change.position
            onPath(points.toList())
        }
        change.consume()
    }
    onEnd(points)
}

/** The watermark's anchor follows the finger from where it was (photo fractions); one step on release. */
@Composable
private fun WatermarkDrag(vm: EditorViewModel, start: Pair<Double, Double>) {
    Box(
        Modifier.fillMaxSize().pointerInput(start) {
            awaitEachGesture {
                val down = awaitFirstDown()
                val origin = vm.watermarkCanvasAnchor()
                var last = down.position
                var moved = false
                while (true) {
                    val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                    if (change.isConsumed) { if (moved) vm.cancelPhotoGesturePreview(); return@awaitEachGesture }
                    if (!change.pressed) break
                    last = change.position
                    moved = true
                    vm.dragWatermark(origin, ((last.x - down.position.x) / size.width).toDouble(), ((last.y - down.position.y) / size.height).toDouble(), release = false)
                    change.consume()
                }
                if (moved) vm.dragWatermark(origin, ((last.x - down.position.x) / size.width).toDouble(), ((last.y - down.position.y) / size.height).toDouble(), release = true)
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
                    if (change.isConsumed) { if (moved) vm.cancelPhotoGesturePreview(); return@awaitEachGesture }
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
