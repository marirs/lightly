package com.lightlylabs.lightly.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp

/*
 * Shared pieces of the slice-1 screens, sized from docs/ui/app/styles.css (1 CSS px = 1 dp, font px =
 * sp so Android's text size setting scales them). Touch targets are at least 44 dp as approved;
 * Material components that require 48 dp keep it.
 */

/** Body text in the approved scale: 15 sp, line height 1.35. */
// CSS line boxes (`font: 15px/1.35`): the half-leading sits equally above and below the glyphs and is
// never trimmed. Compose's default LineHeightStyle trims the first and last line, which made stacked
// labels (a row's title and its sub-label) about 2 dp closer than the approved layout.
private val cssLineBox = androidx.compose.ui.text.style.LineHeightStyle(
    alignment = androidx.compose.ui.text.style.LineHeightStyle.Alignment.Center,
    trim = androidx.compose.ui.text.style.LineHeightStyle.Trim.None,
)

/**
 * A prototype font size written as plain px (no `calc(… * var(--ts))`): the approved design keeps it
 * the same at every system text size (the progress box, the photo badge, the ruler labels), so it is
 * converted from dp and does not follow the font scale.
 */
@Composable
fun fixedTextSize(px: Float): TextUnit = with(androidx.compose.ui.platform.LocalDensity.current) { px.dp.toSp() }

fun lightlyTextStyle(size: TextUnit = 15.sp, weight: FontWeight = FontWeight.Normal, color: Color = Color.Unspecified) =
    TextStyle(fontSize = size, fontWeight = weight, color = color, lineHeight = size * 1.35f, lineHeightStyle = cssLineBox)

/**
 * Lightly 2 text: the system font at [size] (CSS px as sp), [weight]; normal line height unless [lineHeight] (a multiple
 * of the size) is given, as the mockup sets it.
 */
fun l2TextStyle(size: TextUnit, weight: FontWeight = FontWeight.Normal, color: Color = Color.Unspecified, lineHeight: Float? = null, tracking: TextUnit = TextUnit.Unspecified) =
    TextStyle(fontSize = size, fontWeight = weight, color = color, letterSpacing = tracking,
        lineHeight = lineHeight?.let { size * it } ?: TextUnit.Unspecified, lineHeightStyle = if (lineHeight != null) cssLineBox else null)

/** `iconBtn`: a 44 dp circle; plain (ink), [glass] (glass fill and line) or [on] (ink fill, on-ink icon). */
@Composable
fun IconTapTarget(
    icon: ImageVector, description: String, onClick: () -> Unit, modifier: Modifier = Modifier, tag: String? = null,
    glass: Boolean = false, on: Boolean = false, enabled: Boolean = true,
) {
    val colors = lightlyColors
    Box(
        modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(if (on) colors.segmentOn else if (glass) colors.glass else Color.Transparent, CircleShape)
            .then(if (glass && !on) Modifier.border(1.dp, colors.glassLine, CircleShape) else Modifier)
            .clickable(enabled = enabled, role = Role.Button, onClickLabel = null, onClick = onClick)
            .semantics { contentDescription = description }
            .then(if (tag != null) Modifier.testTagResource(tag) else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        LightlyIcon(icon, size = 20.dp, tint = (if (on) colors.onInk else if (glass) colors.glassInk else colors.ink).copy(alpha = if (enabled) 1f else 0.38f))
    }
}

/** `moreBtn`: ⋮ on a lime 44 dp circle with the 1 dp lime rim. */
@Composable
fun MoreButton(onClick: () -> Unit, modifier: Modifier = Modifier, tag: String = "editor-more") {
    val colors = lightlyColors
    Box(
        modifier.size(44.dp).clip(CircleShape).background(colors.accent, CircleShape).border(1.dp, colors.accentEdge, CircleShape)
            .clickable(role = Role.Button, onClick = onClick).semantics { contentDescription = "More" }.testTagResource(tag),
        contentAlignment = Alignment.Center,
    ) { LightlyIcon(LightlyIcons.More, size = 20.dp, tint = colors.onAccent) }
}

/** `saveBtn`: "Save", a lime capsule ([height] 44 dp, 40 on the Android app bar), 16 dp padding, 14 sp bold, rim. */
@Composable
fun SaveButton(onClick: () -> Unit, modifier: Modifier = Modifier, height: Dp = 44.dp) {
    val colors = lightlyColors
    Box(
        modifier.height(height).clip(RoundedCornerShape(50)).background(colors.accent).border(1.dp, colors.accentEdge, RoundedCornerShape(50))
            .clickable(role = Role.Button, onClick = onClick).testTagResource("editor-save").padding(horizontal = 16.dp),
        contentAlignment = Alignment.Center,
    ) { Text("Save", style = l2TextStyle(14.sp, FontWeight.Bold, colors.onAccent), maxLines = 1) }
}

/** `.topbar`: 48 dp tall, 6 dp side padding. */
@Composable
fun TopBar(modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    Row(modifier.fillMaxWidth().height(48.dp).padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp), content = content)
}

enum class ButtonKind { PRIMARY, LINE, QUIET }

/**
 * Lightly 2 buttons: PRIMARY (`primary`: lime capsule with the rim, 15 sp bold, [minHeight] 52/56), LINE (`lineBtn`:
 * outlined capsule, 15 sp semibold), QUIET (`quietBtn`: a chip-filled 38 dp capsule, 13 sp semibold; [accent] text).
 */
@Composable
fun LightlyButton(
    text: String,
    kind: ButtonKind,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    minHeight: androidx.compose.ui.unit.Dp = if (kind == ButtonKind.QUIET) 38.dp else 52.dp,
    fontSize: TextUnit = if (kind == ButtonKind.QUIET) 13.sp else 15.sp,
    cornerRadius: androidx.compose.ui.unit.Dp = 0.dp,
    underline: Boolean = false,
    tag: String? = null,
    accent: Boolean = false,
    dimmed: Boolean = false,
    fillsWidth: Boolean = kind != ButtonKind.QUIET,
) {
    val colors = lightlyColors
    val shape = RoundedCornerShape(50)
    val (background, foreground) = when (kind) {
        ButtonKind.PRIMARY -> colors.accent to colors.onAccent
        ButtonKind.LINE -> Color.Transparent to colors.ink
        ButtonKind.QUIET -> colors.chip to (if (accent) colors.sel else colors.ink)
    }
    Row(
        modifier
            .then(if (fillsWidth) Modifier.fillMaxWidth() else Modifier)
            .heightIn(min = minHeight)
            .clip(shape)
            .background(background, shape)
            .then(when (kind) {
                ButtonKind.PRIMARY -> Modifier.border(1.dp, colors.accentEdge, shape)
                ButtonKind.LINE -> Modifier.border(1.dp, colors.hair, shape)
                else -> Modifier
            })
            .clickable(role = Role.Button, onClick = onClick)
            .then(if (tag != null) Modifier.testTagResource(tag) else Modifier)
            .padding(horizontal = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(if (kind == ButtonKind.QUIET) 6.dp else 10.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val fg = foreground.copy(alpha = if (dimmed) 0.4f else 1f)
        CompositionLocalProvider(LocalContentColor provides fg) {
            if (icon != null) LightlyIcon(icon, size = if (kind == ButtonKind.QUIET) 16.dp else 20.dp, tint = fg)
            Text(
                text,
                style = l2TextStyle(fontSize, if (kind == ButtonKind.PRIMARY) FontWeight.Bold else FontWeight.SemiBold, fg)
                    .copy(textDecoration = if (underline) TextDecoration.Underline else null),
                maxLines = 2,
            )
        }
    }
}

/** `linkBtn`: accent text, 13 sp bold, optional 15 dp icon (leading, or trailing for "More colours ›"). */
@Composable
fun LinkButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null, iconTrailing: Boolean = false, tag: String? = null) {
    val colors = lightlyColors
    Row(
        modifier.heightIn(min = 34.dp).clip(RoundedCornerShape(8.dp)).clickable(role = Role.Button, onClick = onClick)
            .then(if (tag != null) Modifier.testTagResource(tag) else Modifier).padding(horizontal = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null && !iconTrailing) LightlyIcon(icon, size = 15.dp, tint = colors.sel)
        Text(text, style = l2TextStyle(13.sp, FontWeight.Bold, colors.sel), maxLines = 1)
        if (icon != null && iconTrailing) LightlyIcon(icon, size = 15.dp, tint = colors.sel)
    }
}

/**
 * Lightly 2 page header (`morePage`): on the first page "More" (30 sp heading, −0.6 sp tracking, 6 dp in) and a 44 dp
 * chip-filled Close; on other pages Back and the title (22 sp heading).
 */
@Composable
fun PageHead(title: String, navigationIcon: ImageVector, navigationDescription: String, onNavigation: () -> Unit, root: Boolean = false) {
    val colors = lightlyColors
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        if (root) {
            Text(title, style = l2TextStyle(30.sp, FontWeight.SemiBold, colors.ink, tracking = (-0.6).sp),
                modifier = Modifier.weight(1f).padding(start = 6.dp).semantics { heading() })
            Box(
                Modifier.size(44.dp).clip(CircleShape).background(colors.chip).clickable(role = Role.Button, onClick = onNavigation)
                    .semantics { contentDescription = navigationDescription }.testTagResource("page-navigation"),
                contentAlignment = Alignment.Center,
            ) { LightlyIcon(LightlyIcons.Close, size = 20.dp, tint = colors.ink) }
        } else {
            IconTapTarget(LightlyIcons.BackChevron, navigationDescription, onNavigation, tag = "page-navigation")
            Text(title, style = l2TextStyle(22.sp, FontWeight.SemiBold, colors.ink), modifier = Modifier.weight(1f).semantics { heading() })
        }
    }
}

/** `groupLabel`: 11 sp bold, 0.8 sp tracking, ink2, upper case, 6 dp sides, 7 dp below. */
@Composable
fun GroupLabel(text: String) {
    Text(
        text.uppercase(),
        style = l2TextStyle(11.sp, FontWeight.Bold, lightlyColors.ink2, tracking = 0.8.sp),
        modifier = Modifier.padding(start = 6.dp, end = 6.dp, bottom = 7.dp).semantics { heading() },
    )
}

/** `note`: 12.5 sp ink2, line height 1.4. Spacing comes from the column it is in. */
@Composable
fun Note(text: String, modifier: Modifier = Modifier) {
    Text(text, style = l2TextStyle(12.5.sp, color = lightlyColors.ink2, lineHeight = 1.4f), modifier = modifier.fillMaxWidth())
}

/** A hairline above (Lightly 2 rows in a card divide from the row before). */
internal fun Modifier.hairlineAbove(color: Color) = drawBehind {
    drawLine(color, Offset(0f, 0.5.dp.toPx()), Offset(size.width, 0.5.dp.toPx()), strokeWidth = 1.dp.toPx())
}

internal fun Modifier.hairlineBelow(color: Color) = drawBehind {
    drawLine(color, Offset(0f, size.height - 0.5.dp.toPx()), Offset(size.width, size.height - 0.5.dp.toPx()), strokeWidth = 1.dp.toPx())
}

/** `card`: 22 dp corners, surface fill, hairline border. */
@Composable
fun L2Card(modifier: Modifier = Modifier, padding: androidx.compose.foundation.layout.PaddingValues = androidx.compose.foundation.layout.PaddingValues(0.dp), content: @Composable () -> Unit) {
    val colors = lightlyColors
    val shape = RoundedCornerShape(22.dp)
    Column(modifier.fillMaxWidth().clip(shape).background(colors.surface, shape).border(1.dp, colors.hair, shape).padding(padding)) { content() }
}

/**
 * `listRow`: 54 dp minimum, 8/16 dp padding, 12 dp gap; 15 sp semibold title, 12 sp ink2 sub-line; trailing ink3;
 * a hairline above every row but the first ([first]).
 */
@Composable
fun ListRow(
    label: String,
    modifier: Modifier = Modifier,
    sub: String? = null,
    onClick: (() -> Unit)? = null,
    enabled: Boolean = true,
    labelColor: Color = Color.Unspecified,
    tag: String? = null,
    first: Boolean = false,
    trailing: @Composable (RowScope.() -> Unit)? = { LightlyIcon(LightlyIcons.Chevron, size = 18.dp, tint = lightlyColors.ink3) },
) {
    val colors = lightlyColors
    val ink = if (!enabled) colors.ink3 else if (labelColor != Color.Unspecified) labelColor else colors.ink
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = 54.dp)
            .then(if (first) Modifier else Modifier.hairlineAbove(colors.hair))
            .then(if (onClick != null && enabled) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .then(if (tag != null) Modifier.testTagResource(tag) else Modifier)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = l2TextStyle(15.sp, FontWeight.SemiBold, ink))
            if (sub != null) Text(sub, style = l2TextStyle(12.sp, color = colors.ink2))
        }
        if (trailing != null && enabled) {
            CompositionLocalProvider(LocalContentColor provides colors.ink3) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp), content = trailing)
            }
        }
    }
}

/**
 * `seg`: 4 dp padding on a chip-filled 22 dp capsule, 4 dp gaps; 36 dp segments; selected on an ink fill with on-ink
 * text, bold. Each segment is a radio for accessibility.
 */
@Composable
fun <T> SegmentedControl(
    options: List<Pair<T, String>>,
    selected: T,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
    icons: Map<T, ImageVector> = emptyMap(),
    marginTop: Dp = 0.dp,
    marginBottom: Dp = 0.dp,
) {
    val colors = lightlyColors
    Row(
        modifier
            .padding(top = marginTop, bottom = marginBottom)
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(colors.chip)
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        options.forEach { (value, label) ->
            val on = value == selected
            Box(
                Modifier
                    .weight(1f)
                    .height(36.dp)
                    .clip(RoundedCornerShape(18.dp))
                    .background(if (on) colors.segmentOn else Color.Transparent)
                    .selectable(selected = on, role = Role.RadioButton, onClick = { onSelect(value) })
                    .testTagResource("segment-$label"),
                contentAlignment = Alignment.Center,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    icons[value]?.let { LightlyIcon(it, size = 16.dp, tint = if (on) colors.onInk else colors.ink2) }
                    Text(label, style = l2TextStyle(14.sp, if (on) FontWeight.Bold else FontWeight.SemiBold, if (on) colors.onInk else colors.ink2), maxLines = 1)
                }
            }
        }
    }
}

/** `toggle`: a 50×30 track (accent when on, `--off` when off) with a 26 dp knob. Semantics are a Switch. */
@Composable
fun ToggleKnob(on: Boolean) {
    val colors = lightlyColors
    Box(Modifier.size(width = 50.dp, height = 30.dp).clip(RoundedCornerShape(15.dp)).background(if (on) colors.accent else colors.track)) {
        Box(Modifier.offset(x = if (on) 22.dp else 2.dp, y = 2.dp).size(26.dp).shadow(2.dp, CircleShape).background(colors.knob, CircleShape))
    }
}

/** `toggleRow` in a card: 14 sp semibold title, 12 sp ink2 sub-line, the switch; 16 dp sides, a hairline above. */
@Composable
fun SwitchRow(label: String, sub: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit, tag: String) {
    val colors = lightlyColors
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .hairlineAbove(colors.hair)
            .toggleable(value = checked, role = Role.Switch, onValueChange = onCheckedChange)
            .testTagResource(tag)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(label, style = l2TextStyle(14.sp, FontWeight.SemiBold, colors.ink))
            Text(sub, style = l2TextStyle(12.sp, color = colors.ink2))
        }
        ToggleKnob(checked)
    }
}

/** The sheet handle: 40×5, `--off`, 8 dp above and 4 dp below. */
@Composable
fun SheetGrabber() {
    Box(Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 4.dp), contentAlignment = Alignment.Center) {
        Box(Modifier.size(width = 40.dp, height = 5.dp).clip(RoundedCornerShape(3.dp)).background(lightlyColors.track))
    }
}

/** Fixed-height spacer shorthand. */
@Composable
fun VSpace(height: androidx.compose.ui.unit.Dp) = Spacer(Modifier.height(height))

/** Width-capped column used by Welcome's actions (`max-width:420px; padding:0 20px`). */
@Composable
fun CappedColumn(maxWidth: androidx.compose.ui.unit.Dp, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Column(modifier.widthIn(max = maxWidth).fillMaxWidth()) { content() }
}

/**
 * Test tag that the root's `testTagsAsResourceId` also exposes as a resource id, so the Robolectric
 * tests and the scripted emulator comparison (uiautomator) find the same controls.
 */
fun Modifier.testTagResource(tag: String): Modifier = this.testTag(tag)
