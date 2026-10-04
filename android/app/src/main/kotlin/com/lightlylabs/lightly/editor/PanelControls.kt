package com.lightlylabs.lightly.editor

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.shell.lightlyColors
import com.lightlylabs.lightly.shell.lightlyTextStyle
import com.lightlylabs.lightly.shell.testTagResource
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/*
 * The prototype's shared panel pieces (app.js `tabs`, `sl`, `.opt`, `.sw`, `.thumbopt`, `.note`),
 * reused by every tool panel from slice 3 on.
 */

/** `.tabs`: one scrolling row of text tabs, faded at both ends (or wrapping in the wide layout). */
@Composable
fun <T> OptionTabs(items: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit, dotted: (T) -> Boolean = { false }, tagPrefix: String = "tab") {
    val colors = lightlyColors
    val scroll = rememberScrollState()
    // The selected tab's left edge in window coordinates, as currently scrolled.
    var selectedWindowX by remember { mutableFloatStateOf(Float.NaN) }
    val density = LocalDensity.current
    // Prototype buildRulers, for every `.tabs` row that overflows: scrollLeft = max(0, on.offsetLeft − 120),
    // with offsetLeft measured from the device frame's left edge, so the selected tab lands 120 dp in
    // (the same rule as the Develop category strip).
    LaunchedEffect(selected, selectedWindowX) {
        if (selectedWindowX.isNaN() || scroll.maxValue == 0) return@LaunchedEffect
        val target = (scroll.value + selectedWindowX - with(density) { 120.dp.toPx() }).roundToInt().coerceIn(0, scroll.maxValue)
        if (abs(target - scroll.value) > 1) scroll.scrollTo(target)
    }
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
            .drawWithContent {
                drawContent()
                val w = size.width
                drawRect(Brush.horizontalGradient(0f to Color.Transparent, 16.dp.toPx() / w to Color.Black, 1f - 24.dp.toPx() / w to Color.Black, 1f to Color.Transparent), blendMode = BlendMode.DstIn)
            }
            .horizontalScroll(scroll)
            .padding(horizontal = 18.dp),
        horizontalArrangement = Arrangement.spacedBy(20.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        items.forEach { (value, label) ->
            val on = value == selected
            Row(
                Modifier
                    .heightIn(min = 44.dp)
                    .widthIn(min = 44.dp)
                    .clickable(role = Role.Tab) { onSelect(value) }
                    .semantics { this.selected = on }
                    .then(if (on) Modifier.onGloballyPositioned { selectedWindowX = it.positionInWindow().x } else Modifier)
                    .testTagResource("$tagPrefix-${label.lowercase().replace(' ', '-')}"),
                horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(label, style = lightlyTextStyle(15.sp, if (on) FontWeight.SemiBold else FontWeight.Normal, if (on) colors.ink else colors.ink2), maxLines = 1)
                if (dotted(value)) Box(Modifier.padding(start = 3.dp).size(5.dp).background(colors.sel, CircleShape))
            }
        }
    }
}

/**
 * `.sl`: label (max-content), a track (at least 90 dp, filling the rest), the rounded value (36 dp,
 * right-aligned, "+" for positive values on centred sliders). Dragging calls [onDrag]; release [onRelease].
 */
@Composable
fun SliderRow(label: String, value: Double, min: Double, max: Double, onDrag: (Double) -> Unit, onRelease: (Double) -> Unit, tag: String) {
    val colors = lightlyColors
    val centred = min < 0
    Row(
        Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(label, style = lightlyTextStyle(color = colors.ink), maxLines = 1, overflow = TextOverflow.Ellipsis)
        Box(
            Modifier
                .weight(1f)
                .widthIn(min = 90.dp)
                .height(44.dp)
                .pointerInput(min, max) {
                    awaitEachGesture {
                        val down = awaitFirstDown()
                        fun valueAt(x: Float) = (min + (x / size.width).coerceIn(0f, 1f) * (max - min)).roundToInt().toDouble()
                        var current = valueAt(down.position.x)
                        onDrag(current)
                        while (true) {
                            val change = awaitPointerEvent().changes.first()
                            if (!change.pressed) break
                            current = valueAt(change.position.x)
                            onDrag(current)
                            change.consume()
                        }
                        onRelease(current)
                    }
                }
                .semantics {
                    contentDescription = label
                    progressBarRangeInfo = ProgressBarRangeInfo(value.toFloat(), min.toFloat()..max.toFloat(), steps = (max - min).toInt() - 1)
                    setProgress { v -> onRelease(v.roundToInt().toDouble()); true }
                }
                .testTagResource(tag),
            contentAlignment = Alignment.CenterStart,
        ) {
            Canvas(Modifier.fillMaxWidth().height(18.dp)) {
                val y = size.height / 2
                val track = 3.dp.toPx()
                val f = ((value - min) / (max - min)).toFloat().coerceIn(0f, 1f)
                drawRoundRect(colors.track, Offset(0f, y - track / 2), Size(size.width, track), CornerRadius(2.dp.toPx()))
                val from = if (centred) minOf(0.5f, f) else 0f
                val to = if (centred) maxOf(0.5f, f) else f
                drawRoundRect(colors.ink, Offset(size.width * from, y - track / 2), Size(size.width * (to - from), track), CornerRadius(2.dp.toPx()))
                val knob = 9.dp.toPx()
                drawCircle(if (colors.isDark) colors.ink else colors.bg, knob, Offset(size.width * f, y))
                // `.trk b { border:1.5px }` renders as 1px (Chrome floors fractional borders).
                drawCircle(colors.ink, knob - 0.5.dp.toPx(), Offset(size.width * f, y), style = Stroke(1.dp.toPx()))
            }
        }
        val shown = value.roundToInt()
        Text((if (centred && shown > 0) "+" else "") + shown, style = lightlyTextStyle(13.sp, color = colors.ink3), textAlign = TextAlign.End, modifier = Modifier.width(36.dp), maxLines = 1)
    }
}

/** `.chiprow`: a scrolling row of options, gap 8, padding 6 18. */
@Composable
fun ChipRow(content: @Composable RowScope.() -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 18.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

/** `.opt`: an outlined option (44 dp min, radius 10, border-box padding 0 12 + 1 border); selected = selection colour and soft fill. */
@Composable
fun OptChip(selected: Boolean, description: String, onClick: () -> Unit, tag: String, content: @Composable RowScope.() -> Unit) {
    val colors = lightlyColors
    val shape = RoundedCornerShape(10.dp)
    Row(
        Modifier
            .heightIn(min = 44.dp)
            .widthIn(min = 44.dp)
            .clip(shape)
            .then(if (selected) Modifier.background(colors.selSoft) else Modifier)
            .border(1.dp, if (selected) colors.sel else colors.hair, shape)
            .clickable(role = Role.RadioButton, onClick = onClick)
            .semantics { contentDescription = description; this.selected = selected }
            .testTagResource(tag)
            // CSS border-box: `padding: 0 12px` plus the 1px border, which takes layout space in CSS but
            // not in Compose (its border is drawn inside). 12 alone made every chip 2 dp narrower.
            .padding(horizontal = 12.dp + 1.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

/** `.sw` (44 dp circle) or a gradient swatch (52 × 44, radius 10); selected = a 2 dp ring 5 dp outside. */
@Composable
fun Swatch(fill: (Size) -> Brush, selected: Boolean, description: String, onClick: () -> Unit, tag: String, width: Dp = 44.dp, cornerRadius: Dp? = null) {
    val colors = lightlyColors
    val shape = if (cornerRadius == null) CircleShape else RoundedCornerShape(cornerRadius)
    Box(
        Modifier
            .size(width = width, height = 44.dp)
            .drawBehind {
                if (selected) {
                    // `.sw.on::after`: absolutely positioned at inset -5px from the swatch's PADDING box
                    // (inside its 1px border), so the ring's outer edge is 4 dp outside the swatch; a 2px
                    // border; border-radius 50% of the ring box, i.e. a circle on round swatches and an
                    // ellipse on the 52 × 44 gradient swatches.
                    val outside = 4.dp.toPx()
                    val stroke = 2.dp.toPx()
                    drawOval(
                        colors.sel,
                        topLeft = Offset(-outside + stroke / 2, -outside + stroke / 2),
                        size = Size(size.width + 2 * outside - stroke, size.height + 2 * outside - stroke),
                        style = Stroke(stroke),
                    )
                }
            }
            .clip(shape)
            .drawBehind { drawRect(fill(size)) }
            .border(1.dp, colors.hair, shape)
            .clickable(role = Role.RadioButton, onClick = onClick)
            .semantics { contentDescription = description; this.selected = selected }
            .testTagResource(tag),
    )
}

/** `.thumbopt.add`: the dashed 64 dp tile with a plus. */
@Composable
fun AddTile(description: String, onClick: () -> Unit, tag: String, content: @Composable () -> Unit) {
    val colors = lightlyColors
    Box(
        Modifier
            .size(64.dp)
            .drawBehind {
                drawRoundRect(colors.ink3, cornerRadius = CornerRadius(10.dp.toPx()), style = Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx()))))
            }
            .clip(RoundedCornerShape(10.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description }
            .testTagResource(tag),
        contentAlignment = Alignment.Center,
    ) { content() }
}

/** CSS `linear-gradient(angle, a, b)` as a Compose brush for a box of [width] × [height] px. */
fun cssLinearGradient(angleDegrees: Double, colours: List<Color>, width: Float, height: Float): Brush {
    val a = Math.toRadians(angleDegrees)
    val dx = sin(a).toFloat()
    val dy = -cos(a).toFloat()
    val half = (abs(width * sin(a)) + abs(height * cos(a))).toFloat() / 2
    val centre = Offset(width / 2, height / 2)
    return Brush.linearGradient(colours, start = centre - Offset(dx, dy) * half, end = centre + Offset(dx, dy) * half)
}

fun colourOf(hex: String): Color = Color(0xFF000000 or hex.substring(1).toLong(16))

/** `.note`: 13 sp ink3, padding 6 18. */
@Composable
fun PanelNote(text: String, modifier: Modifier = Modifier) {
    Text(text, style = lightlyTextStyle(13.sp, color = lightlyColors.ink3), modifier = modifier.padding(horizontal = 18.dp, vertical = 6.dp))
}
