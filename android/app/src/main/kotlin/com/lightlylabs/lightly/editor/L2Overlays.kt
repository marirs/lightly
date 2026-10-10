package com.lightlylabs.lightly.editor

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.min
import androidx.compose.ui.unit.sp
import com.lightlylabs.lightly.shell.SheetGrabber
import com.lightlylabs.lightly.shell.l2TextStyle
import com.lightlylabs.lightly.shell.lightlyColors
import com.lightlylabs.lightly.shell.testTagResource

// Lightly 2 overlays (docs/ui/directions/lightly-2-concept/index.html: dialog, actionSheet, sheetOverlay, sheetHead).

/** One dialog action. [destructive] draws it in the danger colour. */
data class L2DialogButton(val label: String, val tag: String, val destructive: Boolean = false, val action: () -> Unit)

/**
 * The Android dialog (`dialog`, `.md`): over the scrim, a 312 dp card (28 dp corners, sheet fill, shadow) with 22/22/14
 * dp padding and 14 dp between: the title (20 sp heading), the message (14 sp ink2, line height 1.45), then the actions
 * right-aligned, 4 dp apart: 40 dp capsules, 12 dp padding, 14 sp bold, accent (danger for destructive ones).
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun L2Dialog(title: String, body: String?, buttons: List<L2DialogButton>, onDismiss: () -> Unit) {
    val colors = lightlyColors
    BackHandler(onBack = onDismiss)
    Box(
        // The scrim swallows taps without `clickable`: a clickable parent merges its descendants' semantics, and merging
        // the card's paneTitle throws ("unmergeable property PaneTitle") whenever the merged tree is built (TalkBack, tests).
        Modifier.fillMaxSize().background(colors.scrim).pointerInput(Unit) { detectTapGestures {} },
        contentAlignment = Alignment.Center,
    ) {
        val shape = RoundedCornerShape(28.dp)
        Column(
            Modifier.width(312.dp).shadow(30.dp, shape).clip(shape).background(colors.sheet, shape)
                .pointerInput(Unit) { detectTapGestures {} }
                .semantics { paneTitle = title }
                .padding(start = 22.dp, end = 22.dp, top = 22.dp, bottom = 14.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(title, style = l2TextStyle(20.sp, FontWeight.SemiBold, colors.ink), modifier = Modifier.semantics { heading() })
            if (!body.isNullOrEmpty()) Text(body, style = l2TextStyle(14.sp, color = colors.ink2, lineHeight = 1.45f))
            FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.End), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                buttons.forEach { button ->
                    Box(
                        Modifier.height(40.dp).clip(RoundedCornerShape(20.dp)).clickable(role = Role.Button, onClick = button.action)
                            .testTagResource(button.tag).padding(horizontal = 12.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(button.label, style = l2TextStyle(14.sp, FontWeight.Bold, if (button.destructive) colors.danger else colors.sel))
                    }
                }
            }
        }
    }
}

/** The Reset choice (`actionSheet` on Android): the dialog titled "Reset" with the reset options (danger) and Cancel. */
@Composable
fun L2ResetChoices(options: List<L2DialogButton>, onCancel: () -> Unit) {
    L2Dialog("Reset", null, options.map { it.copy(destructive = true) } + L2DialogButton("Cancel", "reset-cancel", action = onCancel), onCancel)
}

/**
 * `sheetOverlay`: on phones a bottom sheet (30 dp top corners, hairline top edge, the 40×5 grabber unless [bare]) over
 * the scrim; on wider windows ([big]) a centred card, min(560 dp, 60 % of the width), 28 dp corners, hairline, shadow.
 * [heightFraction] gives it a fixed height; otherwise it fits its content (at most 92 % / 86 %).
 */
@Composable
fun L2Sheet(big: Boolean, heightFraction: Float? = null, bare: Boolean = false, scrolls: Boolean = true, onDismiss: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    val colors = lightlyColors
    BackHandler(onBack = onDismiss)
    BoxWithConstraints(
        // Tap-to-dismiss without `clickable`, for the same paneTitle merge reason as L2Dialog's scrim.
        Modifier.fillMaxSize().background(colors.scrim).pointerInput(onDismiss) { detectTapGestures { onDismiss() } },
        contentAlignment = if (big) Alignment.Center else Alignment.BottomCenter,
    ) {
        val shape = if (big) RoundedCornerShape(28.dp) else RoundedCornerShape(topStart = 30.dp, topEnd = 30.dp)
        val height = heightFraction?.let { maxHeight * it }
        Column(
            Modifier
                .then(if (big) Modifier.width(min(560.dp, maxWidth * 0.6f)) else Modifier.fillMaxWidth())
                .then(if (height != null) Modifier.height(height) else Modifier.heightIn(max = maxHeight * if (big) 0.86f else 0.92f))
                .then(if (big) Modifier.shadow(30.dp, shape) else Modifier)
                .clip(shape)
                .background(colors.sheet, shape)
                .border(1.dp, colors.hair, shape)
                .pointerInput(Unit) { detectTapGestures {} }
                .semantics { paneTitle = "Sheet" }
                .then(if (big) Modifier.padding(bottom = 14.dp) else Modifier.navigationBarsPadding().padding(bottom = 6.dp))
                .then(if (scrolls) Modifier.verticalScroll(rememberScrollState()) else Modifier),
        ) {
            if (!big && !bare) SheetGrabber()
            content()
        }
    }
}

/** `sheetHead`: a 90 dp leading slot, the centred 16 sp bold title, a 90 dp trailing slot; 6/12/10 dp padding. */
@Composable
fun L2SheetHead(title: String, leading: (@Composable () -> Unit)? = null, trailing: (@Composable () -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 6.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(90.dp), contentAlignment = Alignment.CenterStart) { leading?.invoke() }
        Text(title, style = l2TextStyle(16.sp, FontWeight.Bold, lightlyColors.ink), textAlign = TextAlign.Center, modifier = Modifier.weight(1f).semantics { heading() })
        Box(Modifier.width(90.dp), contentAlignment = Alignment.CenterEnd) { trailing?.invoke() }
    }
}

/** `textBtn`: accent text, 15 sp (bold when [bold]), 8/4 dp padding, 44 dp tall. */
@Composable
fun L2TextButton(label: String, tag: String, bold: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    Box(
        Modifier.heightIn(min = 44.dp).clip(RoundedCornerShape(8.dp)).clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .testTagResource(tag).padding(horizontal = 4.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = l2TextStyle(15.sp, if (bold) FontWeight.Bold else FontWeight.SemiBold, lightlyColors.sel.copy(alpha = if (enabled) 1f else 0.4f)))
    }
}
