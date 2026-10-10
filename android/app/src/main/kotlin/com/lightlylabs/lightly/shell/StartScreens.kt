package com.lightlylabs.lightly.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.max
import androidx.compose.ui.unit.sp

/** Approved copy for the start screens (docs/ui/app/app.js), verbatim. */
object StartCopy {
    const val WORDMARK = "Lightly"
    const val TAGLINE = "See it as you remember it."
    const val CHOOSE_PHOTO = "Choose a photo"
    const val CAMERA = "Camera"
    const val PRIVACY_LINE = "Your photos stay on your device by default."
    const val PRIVACY_POLICY = "Privacy Policy"

    const val CAMERA_DENIED_TITLE = "Camera access is off"
    const val CAMERA_DENIED_BODY = "To take a photo in Lightly, allow camera access in Settings. You can still choose a photo from your library."
    const val OPEN_SETTINGS = "Open Settings"
    const val CHOOSE_INSTEAD = "Choose a photo instead"

    const val LOAD_FAILED_TITLE = "This photo can’t be opened"
    const val LOAD_FAILED_BODY = "It may be in a format Lightly doesn’t support, or it couldn’t be downloaded. Your library is unchanged."
    const val CHOOSE_ANOTHER = "Choose another photo"
    const val TRY_AGAIN = "Try again"
}

/** Stable tags for tests and the scripted emulator comparison. */
object ShellTags {
    const val MORE = "shell-more"
    const val CHOOSE_PHOTO = "welcome-choose-photo"
    const val CAMERA = "welcome-camera"
    const val PRIVACY_LINK = "welcome-privacy-policy"
    const val BACK = "shell-back"
    const val MESSAGE_PRIMARY = "message-primary"
    const val MESSAGE_SECONDARY = "message-secondary"
    const val SHEET_SCRIM = "more-scrim"
    const val KEEP_METADATA = "pref-keep-metadata"
    const val INCLUDE_LOCATION = "pref-include-location"
}

/**
 * Two panes either side of a fold (prototype `.foldsplit`): the area below the top bar is split into
 * two equal halves, along the fold's direction, and each pane's content starts at its top, centred
 * across (`.center` = place-items:center on a top-aligned column). With top-aligned content, nothing
 * sits on the fold line.
 */
@Composable
fun FoldPanes(layout: ShellLayout, modifier: Modifier = Modifier, first: @Composable () -> Unit, second: @Composable () -> Unit) {
    when (layout) {
        is ShellLayout.SplitHorizontal -> Column(modifier) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.TopCenter) { first() }
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.TopCenter) { second() }
        }
        else -> Row(modifier) {
            Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.TopCenter) { first() }
            Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.TopCenter) { second() }
        }
    }
}

/** Lightly 2 `welcome` brand: the coloured mark (84 dp), "Lightly" (44 sp heading, −1 sp) and the tagline (18 sp ink2), 16 dp apart. */
@Composable
private fun WelcomeBrand() {
    val colors = lightlyColors
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        LightlyMark(84.dp)
        Text(StartCopy.WORDMARK, style = l2TextStyle(44.sp, FontWeight.SemiBold, colors.ink, tracking = (-1).sp), modifier = Modifier.semantics { heading() })
        Text(StartCopy.TAGLINE, style = l2TextStyle(18.sp, color = colors.ink2), textAlign = TextAlign.Center)
    }
}

/**
 * The actions (at most 360 dp, 12 dp apart): Choose a photo (lime, 56 dp), Camera (outlined, 56 dp), the privacy line
 * (13 sp ink2, 8 dp more above) and the Privacy Policy link (14 sp semibold accent, 10 dp padding).
 */
@Composable
private fun WelcomeActions(onChoosePhoto: () -> Unit, onCamera: () -> Unit, onPrivacyPolicy: () -> Unit) {
    val colors = lightlyColors
    Column(Modifier.widthIn(max = 360.dp).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        LightlyButton(StartCopy.CHOOSE_PHOTO, ButtonKind.PRIMARY, onChoosePhoto, icon = LightlyIcons.Photo, minHeight = 56.dp, tag = ShellTags.CHOOSE_PHOTO)
        LightlyButton(StartCopy.CAMERA, ButtonKind.LINE, onCamera, icon = LightlyIcons.Camera, minHeight = 56.dp, tag = ShellTags.CAMERA)
        Text(StartCopy.PRIVACY_LINE, style = l2TextStyle(13.sp, color = colors.ink2), textAlign = TextAlign.Center, modifier = Modifier.padding(top = 8.dp))
        Text(
            StartCopy.PRIVACY_POLICY, style = l2TextStyle(14.sp, FontWeight.SemiBold, colors.sel),
            modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable(role = Role.Button, onClick = onPrivacyPolicy)
                .testTagResource(ShellTags.PRIVACY_LINK).padding(10.dp),
        )
    }
}

/**
 * Welcome (Lightly 2 `welcome`): the lime ⋮ More top right; on phones the brand centred above the actions (24 dp sides,
 * 10 dp above the bottom); on unfolded foldables the brand and the actions side by side, centred in two equal columns.
 */
@Composable
fun WelcomeScreen(layout: ShellLayout, onChoosePhoto: () -> Unit, onCamera: () -> Unit, onPrivacyPolicy: () -> Unit, onMore: () -> Unit) {
    Column(Modifier.fillMaxSize().safeDrawingPadding().padding(horizontal = if (layout.isSplit) 16.dp else 24.dp)
        .padding(top = if (layout.isSplit) 16.dp else 0.dp, bottom = if (layout.isSplit) 16.dp else 10.dp)) {
        Row(Modifier.fillMaxWidth()) {
            Spacer(Modifier.weight(1f))
            MoreButton(onMore, tag = ShellTags.MORE)
        }
        if (layout is ShellLayout.SplitHorizontal) {
            // No mockup reference for a horizontal fold: the agreed behaviour keeps the brand above it and the actions below.
            FoldPanes(layout, Modifier.weight(1f).fillMaxWidth(), first = { WelcomeBrand() }, second = { WelcomeActions(onChoosePhoto, onCamera, onPrivacyPolicy) })
        } else if (layout.isSplit) {
            Row(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 24.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(32.dp)) {
                Box(Modifier.weight(1f), contentAlignment = Alignment.Center) { WelcomeBrand() }
                Box(Modifier.weight(1f), contentAlignment = Alignment.Center) { WelcomeActions(onChoosePhoto, onCamera, onPrivacyPolicy) }
            }
        } else {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) { WelcomeBrand() }
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { WelcomeActions(onChoosePhoto, onCamera, onPrivacyPolicy) }
        }
    }
}

/**
 * Lightly 2 `messageScreen`: Close top-left (12 dp in); a 72 dp photo tile (24 dp corners, card fill, hairline, 34 dp
 * accent icon), the title (22 sp heading) and the message (14 sp ink2, line height 1.45), 14 dp apart, at most 340 dp;
 * the actions (primary then outlined, 10 dp apart, at most 340 dp); 28 dp between, centred. Foldables: side by side.
 */
@Composable
fun MessageScreen(
    layout: ShellLayout,
    title: String,
    body: String,
    primaryLabel: String,
    onPrimary: () -> Unit,
    secondaryLabel: String,
    onSecondary: () -> Unit,
    onBack: () -> Unit,
) {
    val colors = lightlyColors
    val head: @Composable () -> Unit = {
        Column(Modifier.widthIn(max = 340.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(Modifier.size(72.dp).clip(RoundedCornerShape(24.dp)).background(colors.bg2).border(1.dp, colors.hair, RoundedCornerShape(24.dp)),
                contentAlignment = Alignment.Center) { LightlyIcon(LightlyIcons.Photo, size = 34.dp, tint = colors.sel) }
            Text(title, style = l2TextStyle(22.sp, FontWeight.SemiBold, colors.ink), textAlign = TextAlign.Center, modifier = Modifier.semantics { heading() })
            Text(body, style = l2TextStyle(14.sp, color = colors.ink2, lineHeight = 1.45f), textAlign = TextAlign.Center)
        }
    }
    val actions: @Composable () -> Unit = {
        Column(Modifier.widthIn(max = 340.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            LightlyButton(primaryLabel, ButtonKind.PRIMARY, onPrimary, tag = ShellTags.MESSAGE_PRIMARY)
            LightlyButton(secondaryLabel, ButtonKind.LINE, onSecondary, tag = ShellTags.MESSAGE_SECONDARY)
        }
    }
    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
        if (layout is ShellLayout.SplitHorizontal) {
            // As Welcome: nothing on a horizontal fold (no mockup reference; agreed behaviour).
            FoldPanes(layout, Modifier.fillMaxSize().padding(start = 24.dp, end = 24.dp, top = 50.dp), first = head, second = actions)
        } else if (layout.isSplit) {
            Row(Modifier.fillMaxSize().padding(start = 40.dp, end = 40.dp, top = 50.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f), contentAlignment = Alignment.Center) { head() }
                Box(Modifier.weight(1f), contentAlignment = Alignment.Center) { actions() }
            }
        } else {
            Column(Modifier.fillMaxSize().padding(start = 24.dp, end = 24.dp, top = 50.dp, bottom = 20.dp), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(28.dp, Alignment.CenterVertically)) {
                head()
                actions()
            }
        }
        IconTapTarget(LightlyIcons.Close, "Close", onBack, Modifier.padding(start = 12.dp), tag = ShellTags.BACK)
    }
}
