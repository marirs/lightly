package com.lightlylabs.lightly.shell

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

@Composable
private fun WelcomeBrand() {
    val colors = lightlyColors
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        LightlyMark(56.dp, colors.ink)
        Text(
            StartCopy.WORDMARK,
            style = lightlyTextStyle(34.sp, FontWeight.SemiBold, colors.ink).copy(letterSpacing = (-0.02).em),
            modifier = Modifier.semantics { heading() },
        )
        Text(StartCopy.TAGLINE, style = lightlyTextStyle(17.sp, color = colors.ink2), textAlign = TextAlign.Center)
    }
}

@Composable
private fun WelcomeActions(onChoosePhoto: () -> Unit, onCamera: () -> Unit, onPrivacyPolicy: () -> Unit) {
    val colors = lightlyColors
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Column(Modifier.widthIn(max = 420.dp).fillMaxWidth().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            LightlyButton(
                StartCopy.CHOOSE_PHOTO, ButtonKind.PRIMARY, onChoosePhoto, Modifier.fillMaxWidth(),
                icon = LightlyIcons.Photo, minHeight = 52.dp, fontSize = 16.sp, cornerRadius = 12.dp, tag = ShellTags.CHOOSE_PHOTO,
            )
            LightlyButton(
                StartCopy.CAMERA, ButtonKind.LINE, onCamera, Modifier.fillMaxWidth(),
                icon = LightlyIcons.Camera, minHeight = 52.dp, fontSize = 16.sp, cornerRadius = 12.dp, tag = ShellTags.CAMERA,
            )
        }
        Text(
            StartCopy.PRIVACY_LINE,
            style = lightlyTextStyle(12.5.sp, color = colors.ink3),
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(start = 20.dp, end = 20.dp, top = 14.dp),
        )
        LightlyButton(StartCopy.PRIVACY_POLICY, ButtonKind.QUIET, onPrivacyPolicy, Modifier.padding(top = 4.dp), underline = true, tag = ShellTags.PRIVACY_LINK)
    }
}

/**
 * Welcome (prototype `welcomeHTML`): ⋮, the mark, "Lightly", tagline, Choose a photo, Camera, the
 * privacy line and the Privacy Policy link. On an unfolded foldable the brand takes one pane and the
 * actions the other, so nothing sits on the fold. No sign-in, no onboarding.
 */
@Composable
fun WelcomeScreen(layout: ShellLayout, onChoosePhoto: () -> Unit, onCamera: () -> Unit, onPrivacyPolicy: () -> Unit, onMore: () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        // Prototype: max(28px, 6% of the screen height) below the link.
        val bottomSpace = max(28.dp, maxHeight * 0.06f)
        Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            TopBar {
                Spacer(Modifier.weight(1f))
                IconTapTarget(LightlyIcons.More, "More", onMore, tag = ShellTags.MORE)
            }
            if (layout.isSplit) {
                FoldPanes(
                    layout, Modifier.weight(1f).fillMaxWidth(),
                    first = { WelcomeBrand() },
                    second = { WelcomeActions(onChoosePhoto, onCamera, onPrivacyPolicy) },
                )
            } else {
                Column(Modifier.weight(1f).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                    Spacer(Modifier.weight(1f))
                    WelcomeBrand()
                    Spacer(Modifier.weight(1f))
                    WelcomeActions(onChoosePhoto, onCamera, onPrivacyPolicy)
                    Spacer(Modifier.height(bottomSpace))
                }
            }
        }
    }
}

/**
 * A full-screen message with two actions (prototype `messageScreen`): Camera access is off, and
 * This photo can't be opened. On an unfolded foldable the message and the actions take one pane each.
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
    // Prototype: the text block is at most 380 dp wide, or 360 dp in a fold pane.
    val headMaxWidth = if (layout.isSplit) 360.dp else 380.dp
    val head: @Composable () -> Unit = {
        // As approved: the icon sits at the start of the text block (a block-level icon in the
        // prototype), the title and body are centred lines.
        Column(Modifier.widthIn(max = headMaxWidth)) {
            LightlyIcon(LightlyIcons.Photo, size = 44.dp, tint = colors.ink)
            Text(
                title,
                style = lightlyTextStyle(20.sp, FontWeight.SemiBold, colors.ink),
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(top = 16.dp, bottom = 8.dp).semantics { heading() },
            )
            Text(body, style = lightlyTextStyle(color = colors.ink2), textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
        }
    }
    val actions: @Composable () -> Unit = {
        Column(Modifier.widthIn(max = 380.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            LightlyButton(primaryLabel, ButtonKind.PRIMARY, onPrimary, Modifier.fillMaxWidth(), tag = ShellTags.MESSAGE_PRIMARY)
            LightlyButton(secondaryLabel, ButtonKind.LINE, onSecondary, Modifier.fillMaxWidth(), tag = ShellTags.MESSAGE_SECONDARY)
        }
    }
    Column(Modifier.fillMaxSize().safeDrawingPadding()) {
        TopBar { IconTapTarget(LightlyIcons.BackArrow, "Back", onBack, tag = ShellTags.BACK) }
        if (layout.isSplit) {
            FoldPanes(
                layout, Modifier.weight(1f).fillMaxWidth(),
                first = { Box(Modifier.padding(24.dp)) { head() } },
                second = { Box(Modifier.padding(24.dp)) { actions() } },
            )
        } else {
            Box(Modifier.weight(1f).fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                Column(Modifier.widthIn(max = 380.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
                    head()
                    actions()
                }
            }
        }
    }
}
