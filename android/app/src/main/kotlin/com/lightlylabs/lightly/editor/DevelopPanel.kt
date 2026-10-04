package com.lightlylabs.lightly.editor

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.exponentialDecay
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.shell.LightlyIcon
import com.lightlylabs.lightly.shell.LightlyIcons
import com.lightlylabs.lightly.shell.lightlyColors
import com.lightlylabs.lightly.shell.lightlyTextStyle
import com.lightlylabs.lightly.shell.testTagResource
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Prototype `developPanel`: Auto, categories (tabs on phones, wrapped tabs in wide layouts, a list in
 * side panels, Favourites first), the notice, name / position / star / Amount, the "Applied: …" line,
 * then the ruler or the Amount slider.
 */
@Composable
fun DevelopPanel(vm: EditorViewModel, model: DevelopPanelModel, roomy: Boolean, wrapped: Boolean) = Column(Modifier.fillMaxWidth()) {
    if (roomy) PanelTitle("Develop")
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically) {
        AutoSwitchButton(model.autoSwitch, vm::toggleAuto)
        if (!roomy) {
            if (wrapped) WrappedTabs(model, vm::selectCategory, Modifier.weight(1f)) else ScrollingTabs(model, vm::selectCategory, Modifier.weight(1f))
        }
    }
    if (roomy) CategoryList(model, vm::selectCategory)
    model.notice?.let { DevelopNoticeView(it, vm) }
    NameRow(model, vm)
    Text(
        model.context,
        style = lightlyTextStyle(12.5.sp, color = lightlyColors.ink3),
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = Modifier.fillMaxWidth().heightIn(min = 18.dp).padding(horizontal = 18.dp),
    )
    if (model.amountOpen) AmountRow(model.amount, vm) else Ruler(model, vm)
}

/** `.autoT`: a ring that fills when Auto is applied; unavailable or failed reads ink3. */
@Composable
private fun AutoSwitchButton(state: AutoSwitch, onToggle: () -> Unit) {
    val colors = lightlyColors
    val text = when (state) { AutoSwitch.ON -> colors.ink; AutoSwitch.OFF -> colors.ink2; AutoSwitch.UNAVAILABLE -> colors.ink3 }
    Row(
        Modifier
            .heightIn(min = 44.dp)
            .drawBehind { drawLine(colors.hair, Offset(size.width - 0.5f, 0f), Offset(size.width - 0.5f, size.height), strokeWidth = 1.dp.toPx()) }
            .clickable(enabled = state != AutoSwitch.UNAVAILABLE, role = Role.Switch, onClick = onToggle)
            .semantics {
                contentDescription = "Automatic correction"
                toggleableState = if (state == AutoSwitch.ON) ToggleableState.On else ToggleableState.Off
                if (state == AutoSwitch.UNAVAILABLE) stateDescription = "Unavailable"
            }
            .testTagResource(EditorTags.AUTO)
            .padding(start = 18.dp, end = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        // `.autoT::before`: 9px wide plus a border, content-box (`.dv * { box-sizing: border-box }` does
        // not match pseudo-elements), corner radius 5px. The CSS border is 1.5px, but the approved renders
        // (Chrome) floor fractional border widths: computed 1px, so the box is 11 dp with a 1 dp ring.
        val dotShape = androidx.compose.foundation.shape.RoundedCornerShape(5.dp)
        Box(
            Modifier.size(11.dp).then(
                if (state == AutoSwitch.ON) Modifier.background(colors.sel, dotShape).border(1.dp, colors.sel, dotShape)
                else Modifier.border(1.dp, colors.ink3, dotShape),
            ),
        )
        Text("Auto", style = lightlyTextStyle(color = text))
    }
}

@Composable
private fun TabLabel(entry: CategoryEntry) {
    val colors = lightlyColors
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        if (entry.isFavourites) LightlyIcon(LightlyIcons.Star, size = 15.dp, tint = if (entry.selected) colors.ink else colors.ink2)
        Text(entry.label, style = lightlyTextStyle(15.sp, if (entry.selected) FontWeight.SemiBold else FontWeight.Normal, if (entry.selected) colors.ink else colors.ink2), maxLines = 1)
        Text(entry.count, style = lightlyTextStyle(12.sp, color = colors.ink3), modifier = Modifier.padding(start = 3.dp), maxLines = 1)
        if (entry.dotted) Box(Modifier.padding(start = 3.dp).size(5.dp).background(colors.sel, CircleShape))
    }
}

private fun Modifier.tab(entry: CategoryEntry, onSelect: (String) -> Unit) = this
    .heightIn(min = 44.dp)
    .clickable(role = Role.Tab) { onSelect(entry.id) }
    .semantics { selected = entry.selected }
    .testTagResource(EditorTags.category(entry.id))

/** `.tabs` on phones: one scrolling row, faded at both ends; the selected tab is scrolled to 120 dp in. */
@Composable
private fun ScrollingTabs(model: DevelopPanelModel, onSelect: (String) -> Unit, modifier: Modifier) {
    val scroll = rememberScrollState()
    // The selected tab's left edge in window coordinates, as currently scrolled.
    var selectedWindowX by remember { mutableFloatStateOf(Float.NaN) }
    val density = LocalDensity.current
    // Prototype buildRulers: scrollLeft = max(0, on.offsetLeft - 120), where offsetLeft is measured from
    // the screen's left edge (the device frame is the offset parent), so the selected tab lands 120 dp in.
    LaunchedEffect(model.categoryId, selectedWindowX) {
        if (selectedWindowX.isNaN() || scroll.maxValue == 0) return@LaunchedEffect
        val target = (scroll.value + selectedWindowX - with(density) { 120.dp.toPx() }).roundToInt().coerceIn(0, scroll.maxValue)
        if (abs(target - scroll.value) > 1) scroll.scrollTo(target)
    }
    Row(
        modifier
            .heightIn(min = 44.dp)
            .graphicsLayer(compositingStrategy = CompositingStrategy.Offscreen)
            .drawWithContent {
                drawContent()
                val w = size.width
                val start = 16.dp.toPx() / w
                val end = 1f - 24.dp.toPx() / w
                drawRect(Brush.horizontalGradient(0f to Color.Transparent, start to Color.Black, end to Color.Black, 1f to Color.Transparent), blendMode = BlendMode.DstIn)
            }
            .horizontalScroll(scroll)
            .padding(start = 14.dp, end = 18.dp),
        horizontalArrangement = Arrangement.spacedBy(20.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        model.categories.forEach { entry ->
            Box(
                Modifier.tab(entry, onSelect).then(if (entry.selected) Modifier.onGloballyPositioned { selectedWindowX = it.positionInWindow().x } else Modifier),
                contentAlignment = Alignment.Center,
            ) { TabLabel(entry) }
        }
    }
}

/** `.wrapped .tabs` (tablet portrait): the same tabs wrapping onto more rows, no fade. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun WrappedTabs(model: DevelopPanelModel, onSelect: (String) -> Unit, modifier: Modifier) {
    FlowRow(modifier.padding(start = 14.dp, end = 18.dp), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
        model.categories.forEach { entry -> Box(Modifier.tab(entry, onSelect), contentAlignment = Alignment.Center) { TabLabel(entry) } }
    }
}

/** `.catlist` (side panels and the unfolded foldable): one row per category with its count. */
@Composable
private fun CategoryList(model: DevelopPanelModel, onSelect: (String) -> Unit) {
    val colors = lightlyColors
    Column(Modifier.fillMaxWidth().padding(start = 10.dp, end = 10.dp, top = 2.dp, bottom = 4.dp)) {
        model.categories.forEach { entry ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = 44.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .then(if (entry.selected) Modifier.background(colors.bg2) else Modifier)
                    .tab(entry, onSelect)
                    .padding(horizontal = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (entry.isFavourites) LightlyIcon(LightlyIcons.Star, size = 15.dp, tint = if (entry.selected) colors.ink else colors.ink2)
                Text(entry.label, style = lightlyTextStyle(15.sp, if (entry.selected) FontWeight.SemiBold else FontWeight.Normal, if (entry.selected) colors.ink else colors.ink2), modifier = Modifier.weight(1f))
                Text(entry.count, style = lightlyTextStyle(12.sp, color = colors.ink3))
            }
        }
    }
}

/** `.notice`, with the approved copy for each Develop notice. */
@Composable
private fun DevelopNoticeView(notice: DevelopNotice, vm: EditorViewModel) {
    when (notice) {
        DevelopNotice.AutoFailed -> Notice(
            LightlyIcons.Warn,
            bold("Automatic correction didn't finish.", " Your photo is unchanged and presets still work."),
            listOf("Retry" to vm::retryAuto, "Continue with original" to vm::continueWithOriginal),
        )
        DevelopNotice.AutoUnavailable -> Notice(LightlyIcons.Info, AnnotatedString("Automatic correction isn't available on this device. Presets still work."))
        DevelopNotice.FavouritesFull -> Notice(
            LightlyIcons.Star,
            bold("Favourites holds five presets.", " Remove one in Preferences, or replace one now."),
            listOf("Replace…" to vm::openFavouriteReplace, "Not now" to vm::dismiss),
        )
    }
}

@Composable
private fun bold(head: String, rest: String) = buildAnnotatedString {
    withStyle(SpanStyle(color = lightlyColors.ink, fontWeight = FontWeight.SemiBold)) { append(head) }
    append(rest)
}

@Composable
internal fun Notice(icon: androidx.compose.ui.graphics.vector.ImageVector, text: AnnotatedString, actions: List<Pair<String, () -> Unit>> = emptyList()) {
    val colors = lightlyColors
    Row(
        Modifier
            .padding(start = 18.dp, end = 18.dp, top = 8.dp, bottom = 2.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.bg2)
            .border(1.dp, colors.hair, RoundedCornerShape(10.dp))
            // CSS border-box: the 1px border takes layout space inside the box (Compose's border does not).
            .padding(horizontal = 12.dp + 1.dp, vertical = 10.dp + 1.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        LightlyIcon(icon, size = 18.dp, tint = colors.ink2)
        Column(Modifier.weight(1f)) {
            Text(text, style = lightlyTextStyle(13.5.sp, color = colors.ink2))
            if (actions.isNotEmpty()) {
                Row(Modifier.padding(top = 4.dp).offset(x = (-12).dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    actions.forEach { (label, action) -> QuietSmallButton(label, action) }
                }
            }
        }
    }
}

/**
 * `.btn.quiet.small`: min-height 44, padding 0 12, 14.5 sp semibold in the selection colour, an
 * optional leading icon (gap 8). [large] is `.btn.quiet` (15 sp).
 */
@Composable
internal fun QuietSmallButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: androidx.compose.ui.graphics.vector.ImageVector? = null, large: Boolean = false) {
    Row(
        modifier.heightIn(min = 44.dp).clip(RoundedCornerShape(10.dp)).clickable(role = Role.Button, onClick = onClick).padding(horizontal = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) LightlyIcon(icon, size = 17.dp, tint = lightlyColors.sel)
        Text(label, style = lightlyTextStyle(if (large) 15.sp else 14.5.sp, FontWeight.SemiBold, lightlyColors.sel), maxLines = 1)
    }
}

/** `.namerow`: star, the preset name (wrapping), "stop / count", "Amount N". */
@Composable
private fun NameRow(model: DevelopPanelModel, vm: EditorViewModel) {
    val colors = lightlyColors
    Row(
        Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(start = 8.dp, end = 6.dp, top = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(
            Modifier
                .size(44.dp)
                .graphicsLayer { alpha = if (model.presetShown) 1f else 0f }
                .clickable(enabled = model.presetShown, role = Role.Button, onClick = vm::toggleStar)
                .semantics {
                    contentDescription = "Favourite"
                    toggleableState = if (model.starred) ToggleableState.On else ToggleableState.Off
                }
                .testTagResource(EditorTags.STAR),
            contentAlignment = Alignment.Center,
        ) {
            LightlyIcon(if (model.starred) LightlyIcons.StarFilled else LightlyIcons.Star, size = 20.dp, tint = if (model.starred) colors.sel else colors.ink3)
        }
        Text(
            model.name,
            style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = colors.ink, letterSpacing = (-0.01).em, lineHeight = 17.sp * 1.2f, lineHeightStyle = androidx.compose.ui.text.style.LineHeightStyle(androidx.compose.ui.text.style.LineHeightStyle.Alignment.Center, androidx.compose.ui.text.style.LineHeightStyle.Trim.None)),
            modifier = Modifier.weight(1f),
        )
        Text(model.position, style = lightlyTextStyle(13.sp, color = colors.ink3), maxLines = 1)
        Box(
            Modifier
                .heightIn(min = 44.dp)
                .graphicsLayer { alpha = if (model.presetShown) 1f else 0f }
                .clickable(enabled = model.presetShown, role = Role.Button, onClick = vm::openAmount)
                .testTagResource(EditorTags.AMOUNT)
                .padding(horizontal = 8.dp),
            contentAlignment = Alignment.Center,
        ) { Text("Amount ${model.amount}", style = lightlyTextStyle(14.sp, FontWeight.Medium, colors.sel), maxLines = 1) }
    }
}

/**
 * The Amount control as approved: `.sl` (label, a 90 dp track, the value) then Done. Dragging previews;
 * release is one undo step.
 */
@Composable
private fun AmountRow(amount: Int, vm: EditorViewModel) {
    val colors = lightlyColors
    var dragValue by remember { mutableIntStateOf(amount) }
    val shown = amount
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.heightIn(min = 44.dp).padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Amount", style = lightlyTextStyle(color = colors.ink), maxLines = 1)
            Box(
                Modifier
                    .width(90.dp)
                    .height(44.dp)
                    .pointerInput(Unit) {
                        awaitEachGesture {
                            val down = awaitFirstDown()
                            fun valueAt(x: Float) = ((x / size.width) * 100).roundToInt().coerceIn(0, 100)
                            dragValue = valueAt(down.position.x)
                            vm.onAmountDrag(dragValue)
                            while (true) {
                                val event = awaitPointerEvent()
                                val change = event.changes.first()
                                if (!change.pressed) break
                                dragValue = valueAt(change.position.x)
                                vm.onAmountDrag(dragValue)
                                change.consume()
                            }
                            vm.onAmountRelease(dragValue)
                        }
                    }
                    .semantics {
                        contentDescription = "Amount"
                        progressBarRangeInfo = ProgressBarRangeInfo(shown.toFloat(), 0f..100f, steps = 99)
                        setProgress { value -> vm.onAmountRelease(value.roundToInt()); true }
                    },
                contentAlignment = Alignment.CenterStart,
            ) {
                Canvas(Modifier.fillMaxWidth().height(18.dp)) {
                    val y = size.height / 2
                    val track = 3.dp.toPx()
                    val f = shown / 100f
                    drawRoundRect(colors.track, Offset(0f, y - track / 2), Size(size.width, track), CornerRadius(2.dp.toPx()))
                    drawRoundRect(colors.ink, Offset(0f, y - track / 2), Size(size.width * f, track), CornerRadius(2.dp.toPx()))
                    val knob = 9.dp.toPx()
                    val x = size.width * f
                    drawCircle(if (colors.isDark) colors.ink else colors.bg, knob, Offset(x, y))
                    // `.trk b { border:1.5px }` renders as 1px (Chrome floors fractional borders).
                    drawCircle(colors.ink, knob - 0.5.dp.toPx(), Offset(x, y), style = androidx.compose.ui.graphics.drawscope.Stroke(1.dp.toPx()))
                }
            }
            Text("$shown", style = lightlyTextStyle(13.sp, color = colors.ink3), modifier = Modifier.width(36.dp), textAlign = androidx.compose.ui.text.style.TextAlign.End, maxLines = 1)
        }
        QuietSmallButton("Done", vm::amountDone)
    }
}

/**
 * `.ruler`: one tick per preset stop (stop 0 is the bold first tick), longer ticks every 10, labels
 * every 50, a fixed needle. Dragging previews the stop under the needle; release (after any fling,
 * which always settles exactly on a stop) is ONE undo step. Holding still while dragging enters fine
 * mode ("Fine"), where the ruler moves at a quarter of the finger's speed. No arrows, no interpolation.
 */
@Composable
private fun Ruler(model: DevelopPanelModel, vm: EditorViewModel) {
    val colors = lightlyColors
    val density = LocalDensity.current
    val step = with(density) { 12.dp.toPx() }
    val count = model.presets.size
    val scope = rememberCoroutineScope()
    val offset = remember(model.categoryId) { Animatable(model.stop * step) }
    var dragging by remember { mutableStateOf(false) }
    var fling: Job? by remember { mutableStateOf(null) }
    val currentCount by rememberUpdatedState(count)
    LaunchedEffect(model.categoryId, model.stop, dragging) {
        if (!dragging && (fling?.isActive != true)) offset.snapTo(model.stop * step)
    }
    val measurer = rememberTextMeasurer()
    // `.tk span` 9.5px and `.fine` 11px are fixed sizes in the prototype: they do not follow the text size.
    val labelStyle = TextStyle(fontSize = com.lightlylabs.lightly.shell.fixedTextSize(9.5f), color = colors.ink3)
    val fineStyle = TextStyle(fontSize = com.lightlylabs.lightly.shell.fixedTextSize(11f), color = colors.sel, fontWeight = FontWeight.SemiBold)
    fun stopAt(value: Float) = (value / step).roundToInt().coerceIn(0, currentCount)

    Box(
        Modifier
            .fillMaxWidth()
            .height(52.dp)
            .clipToBounds() // `.rtrack` scrolls inside the panel; ticks never draw over the photo
            .testTagResource(EditorTags.RULER)
            .semantics {
                contentDescription = "Presets"
                stateDescription = model.name
                progressBarRangeInfo = ProgressBarRangeInfo(model.stop.toFloat(), 0f..count.toFloat().coerceAtLeast(1f), steps = (count - 1).coerceAtLeast(0))
                setProgress { value -> vm.onRulerRelease(value.roundToInt()); true }
            }
            .pointerInput(model.categoryId) {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    fling?.cancel()
                    dragging = true
                    val tracker = VelocityTracker()
                    tracker.addPosition(down.uptimeMillis, down.position)
                    var fine = false
                    var moved = 0f
                    var lastMoveAt = down.uptimeMillis
                    var released = false
                    while (!released) {
                        val event = withTimeoutOrNull(FINE_HOLD_MILLIS) { awaitPointerEvent() }
                        if (event == null) {
                            // Held still for a moment after starting to drag: fine mode.
                            if (!fine && moved > viewConfiguration.touchSlop) { fine = true; vm.onRulerFine(true) }
                            continue
                        }
                        val change = event.changes.first()
                        if (!change.pressed) { released = true; tracker.addPosition(change.uptimeMillis, change.position); break }
                        val dx = change.positionChange().x
                        tracker.addPosition(change.uptimeMillis, change.position)
                        if (abs(dx) > 0.5f) {
                            if (!fine && moved > viewConfiguration.touchSlop && change.uptimeMillis - lastMoveAt > FINE_HOLD_MILLIS) { fine = true; vm.onRulerFine(true) }
                            lastMoveAt = change.uptimeMillis
                        }
                        moved += abs(dx)
                        val next = (offset.value - dx * if (fine) FINE_FACTOR else 1f).coerceIn(0f, currentCount * step)
                        scope.launch { offset.snapTo(next) }
                        vm.onRulerDrag(stopAt(next))
                        change.consume()
                    }
                    val velocity = if (fine) 0f else -tracker.calculateVelocity().x
                    fling = scope.launch {
                        if (abs(velocity) > 50f) {
                            offset.animateDecay(velocity, exponentialDecay(frictionMultiplier = 2f)) {
                                val clamped = value.coerceIn(0f, currentCount * step)
                                if (clamped != value) scope.launch { offset.snapTo(clamped) }
                                vm.onRulerDrag(stopAt(clamped))
                            }
                        }
                        val target = stopAt(offset.value.coerceIn(0f, currentCount * step))
                        offset.animateTo(target * step, tween(120))
                        vm.onRulerRelease(target)
                        dragging = false
                    }
                    if (moved < 1f && abs(velocity) <= 50f) {
                        // A tap without movement changes nothing.
                        fling?.cancel()
                        vm.onRulerRelease(stopAt(offset.value))
                        dragging = false
                    }
                }
            },
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val centre = size.width / 2
            val bottom = size.height - 14.dp.toPx()
            val first = ((offset.value - centre) / step).toInt().coerceAtLeast(0) - 1
            val last = ((offset.value + centre) / step).toInt() + 1
            for (i in first.coerceAtLeast(0)..last.coerceAtMost(count)) {
                val x = centre + i * step - offset.value
                val (length, width, colour) = when {
                    i == 0 -> Triple(20.dp.toPx(), 1.5.dp.toPx(), colors.ink2)
                    i % 10 == 0 -> Triple(16.dp.toPx(), 1.dp.toPx(), colors.tickMajor)
                    else -> Triple(10.dp.toPx(), 1.dp.toPx(), colors.tick)
                }
                drawRect(colour, Offset(x - width / 2, bottom - length), Size(width, length))
                if (i % 50 == 0 && i > 0) {
                    val label = measurer.measure(i.toString(), labelStyle)
                    drawText(label, topLeft = Offset(x - label.size.width / 2f, size.height - label.size.height))
                }
            }
            // `.rfade`: the panel colour fades the ends of the track.
            drawRect(Brush.horizontalGradient(0f to colors.bg, 0.16f to colors.bg.copy(alpha = 0f), 0.84f to colors.bg.copy(alpha = 0f), 1f to colors.bg))
            val needleHeight = 30.dp.toPx()
            val needleWidth = 2.dp.toPx()
            drawRoundRect(colors.sel, Offset(centre - needleWidth / 2, size.height - 10.dp.toPx() - needleHeight), Size(needleWidth, needleHeight), CornerRadius(1.dp.toPx()))
            if (model.fine) {
                val fineText = measurer.measure("Fine", fineStyle)
                drawText(fineText, topLeft = Offset(centre - fineText.size.width / 2f, 0f))
            }
        }
    }
}

private const val FINE_HOLD_MILLIS = 450L
private const val FINE_FACTOR = 0.25f

/** Debug builds only: the panel of a tool slice 2 does not implement, clearly marked as a stub. */
@Composable
fun ToolStub(tool: EditorTool, roomy: Boolean) = Column(Modifier.fillMaxWidth()) {
    if (roomy) PanelTitle(tool.label)
    val slice = when (tool) {
        EditorTool.BACKGROUND, EditorTool.PORTRAIT -> 3
        EditorTool.EDIT, EditorTool.EFFECTS -> 4
        else -> 5
    }
    val portraitNote = if (tool == EditorTool.PORTRAIT) " Person detection is a pending dependency (D3), so debug builds offer Portrait on every photo." else ""
    Notice(
        LightlyIcons.Warn,
        buildAnnotatedString {
            withStyle(SpanStyle(color = lightlyColors.ink, fontWeight = FontWeight.SemiBold)) { append("Development stub (debug build only).") }
            append(" ${tool.label} is not implemented yet; it arrives in slice $slice.$portraitNote")
        },
    )
}
