package com.lightlylabs.lightly.editor

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.systemGestureExclusion
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/** Test tags; the markers are real nodes so tests (and TalkBack users' sighted helpers) can see them. */
object SteppedSliderTags {
    const val SLIDER = "look-slider"
    fun marker(index: Int) = "look-slider-stop-$index"
    const val THUMB = "look-slider-thumb"
}

/**
 * The stepped Look slider (spec §6, D6): one detent per stop, every detent drawn as a visible
 * marker, a haptic tick on each detent. It selects a preset; it never sets an intensity.
 *
 * Moving (drag) calls [onMove] once per detent change (transient preview); lifting the finger or a
 * tap calls [onSettle] once (one undo step). TalkBack adjusts it one stop at a time via setProgress,
 * which settles directly because there is no drag to preview.
 *
 * A custom control rather than Material's Slider: Material draws its step ticks faintly or not at
 * all depending on the version, and its track inset is not public, so markers drawn beside it
 * would not line up with the thumb.
 */
@Composable
fun SteppedLookSlider(
    stopNames: List<String>,
    selectedStop: Int,
    categoryLabel: String,
    onMove: (Int) -> Unit,
    onSettle: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val lastIndex = stopNames.lastIndex
    val haptics = LocalHapticFeedback.current
    val currentOnMove by rememberUpdatedState(onMove)
    val currentOnSettle by rememberUpdatedState(onSettle)
    // The stop under the finger while dragging; null when idle (the view model's state rules then).
    var draggingStop by remember(stopNames) { mutableStateOf<Int?>(null) }
    val shownStop = (draggingStop ?: selectedStop).coerceIn(0, lastIndex.coerceAtLeast(0))

    BoxWithConstraints(
        modifier
            .fillMaxWidth()
            .height(SLIDER_HEIGHT)
            .testTag(SteppedSliderTags.SLIDER)
            // Stop 0 sits in the left back-gesture zone; without the exclusion a drag that starts
            // there is taken by the system (seen on the API 36 emulator).
            .systemGestureExclusion()
            .semantics {
                contentDescription = "Look"
                stateDescription = "$categoryLabel, ${stopNames.getOrElse(shownStop) { "" }}, ${shownStop + 1} of ${stopNames.size}"
                progressBarRangeInfo = ProgressBarRangeInfo(shownStop.toFloat(), 0f..lastIndex.coerceAtLeast(1).toFloat(), steps = (stopNames.size - 2).coerceAtLeast(0))
                setProgress { target ->
                    val stop = target.roundToInt().coerceIn(0, lastIndex)
                    if (stop != shownStop) currentOnSettle(stop)
                    true
                }
            },
    ) {
        val density = LocalDensity.current
        val trackStartPx = with(density) { THUMB_SIZE.toPx() / 2 }
        val trackWidthPx = (with(density) { maxWidth.toPx() } - 2 * trackStartPx).coerceAtLeast(1f)
        fun stopAt(xPx: Float): Int =
            if (lastIndex <= 0) 0 else (((xPx - trackStartPx) / trackWidthPx) * lastIndex).roundToInt().coerceIn(0, lastIndex)
        fun centreOf(stop: Int): Dp = with(density) {
            (trackStartPx + if (lastIndex <= 0) 0f else trackWidthPx * stop / lastIndex).toDp()
        }
        fun moveTo(stop: Int) {
            if (stop == draggingStop) return
            draggingStop = stop
            haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
            currentOnMove(stop)
        }

        val gestures = Modifier
            .pointerInput(stopNames) {
                detectTapGestures(onTap = { offset ->
                    val stop = stopAt(offset.x)
                    haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
                    currentOnSettle(stop)
                })
            }
            .pointerInput(stopNames) {
                detectHorizontalDragGestures(
                    onDragStart = { offset -> moveTo(stopAt(offset.x)) },
                    onHorizontalDrag = { change, _ -> change.consume(); moveTo(stopAt(change.position.x)) },
                    onDragEnd = { draggingStop?.let(currentOnSettle); draggingStop = null },
                    // Cancelled (e.g. the parent scroll took over): commit what is on screen, so the
                    // photo never shows a preview that history does not hold.
                    onDragCancel = { draggingStop?.let(currentOnSettle); draggingStop = null },
                )
            }

        Box(Modifier.fillMaxWidth().height(SLIDER_HEIGHT).then(gestures)) {
            val trackColour = MaterialTheme.colorScheme.outlineVariant
            val activeColour = MaterialTheme.colorScheme.primary
            Box(
                Modifier
                    .align(Alignment.CenterStart)
                    .offset(x = centreOf(0))
                    .width(centreOf(lastIndex.coerceAtLeast(0)) - centreOf(0))
                    .height(TRACK_HEIGHT)
                    .background(trackColour, RoundedCornerShape(50)),
            )
            Box(
                Modifier
                    .align(Alignment.CenterStart)
                    .offset(x = centreOf(0))
                    .width(centreOf(shownStop) - centreOf(0))
                    .height(TRACK_HEIGHT)
                    .background(activeColour, RoundedCornerShape(50)),
            )
            for (stop in 0..lastIndex) {
                val reached = stop <= shownStop
                Box(
                    Modifier
                        .align(Alignment.CenterStart)
                        .offset(x = centreOf(stop) - MARKER_SIZE / 2)
                        .size(MARKER_SIZE)
                        .background(if (reached) activeColour else MaterialTheme.colorScheme.surface, CircleShape)
                        .border(2.dp, if (reached) activeColour else MaterialTheme.colorScheme.outline, CircleShape)
                        .testTag(SteppedSliderTags.marker(stop)),
                )
            }
            Box(
                Modifier
                    .align(Alignment.CenterStart)
                    .offset(x = centreOf(shownStop) - THUMB_SIZE / 2)
                    .size(THUMB_SIZE)
                    .background(activeColour, CircleShape)
                    .border(3.dp, MaterialTheme.colorScheme.surface, CircleShape)
                    .testTag(SteppedSliderTags.THUMB),
            )
        }
    }
}

private val SLIDER_HEIGHT = 48.dp
private val TRACK_HEIGHT = 4.dp
private val MARKER_SIZE = 12.dp
private val THUMB_SIZE = 26.dp
