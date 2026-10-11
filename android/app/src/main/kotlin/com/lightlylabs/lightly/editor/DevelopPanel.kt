package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.shell.l2TextStyle

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.calculateTargetValue
import androidx.compose.animation.core.exponentialDecay
import androidx.compose.animation.core.tween
import androidx.compose.foundation.gestures.detectVerticalDragGestures
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
import androidx.compose.runtime.mutableStateMapOf
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
import androidx.compose.foundation.layout.Spacer
import androidx.compose.ui.graphics.StrokeCap

/**
 * The Lightly 2 Develop panel (`developPanel`), 6 dp between rows: the grab handle (compact), the category tabs (orange
 * underline on the browsed one, orange dot on the one holding the applied preset, Favourites with its star), a notice
 * when one applies, the heading (star, the preset's name, Reset), the preset gallery and Amount.
 */
@Composable
fun DevelopPanel(vm: EditorViewModel, model: DevelopPanelModel, roomy: Boolean, wrapped: Boolean, expanded: Boolean = false) =
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
    val colors = lightlyColors
    if (!expanded) Box(Modifier.fillMaxWidth().height(20.dp).padding(bottom = 14.dp).pointerInput(Unit) {
        var distance = 0f
        detectVerticalDragGestures(onDragStart = { distance = 0f }) { change, dy ->
            distance += dy
            if (distance < -24.dp.toPx()) { change.consume(); vm.setPresetExpanded(true) }
        }
    }.semantics { contentDescription = "Preset browser" }, contentAlignment = Alignment.TopCenter) {
        Box(Modifier.width(36.dp).height(4.dp).background(colors.track, CircleShape))
    }
    OptionTabs(
        model.categories.map { it.id to it.label }, model.categoryId, vm::selectCategory,
        dotted = { id -> model.categories.firstOrNull { it.id == id }?.dotted == true },
        tagPrefix = "develop-category", underline = true,
        icon = { id -> if (model.categories.firstOrNull { it.id == id }?.isFavourites == true) LightlyIcons.Star else null },
    )
    model.notice?.let { DevelopNoticeView(it, vm) }
    // `heading`: the star (30×36, 20 dp; accent when a favourite, ink3 otherwise, faint without a preset), the name
    // (17 sp heading, one line), and "Reset" when a preset is applied; 8 dp gaps, 36 dp tall.
    val applied = vm.uiState.value.session?.current?.look != null
    Row(Modifier.fillMaxWidth().heightIn(min = 36.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(
            Modifier.size(width = 30.dp, height = 36.dp).clickable(enabled = model.presetShown, role = Role.Button, onClick = vm::toggleStar)
                .semantics { contentDescription = "Favourite"; selected = model.starred }.testTagResource("develop-star"),
            contentAlignment = Alignment.Center,
        ) {
            LightlyIcon(if (model.starred) LightlyIcons.StarFilled else LightlyIcons.Star, size = 20.dp,
                tint = (if (model.starred) colors.sel else colors.ink3).copy(alpha = if (model.presetShown) 1f else 0.35f))
        }
        Text(model.name.ifEmpty { "Original" }, style = l2TextStyle(17.sp, FontWeight.SemiBold, colors.ink), maxLines = 1,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, modifier = Modifier.weight(1f).testTagResource("develop-name"))
        if (applied) com.lightlylabs.lightly.shell.LinkButton("Reset", vm::clearPreset, icon = LightlyIcons.Reset, tag = "develop-clear")
    }
    PresetGallery(vm, model, expanded || roomy)
    SliderRow("Amount", model.amount.toDouble(), 0.0, 100.0, onDrag = { vm.onAmountDrag(it.toInt()) }, onRelease = { vm.onAmountRelease(it.toInt()) },
        tag = "develop-amount-slider", enabled = applied)
}

@Composable
private fun TabLabel(entry: CategoryEntry) {
    val colors = lightlyColors
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        if (entry.isFavourites) LightlyIcon(LightlyIcons.Star, size = 15.dp, tint = if (entry.selected) colors.ink else colors.ink2)
        BrowsedLabel(entry)
        if (entry.dotted) Box(Modifier.padding(start = 3.dp).size(5.dp).background(colors.browse, CircleShape))
    }
}

/**
 * The category name with the browsed category's 2 dp orange underline, 6 dp below the text and as wide as it (owner
 * amendment 2026-10-05). A shape, not only a colour: browsing and the applied dot differ without relying on colour.
 */
@Composable
private fun BrowsedLabel(entry: CategoryEntry, modifier: Modifier = Modifier) {
    val colors = lightlyColors
    Text(
        entry.label,
        style = lightlyTextStyle(15.sp, if (entry.selected) FontWeight.SemiBold else FontWeight.Normal, if (entry.selected) colors.ink else colors.ink2),
        maxLines = 1,
        modifier = modifier.drawBehind {
            if (entry.selected) {
                val y = size.height + 6.dp.toPx() - 1.dp.toPx()
                drawLine(colors.browse, Offset(0f, y), Offset(size.width, y), strokeWidth = 2.dp.toPx(), cap = StrokeCap.Round)
            }
        },
    )
}

private fun Modifier.tab(entry: CategoryEntry, onSelect: (String) -> Unit) = this
    .heightIn(min = 44.dp)
    .clickable(role = Role.Tab) { onSelect(entry.id) }
    .semantics {
        selected = entry.selected
        if (entry.dotted) stateDescription = "Contains the applied preset"
    }
    .testTagResource(EditorTags.category(entry.id))

/** `.tabs` on phones: one scrolling row, faded at both ends; the selected tab is scrolled to 120 dp in. */
@Composable
private fun ScrollingTabs(model: DevelopPanelModel, onSelect: (String) -> Unit, modifier: Modifier) {
    val scroll = rememberScrollState()
    // Each tab's left edge within the scrolling row (px, padding included).
    val tabStarts = remember { mutableStateMapOf<String, Float>() }
    // Owner amendment 2026-10-05 (as iOS): the tab before the selected one starts 18 dp in, fully visible past the 16 dp
    // fade; replaces the prototype's "selected tab 120 dp in", which left the previous tab half hidden beside Auto.
    LaunchedEffect(model.categoryId, tabStarts.size, scroll.maxValue) {
        val ids = model.categories.map { it.id }
        val index = ids.indexOf(model.categoryId).takeIf { it >= 0 } ?: return@LaunchedEffect
        val previous = tabStarts[ids[maxOf(index - 1, 0)]] ?: return@LaunchedEffect
        // positionInParent is measured inside the row's 18 dp start padding, so scrolling to it puts the previous tab's
        // leading edge at that padding, past the 16 dp fade (checked on the emulator, 2026-10-05).
        val target = previous.roundToInt().coerceIn(0, scroll.maxValue)
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
            // 18 dp: the first tab starts past the 16 dp edge fade, so Favourites is not half hidden beside Auto
            // (owner feedback 2026-10-05); the fade still hints that the row scrolls.
            .padding(start = 18.dp, end = 18.dp),
        horizontalArrangement = Arrangement.spacedBy(20.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        model.categories.forEach { entry ->
            Box(
                Modifier.tab(entry, onSelect).onGloballyPositioned { tabStarts[entry.id] = it.positionInParent().x },
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
                BrowsedLabel(entry)
                if (entry.dotted) Box(Modifier.padding(start = 6.dp).size(5.dp).background(colors.browse, CircleShape))
                Spacer(Modifier.weight(1f))
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
        DevelopNotice.FavouritesFull -> Notice(
            LightlyIcons.Star,
            bold("Favourites holds ten presets.", " Remove one in Preferences, or replace one now."),
            listOf("Replace…" to vm::openFavouriteReplace, "Not now" to vm::dismiss),
        )
    }
}

@Composable
private fun bold(head: String, rest: String) = buildAnnotatedString {
    withStyle(SpanStyle(color = lightlyColors.ink, fontWeight = FontWeight.Bold)) { append(head) }
    append(rest)
}

/**
 * A panel notice (Lightly 2 `notice`): an 18 dp icon (accent; danger for warnings), 13 sp text (line height 1.4) with a
 * bold lead, quiet actions 8 dp apart; 12/14 dp padding, 18 dp corners, card fill, hairline.
 */
@Composable
internal fun Notice(icon: androidx.compose.ui.graphics.vector.ImageVector, text: AnnotatedString, actions: List<Pair<String, () -> Unit>> = emptyList()) {
    val colors = lightlyColors
    val shape = RoundedCornerShape(18.dp)
    Row(
        Modifier.fillMaxWidth().clip(shape).background(colors.bg2).border(1.dp, colors.hair, shape).padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        LightlyIcon(icon, size = 18.dp, tint = if (icon == LightlyIcons.Warn) colors.danger else colors.sel, modifier = Modifier.padding(top = 1.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(text, style = l2TextStyle(13.sp, color = colors.ink, lineHeight = 1.4f))
            if (actions.isNotEmpty()) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) { actions.forEach { (label, action) -> QuietSmallButton(label, action) } }
            }
        }
    }
}

/** `quietBtn`: a chip-filled capsule ([height] 38 dp), 14 dp padding, 13 sp semibold ink (accent when [accent]); an optional 16 dp icon. */
@Composable
internal fun QuietSmallButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: androidx.compose.ui.graphics.vector.ImageVector? = null,
    large: Boolean = false, accent: Boolean = false, height: androidx.compose.ui.unit.Dp = 38.dp, dimmed: Boolean = false) {
    val colors = lightlyColors
    val ink = (if (accent) colors.sel else colors.ink).copy(alpha = if (dimmed) 0.4f else 1f)
    Row(
        modifier.height(height).clip(RoundedCornerShape(50)).background(colors.chip).clickable(role = Role.Button, onClick = onClick).padding(horizontal = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) LightlyIcon(icon, size = 16.dp, tint = ink)
        Text(label, style = l2TextStyle(13.sp, FontWeight.SemiBold, ink), maxLines = 1)
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
        if (vm.uiState.value.develop.startsAtFirst && model.presetShown) {
            QuietSmallButton("Apply", vm::applyBrowsedPreset, Modifier.testTagResource("develop-apply"))
        } else {
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
        if (vm.uiState.value.session?.current?.look != null) {
            QuietSmallButton("Reset", vm::clearPreset,
                Modifier.semantics { contentDescription = "Reset preset" }.testTagResource("develop-clear"), icon = LightlyIcons.RotateLeft)
        }
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
                        stateDescription = "$shown"
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
                // As iOS: the preset's name and its place in the category.
                stateDescription = "${model.name}, ${model.stop} of $count"
                progressBarRangeInfo = ProgressBarRangeInfo(model.stop.toFloat(), 0f..count.toFloat().coerceAtLeast(1f), steps = (count - 1).coerceAtLeast(0))
                // An accessibility step is a drag to the stop and a release there: one committed step.
                setProgress { value -> vm.onRulerDrag(value.roundToInt()); vm.onRulerRelease(value.roundToInt()); true }
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
                    // Reduced animations (Remove animations / animator duration scale 0): the fling still travels as
                    // far, but the ruler jumps there and lands on its stop without the snap animation (as iOS).
                    val reduceMotion = reducedMotion()
                    fling = scope.launch {
                        if (abs(velocity) > 50f && reduceMotion) {
                            val landed = exponentialDecay<Float>(frictionMultiplier = 2f).calculateTargetValue(offset.value, velocity).coerceIn(0f, currentCount * step)
                            offset.snapTo(landed)
                            vm.onRulerDrag(stopAt(landed))
                        } else if (abs(velocity) > 50f) {
                            // Bounds stop the decay at either end. (Snapping inside the decay block cancelled this
                            // coroutine at the ends, so the release never came and the header stayed in drag state.)
                            offset.updateBounds(0f, currentCount * step)
                            offset.animateDecay(velocity, exponentialDecay(frictionMultiplier = 2f)) {
                                vm.onRulerDrag(stopAt(value.coerceIn(0f, currentCount * step)))
                            }
                        }
                        val target = stopAt(offset.value.coerceIn(0f, currentCount * step))
                        if (reduceMotion) offset.snapTo(target * step) else offset.animateTo(target * step, tween(120))
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

/**
 * True when the system asks for no animations: Accessibility › Remove animations, or the developer option
 * "Animator duration scale" off; both set the animator duration scale to 0, which disables animators.
 */
internal fun reducedMotion(): Boolean = !android.animation.ValueAnimator.areAnimatorsEnabled()
