package com.lightlylabs.lightly.editor

import android.graphics.BitmapFactory
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.shell.lightlyColors
import com.lightlylabs.lightly.shell.lightlyTextStyle
import com.lightlylabs.lightly.shell.testTagResource
import com.lightlylabs.lightly.signatures.DrawnSignature

/** `.sheethead`: Cancel, the centred title, the trailing action (`.btn.quiet` in the 17 px semibold head). */
@Composable
fun SheetHeadWithAction(title: String, action: String, onCancel: () -> Unit, onAction: () -> Unit, actionTag: String) {
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(start = 18.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        HeadButton("Cancel", onCancel, "sheet-cancel")
        Text(title, style = lightlyTextStyle(17.sp, FontWeight.SemiBold, lightlyColors.ink), textAlign = TextAlign.Center, modifier = Modifier.weight(1f).semantics { heading() })
        HeadButton(action, onAction, actionTag)
    }
}

@Composable
private fun HeadButton(label: String, onClick: () -> Unit, tag: String) {
    Box(Modifier.heightIn(min = 44.dp).clip(RoundedCornerShape(10.dp)).clickable(role = Role.Button, onClick = onClick).padding(horizontal = 12.dp).testTagResource(tag), contentAlignment = Alignment.Center) {
        Text(label, style = lightlyTextStyle(17.sp, FontWeight.SemiBold, lightlyColors.sel))
    }
}

/**
 * Prototype `sigDraw`: Cancel · "Draw signature" · Save; `.sigpad` (180 dp, 1 px dashed ink-3 border, radius
 * 12, `.line` 20 dp in from each side and 40 dp above the bottom); Clear and the note. Strokes are in pad dp.
 */
@Composable
fun ColumnScope.DrawSignatureSheet(strokes: List<List<DrawnSignature.Point>>, onStrokes: (List<List<DrawnSignature.Point>>) -> Unit, onCancel: () -> Unit, onSave: () -> Unit, onClear: () -> Unit) {
    val colors = lightlyColors
    SheetHeadWithAction("Draw signature", "Save", onCancel, onSave, "signature-draw-save")
    Box(
        Modifier.padding(horizontal = 18.dp, vertical = 12.dp).fillMaxWidth().height(180.dp)
            .pointerInput(strokes) {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    fun point(o: Offset) = DrawnSignature.Point((o.x / density).toDouble(), (o.y / density).toDouble())
                    var stroke = listOf(point(down.position))
                    onStrokes(strokes + listOf(stroke))
                    while (true) {
                        val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                        if (!change.pressed) break
                        stroke = stroke + point(change.position)
                        onStrokes(strokes + listOf(stroke))
                        change.consume()
                    }
                }
            }
            .semantics { contentDescription = "Signature pad. Draw your signature with one finger." }
            .testTagResource("signature-pad"),
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val line = 1.dp.toPx()
            drawRoundRect(colors.bg, cornerRadius = CornerRadius(12.dp.toPx()))
            drawRect(colors.hair, Offset(20.dp.toPx(), size.height - 40.dp.toPx() - line), androidx.compose.ui.geometry.Size(size.width - 40.dp.toPx(), line))
            val pen = WatermarkOptions.PEN_WIDTH.toFloat() * density
            strokes.filter { it.isNotEmpty() }.forEach { stroke ->
                val points = stroke.map { Offset(it.x.toFloat() * density, it.y.toFloat() * density) }
                val path = Path().apply {
                    moveTo(points[0].x, points[0].y)
                    if (points.size == 1) lineTo(points[0].x, points[0].y)
                    for (i in 1 until points.size - 1) quadraticTo(points[i].x, points[i].y, (points[i].x + points[i + 1].x) / 2, (points[i].y + points[i + 1].y) / 2)
                    if (points.size > 1) lineTo(points.last().x, points.last().y)
                }
                drawPath(path, colors.ink, style = Stroke(pen, cap = StrokeCap.Round, join = StrokeJoin.Round))
            }
            drawRoundRect(colors.ink3, topLeft = Offset(line / 2, line / 2), size = androidx.compose.ui.geometry.Size(size.width - line, size.height - line), cornerRadius = CornerRadius(12.dp.toPx()),
                style = Stroke(line, pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx()))))
        }
    }
    Row(Modifier.fillMaxWidth().padding(horizontal = 10.dp), verticalAlignment = Alignment.Top) {
        QuietSmallButton("Clear", onClick = onClear, large = true, modifier = Modifier.testTagResource("signature-draw-clear"))
        Spacer(Modifier.weight(1f))
        PanelNote("Saved for reuse. It keeps its own look.")
    }
}

/** Prototype `sigImport`: Cancel · "Import signature" · Use; the signature on paper colour with the dashed selection; the note. */
@Composable
fun ColumnScope.ImportSignatureSheet(png: ByteArray?, onCancel: () -> Unit, onUse: () -> Unit) {
    val colors = lightlyColors
    SheetHeadWithAction("Import signature", "Use", onCancel, onUse, "signature-import-use")
    Box(
        Modifier.padding(horizontal = 18.dp, vertical = 10.dp).fillMaxWidth().height(170.dp).clip(RoundedCornerShape(12.dp)).background(Color(0xFFF7F4EE)),
        contentAlignment = Alignment.Center,
    ) {
        val bitmap = remember(png) { png?.let { BitmapFactory.decodeByteArray(it, 0, it.size)?.asImageBitmap() } }
        if (bitmap != null) Image(bitmap, "Imported signature", Modifier.size(70.dp * (bitmap.width.toFloat() / bitmap.height), 70.dp))
        // `inset:14px; border:1.5px dashed var(--sel); border-radius:8px` (the CSS source width).
        Canvas(Modifier.fillMaxSize().padding(14.dp)) {
            val w = 1.5.dp.toPx()
            drawRoundRect(colors.sel, topLeft = Offset(w / 2, w / 2), size = androidx.compose.ui.geometry.Size(size.width - w, size.height - w), cornerRadius = CornerRadius(8.dp.toPx()),
                style = Stroke(w, pathEffect = PathEffect.dashPathEffect(floatArrayOf(3 * w, 3 * w))))
        }
    }
    PanelNote("The paper is removed. The ink keeps its original colour and texture.")
}

/** The prototype's sample in the pad (`sigSvg(70)` at left 24, bottom 34 of the 180 dp pad): design captures only. */
fun prototypePadStrokes(): List<List<DrawnSignature.Point>> {
    val scale = 70.0 / 50
    val top = 180.0 - 34 - 70
    return DrawnSignature.PROTOTYPE_SAMPLE.strokes.map { stroke -> stroke.map { DrawnSignature.Point(24 + it.x * scale, top + it.y * scale) } }
}

/**
 * Preferences › Saved signature's Draw and Import sheets, over whatever is on screen (Welcome, the editor,
 * the More page): a scrim and a bottom sheet with the grabber (radius 14, padding 8 0 30), as `.sheet`.
 */
@Composable
fun PreferencesSignatureSheet(vm: EditorViewModel) {
    val ui by vm.uiState.collectAsStateWithLifecycle()
    if (!vm.preferencesSheetOpen(ui)) return
    val colors = lightlyColors
    androidx.activity.compose.BackHandler(onBack = vm::closeSignatureSheet)
    Box(
        Modifier.fillMaxSize().background(colors.scrim).clickable(interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, indication = null) {},
        contentAlignment = Alignment.BottomCenter,
    ) {
        androidx.compose.foundation.layout.Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp)).background(colors.sheet)
                .clickable(interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, indication = null) {}
                .padding(top = 8.dp, bottom = 30.dp),
        ) {
            com.lightlylabs.lightly.shell.SheetGrabber()
            if (ui.overlay == EditorOverlay.SIGNATURE_DRAW) DrawSignatureSheet(ui.watermark.pad, vm::padStroke, onCancel = vm::closeSignatureSheet, onSave = vm::saveDrawnSignature, onClear = vm::clearPad)
            else ImportSignatureSheet(ui.watermark.imported, onCancel = vm::closeSignatureSheet, onUse = vm::useImportedSignature)
        }
    }
}
