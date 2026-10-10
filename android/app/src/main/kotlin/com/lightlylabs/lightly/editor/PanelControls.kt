package com.lightlylabs.lightly.editor

import androidx.compose.ui.layout.positionInParent

import androidx.compose.runtime.mutableStateMapOf

import com.lightlylabs.lightly.shell.l2TextStyle

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
import androidx.compose.runtime.rememberUpdatedState
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
import androidx.compose.ui.semantics.stateDescription
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

/**
 * Tool tabs (Lightly 2 `tabs`): a scrolling row, 20 dp gaps, 14.5 sp; selected bold ink (with the 2 dp orange underline
 * when [underline], Develop's browsed category), others medium ink3; a 5 dp orange dot on tabs holding an edit; the end
 * fades (88 %). The tab before the selected one is scrolled to the start (`scrolled()`).
 */
@Composable
fun <T> OptionTabs(
    items: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit, dotted: (T) -> Boolean = { false }, tagPrefix: String = "tab",
    underline: Boolean = false, icon: (T) -> androidx.compose.ui.graphics.vector.ImageVector? = { null },
) {
    val colors = lightlyColors
    val scroll = rememberScrollState()
    val offsets = remember { mutableStateMapOf<Int, Int>() }
    val selectedIndex = items.indexOfFirst { it.first == selected }
    LaunchedEffect(selectedIndex, offsets[maxOf(0, selectedIndex - 1)]) {
        val target = offsets[maxOf(0, selectedIndex - 1)] ?: return@LaunchedEffect
        scroll.scrollTo(target.coerceIn(0, scroll.maxValue))
    }
    Row(
        // The end fades only while tabs are hidden past it (owner amendment 2026-10-10).
        Modifier.fillMaxWidth().fadeEnd(scroll.canScrollForward).horizontalScroll(scroll),
        horizontalArrangement = Arrangement.spacedBy(20.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        items.forEachIndexed { index, (value, label) ->
            val on = value == selected
            Box(
                Modifier
                    .heightIn(min = 44.dp)
                    .onGloballyPositioned { offsets[index] = it.positionInParent().x.roundToInt() }
                    .clickable(role = Role.Tab) { onSelect(value) }
                    .semantics { this.selected = on; if (dotted(value)) stateDescription = "Edited" }
                    .testTagResource("$tagPrefix-${label.lowercase().replace(' ', '-')}"),
                contentAlignment = Alignment.Center,
            ) {
                Row(
                    // `padding: 8px 0 7px`, the underline an inset 2 dp at the bottom of that box.
                    Modifier.drawBehind { if (on && underline) drawRect(colors.browse, Offset(0f, size.height - 2.dp.toPx()), Size(size.width, 2.dp.toPx())) }
                        .padding(top = 8.dp, bottom = 7.dp),
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    icon(value)?.let { com.lightlylabs.lightly.shell.LightlyIcon(it, size = 14.dp, tint = if (on) colors.ink else colors.ink3) }
                    Text(label, style = l2TextStyle(14.5.sp, if (on) FontWeight.Bold else FontWeight.Medium, if (on) colors.ink else colors.ink3), maxLines = 1)
                    if (dotted(value)) Box(Modifier.size(5.dp).background(colors.edited, CircleShape))
                }
            }
        }
    }
}

/**
 * Lightly 2 `slider`: the label (92 dp, 13 sp semibold ink2), a 3 dp `--off` track with the accent fill (from the centre
 * on bipolar ranges, with a 2×12 dp ink3 centre mark), a 22 dp knob with a soft shadow, the value (34 dp, 13 sp bold ink,
 * "+" when positive on bipolar ranges). Dragging calls [onDrag]; release [onRelease]. [enabled] false dims it to 40 %.
 */
@Composable
fun SliderRow(label: String, value: Double, min: Double, max: Double, onDrag: (Double) -> Unit, onRelease: (Double) -> Unit, tag: String, enabled: Boolean = true) {
    var trackingValue by remember(tag) { mutableFloatStateOf(Float.NaN) }
    val dragCallback by rememberUpdatedState(onDrag)
    val releaseCallback by rememberUpdatedState(onRelease)
    val displayedValue = if (trackingValue.isNaN()) value else trackingValue.toDouble()
    val colors = lightlyColors
    val centred = min < 0
    Row(
        Modifier.fillMaxWidth().heightIn(min = 38.dp).graphicsLayer { alpha = if (enabled) 1f else 0.4f },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(label, style = l2TextStyle(13.sp, FontWeight.SemiBold, colors.ink2), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.width(92.dp))
        Box(
            Modifier
                .weight(1f)
                .height(44.dp)
                .then(if (!enabled) Modifier else Modifier.pointerInput(min, max) {
                    awaitEachGesture {
                        val down = awaitFirstDown()
                        fun valueAt(x: Float) = (min + (x / size.width).coerceIn(0f, 1f) * (max - min)).toDouble()
                        var current = valueAt(down.position.x)
                        trackingValue = current.toFloat()
                        dragCallback(current.roundToInt().toDouble())
                        while (true) {
                            val change = awaitPointerEvent().changes.first()
                            if (!change.pressed) break
                            val next = valueAt(change.position.x)
                            trackingValue = next.toFloat()
                            if (next.roundToInt() != current.roundToInt()) dragCallback(next.roundToInt().toDouble())
                            current = next
                            change.consume()
                        }
                        releaseCallback(current.roundToInt().toDouble())
                        trackingValue = Float.NaN
                    }
                })
                .semantics {
                    contentDescription = label
                    stateDescription = (if (centred && value.roundToInt() > 0) "+" else "") + value.roundToInt()
                    progressBarRangeInfo = ProgressBarRangeInfo(value.toFloat(), min.toFloat()..max.toFloat(), steps = (max - min).toInt() - 1)
                    if (enabled) setProgress { v -> onRelease(v.roundToInt().toDouble()); true }
                }
                .testTagResource(tag),
            contentAlignment = Alignment.CenterStart,
        ) {
            Canvas(Modifier.fillMaxWidth().height(22.dp)) {
                val y = size.height / 2
                val track = 3.dp.toPx()
                val f = ((displayedValue - min) / (max - min)).toFloat().coerceIn(0f, 1f)
                drawRoundRect(colors.track, Offset(0f, y - track / 2), Size(size.width, track), CornerRadius(2.dp.toPx()))
                if (centred) drawRoundRect(colors.ink3, Offset(size.width / 2 - 1.dp.toPx(), y - 6.dp.toPx()), Size(2.dp.toPx(), 12.dp.toPx()), CornerRadius(1.dp.toPx()))
                val from = if (centred) minOf(0.5f, f) else 0f
                val to = if (centred) maxOf(0.5f, f) else f
                drawRoundRect(colors.sel, Offset(size.width * from, y - track / 2), Size(size.width * (to - from), track), CornerRadius(2.dp.toPx()))
                val knob = 11.dp.toPx()
                drawCircle(Color.Black.copy(alpha = 0.2f), knob + 1.dp.toPx(), Offset(size.width * f, y + 1.dp.toPx()))
                drawCircle(colors.knob, knob, Offset(size.width * f, y))
            }
        }
        val shown = displayedValue.roundToInt()
        Text((if (centred && shown > 0) "+" else "") + shown, style = l2TextStyle(13.sp, FontWeight.Bold, colors.ink), textAlign = TextAlign.End, modifier = Modifier.width(34.dp), maxLines = 1)
    }
}

/** A sideways-scrolling row (`rowOf`/`chips`): [spacing] dp gaps, the end fading (88 %). */
@Composable
fun ChipRow(spacing: Dp = 8.dp, content: @Composable RowScope.() -> Unit) {
    val rowScroll = rememberScrollState()
    Row(
        // The end fades only while chips are hidden past it (owner amendment 2026-10-10).
        Modifier.fillMaxWidth().fadeEnd(rowScroll.canScrollForward).horizontalScroll(rowScroll).padding(vertical = 4.dp, horizontal = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(spacing),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

/**
 * An option (Lightly 2 `chips`): a 38 dp capsule, 13 dp padding, 13 sp semibold; selected on an ink fill with on-ink
 * content, others outlined in ink2. [card] options (signatures, fonts) are [cardHeight] dp, 16 dp corners, a 2 dp accent
 * border when selected.
 */
@Composable
fun OptChip(selected: Boolean, description: String, onClick: () -> Unit, tag: String, card: Boolean = false, cardHeight: Dp = 50.dp, minWidth: Dp = 0.dp, content: @Composable RowScope.() -> Unit) {
    val colors = lightlyColors
    val shape = if (card) RoundedCornerShape(16.dp) else RoundedCornerShape(19.dp)
    val ink = if (card) colors.ink else if (selected) colors.onInk else colors.ink2
    androidx.compose.runtime.CompositionLocalProvider(
        androidx.compose.material3.LocalContentColor provides ink,
        androidx.compose.material3.LocalTextStyle provides l2TextStyle(13.sp, FontWeight.SemiBold, ink),
    ) {
        Row(
            Modifier
                .heightIn(min = if (card) cardHeight else 38.dp)
                .widthIn(min = minWidth)
                .clip(shape)
                .then(if (!card && selected) Modifier.background(colors.segmentOn) else Modifier)
                .then(when {
                    card -> Modifier.border(if (selected) 2.dp else 1.dp, if (selected) colors.sel else colors.hair, shape)
                    !selected -> Modifier.border(1.dp, colors.hair, shape)
                    else -> Modifier
                })
                .clickable(role = Role.RadioButton, onClick = onClick)
                .semantics { contentDescription = description; this.selected = selected }
                .testTagResource(tag)
                .padding(horizontal = if (card) 12.dp else 13.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically,
            content = content,
        )
    }
}

/**
 * A swatch (Lightly 2 gradient swatches: [width]×[height], 14 dp corners); selected, a 2 dp sheet-coloured gap and a
 * 2 dp accent ring outside it.
 */
@Composable
fun Swatch(fill: (Size) -> Brush, selected: Boolean, description: String, onClick: () -> Unit, tag: String, width: Dp = 56.dp, cornerRadius: Dp? = 14.dp, colourName: String? = null, height: Dp = 42.dp) {
    val colors = lightlyColors
    val radius = cornerRadius ?: (height / 2)
    val shape = RoundedCornerShape(radius)
    Box(
        Modifier
            .padding(4.dp)
            .size(width = width, height = height)
            .drawBehind {
                if (selected) {
                    val r = radius.toPx()
                    drawRoundRect(colors.sheet, Offset(-2.dp.toPx(), -2.dp.toPx()), Size(size.width + 4.dp.toPx(), size.height + 4.dp.toPx()), CornerRadius(r + 2.dp.toPx()), style = Stroke(2.dp.toPx()))
                    drawRoundRect(colors.sel, Offset(-3.dp.toPx(), -3.dp.toPx()), Size(size.width + 6.dp.toPx(), size.height + 6.dp.toPx()), CornerRadius(r + 4.dp.toPx()), style = Stroke(2.dp.toPx()))
                }
            }
            .clip(shape)
            .drawBehind { drawRect(fill(size)) }
            .clickable(role = Role.RadioButton, onClick = onClick)
            .semantics {
                contentDescription = description
                this.selected = selected
                colourName?.let { stateDescription = it }
            }
            .testTagResource(tag),
    )
}

/** Spoken names of the approved swatch colours (Border, Watermark, Change background); the same names as iOS. */
object SwatchNames {
    private val names = mapOf(
        "#FFFFFF" to "White", "#F4F1EC" to "Warm white", "#111111" to "Black", "#3C4A55" to "Slate", "#C9A27E" to "Tan",
        "#5A4636" to "Brown", "#C9C2B8" to "Stone", "#1F2328" to "Charcoal", "#8A8A8F" to "Grey",
        // Change background's other swatches. iOS names none of its background swatches (they keep the approved
        // "Colour #hex" label); these four are Android-only names, reported for iOS to adopt or replace.
        "#D9D4CC" to "Light stone", "#9AA3A8" to "Blue grey", "#8A5A44" to "Rust", "#4E6B5A" to "Forest green",
    )
    fun of(hex: String): String? = names[hex.uppercase()]
}

/** The (+) tile: 60 dp, 16 dp corners, a 1.5 dp dashed ink3 outline. */
@Composable
fun AddTile(description: String, onClick: () -> Unit, tag: String, content: @Composable () -> Unit) {
    val colors = lightlyColors
    Box(
        Modifier
            .size(60.dp)
            .drawBehind {
                drawRoundRect(colors.ink3, cornerRadius = CornerRadius(16.dp.toPx()), style = Stroke(1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx()))))
            }
            .clip(RoundedCornerShape(16.dp))
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

/** Lightly 2 `note`: 12.5 sp ink2, line height 1.4; spacing comes from the panel's column. */
@Suppress("UNUSED_PARAMETER")
@Composable
fun PanelNote(text: String, modifier: Modifier = Modifier, bottom: Dp = 0.dp) {
    Text(text, style = l2TextStyle(12.5.sp, color = lightlyColors.ink2, lineHeight = 1.4f), modifier = modifier.fillMaxWidth())
}
