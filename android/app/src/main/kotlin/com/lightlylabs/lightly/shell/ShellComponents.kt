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

/** `.ib`: a 44 dp square icon button. */
@Composable
fun IconTapTarget(icon: ImageVector, description: String, onClick: () -> Unit, modifier: Modifier = Modifier, tag: String? = null) {
    Box(
        modifier
            .size(44.dp)
            .clip(RoundedCornerShape(10.dp))
            .clickable(role = Role.Button, onClickLabel = null, onClick = onClick)
            .semantics { contentDescription = description }
            .then(if (tag != null) Modifier.testTagResource(tag) else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        LightlyIcon(icon, tint = lightlyColors.ink)
    }
}

/** `.topbar`: 48 dp tall, 6 dp side padding. */
@Composable
fun TopBar(modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    Row(modifier.fillMaxWidth().height(48.dp).padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp), content = content)
}

enum class ButtonKind { PRIMARY, LINE, QUIET }

/**
 * `.btn` (min height 44, radius 10, weight 600) in its three approved kinds. [minHeight] and
 * [fontSize] follow the Welcome overrides (52 dp, 16 sp, radius 12) where used.
 */
@Composable
fun LightlyButton(
    text: String,
    kind: ButtonKind,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    minHeight: androidx.compose.ui.unit.Dp = 44.dp,
    fontSize: TextUnit = 15.sp,
    cornerRadius: androidx.compose.ui.unit.Dp = 10.dp,
    underline: Boolean = false,
    tag: String? = null,
) {
    val colors = lightlyColors
    val shape = RoundedCornerShape(cornerRadius)
    val (background, foreground) = when (kind) {
        ButtonKind.PRIMARY -> colors.ink to colors.bg
        ButtonKind.LINE -> Color.Transparent to colors.ink
        ButtonKind.QUIET -> Color.Transparent to colors.sel
    }
    Row(
        modifier
            .heightIn(min = minHeight)
            .clip(shape)
            .background(background, shape)
            .then(if (kind == ButtonKind.LINE) Modifier.border(1.dp, colors.hair, shape) else Modifier)
            .clickable(role = Role.Button, onClick = onClick)
            .then(if (tag != null) Modifier.testTagResource(tag) else Modifier)
            .padding(horizontal = if (kind == ButtonKind.QUIET) 12.dp else 18.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CompositionLocalProvider(LocalContentColor provides foreground) {
            if (icon != null) LightlyIcon(icon, size = 20.dp, tint = foreground)
            Text(
                text,
                style = lightlyTextStyle(fontSize, FontWeight.SemiBold, foreground).copy(textDecoration = if (underline) TextDecoration.Underline else null),
                maxLines = 2,
            )
        }
    }
}

/** `.page .head`: back or close, then the centred title (17 sp, 600). */
@Composable
fun PageHead(title: String, navigationIcon: ImageVector, navigationDescription: String, onNavigation: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        IconTapTarget(navigationIcon, navigationDescription, onNavigation, tag = "page-navigation")
        Text(
            title,
            style = lightlyTextStyle(17.sp, FontWeight.SemiBold, lightlyColors.ink),
            textAlign = TextAlign.Center,
            modifier = Modifier.weight(1f).padding(end = 44.dp).semantics { heading() },
        )
    }
}

/** `.group`: small uppercase section label. */
@Composable
fun GroupLabel(text: String) {
    Text(
        text.uppercase(),
        style = lightlyTextStyle(12.5.sp, color = lightlyColors.ink3).copy(letterSpacing = 0.04.em),
        modifier = Modifier.padding(start = 18.dp, end = 18.dp, top = 14.dp, bottom = 4.dp).semantics { heading() },
    )
}

/** `.note`: 13 sp secondary text. */
@Composable
fun Note(text: String, modifier: Modifier = Modifier) {
    Text(text, style = lightlyTextStyle(13.sp, color = lightlyColors.ink3), modifier = modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 6.dp))
}

/** Bottom hairline of a `.listrow`. */
internal fun Modifier.hairlineBelow(color: Color) = drawBehind {
    drawLine(color, Offset(0f, size.height - 0.5.dp.toPx()), Offset(size.width, size.height - 0.5.dp.toPx()), strokeWidth = 1.dp.toPx())
}

/**
 * `.listrow`: min 52 dp, 18 dp padding, hairline below. [onClick] null renders a static row;
 * [enabled] false greys it and removes the action (used for slice-5 rows that exist but do nothing yet).
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
    trailing: @Composable (RowScope.() -> Unit)? = { LightlyIcon(LightlyIcons.Chevron, size = 18.dp, tint = lightlyColors.ink3) },
) {
    val colors = lightlyColors
    val ink = if (!enabled) colors.ink3 else if (labelColor != Color.Unspecified) labelColor else colors.ink
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .hairlineBelow(colors.hair)
            .then(if (onClick != null && enabled) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .then(if (tag != null) Modifier.testTagResource(tag) else Modifier)
            .padding(horizontal = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // No vertical padding: `.listrow` is min-height 52 with the text centred (prototype).
        Column(Modifier.weight(1f)) {
            Text(label, style = lightlyTextStyle(color = ink))
            if (sub != null) Text(sub, style = lightlyTextStyle(13.sp, color = colors.ink3))
        }
        if (trailing != null && enabled) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp), content = trailing)
    }
}

/** `.seg`: the segmented control (Appearance). Each segment is a radio for accessibility. */
@Composable
fun <T> SegmentedControl(
    options: List<Pair<T, String>>,
    selected: T,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
    icons: Map<T, ImageVector> = emptyMap(),
    marginTop: Dp = 8.dp,
    marginBottom: Dp = 4.dp,
) {
    val colors = lightlyColors
    Row(
        modifier
            // `.seg { margin: 8px 18px 4px }`. Vertical CSS margins collapse with a neighbour's, so a caller
            // whose neighbour already provides margin passes the remainder (see PreferencesBody).
            .padding(start = 18.dp, end = 18.dp, top = marginTop, bottom = marginBottom)
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(colors.bg2)
            .border(1.dp, colors.hair, RoundedCornerShape(10.dp))
            // The 1px CSS border takes layout space (Compose's border does not), then `padding: 2px`.
            .padding(1.dp + 2.dp),
    ) {
        options.forEach { (value, label) ->
            val on = value == selected
            Box(
                Modifier
                    .weight(1f)
                    .heightIn(min = 44.dp)
                    .then(if (on) Modifier.shadow(1.dp, RoundedCornerShape(8.dp)).background(colors.segmentOn, RoundedCornerShape(8.dp)) else Modifier)
                    .clip(RoundedCornerShape(8.dp))
                    .selectable(selected = on, role = Role.RadioButton, onClick = { onSelect(value) })
                    .testTagResource("segment-$label"),
                contentAlignment = Alignment.Center,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    icons[value]?.let { LightlyIcon(it, size = 16.dp, tint = if (on) colors.ink else colors.ink2); Spacer(Modifier.size(4.dp)) }
                    // One line up to the approved large text (font scale 1.24); beyond it the label wraps, centred, instead of
                    // being cut ("Change" for "Change background" at font scale 2.0; A11, 2026-10-07).
                    val wraps = androidx.compose.ui.platform.LocalDensity.current.fontScale > 1.24f
                    Text(label, style = lightlyTextStyle(14.sp, FontWeight.Medium, if (on) colors.ink else colors.ink2),
                        maxLines = if (wraps) Int.MAX_VALUE else 1, textAlign = if (wraps) androidx.compose.ui.text.style.TextAlign.Center else null)
                }
            }
        }
    }
}

/** `.toggle`: 46×28 track, 22 dp knob. Drawn to match the approved switch; semantics are a Switch. */
@Composable
fun ToggleKnob(on: Boolean) {
    val colors = lightlyColors
    Box(
        Modifier.size(width = 46.dp, height = 28.dp).clip(RoundedCornerShape(14.dp)).background(if (on) colors.sel else colors.track),
    ) {
        Box(
            Modifier
                .offset(x = if (on) 21.dp else 3.dp, y = 3.dp)
                .size(22.dp)
                .shadow(1.dp, CircleShape)
                .background(Color.White, CircleShape),
        )
    }
}

/** A switch row (`.listrow.export-pref`): label, explanation, approved toggle. The whole row toggles. */
@Composable
fun SwitchRow(label: String, sub: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit, tag: String) {
    val colors = lightlyColors
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .hairlineBelow(colors.hair)
            .toggleable(value = checked, role = Role.Switch, onValueChange = onCheckedChange)
            .testTagResource(tag)
            .padding(horizontal = 18.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(label, style = lightlyTextStyle(color = colors.ink))
            Text(sub, style = lightlyTextStyle(13.sp, color = colors.ink3))
        }
        ToggleKnob(checked)
    }
}

/** `.grab`: the sheet handle. */
@Composable
fun SheetGrabber() {
    Box(Modifier.fillMaxWidth().padding(top = 2.dp, bottom = 8.dp), contentAlignment = Alignment.Center) {
        Box(Modifier.size(width = 36.dp, height = 5.dp).clip(RoundedCornerShape(3.dp)).background(lightlyColors.hair))
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
