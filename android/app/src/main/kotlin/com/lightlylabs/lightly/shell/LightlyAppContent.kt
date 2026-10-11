package com.lightlylabs.lightly.shell

import androidx.compose.foundation.background
import androidx.compose.ui.draw.shadow
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.min

/** Everything the shell can ask the Activity to do (launch system UI, open the editor, …). */
class ShellActions(
    val choosePhoto: () -> Unit,
    val camera: () -> Unit,
    val openAppSettings: () -> Unit,
    val retryLoad: () -> Unit,
    val navigate: (AppNavState) -> Unit,
    val more: MoreActions,
    /** A double tap on Welcome's empty space: the next theme (owner amendment 2026-10-11, [ThemeCycle]). */
    val cycleTheme: (() -> Unit)? = null,
)

/**
 * The whole app below the Activity: the base screen for [state], with ⋮ More above it presented per
 * [layout]. Pure UI (state in, callbacks out) so Robolectric drives it without launchers.
 *
 * [editor] is the approved editor (slice 2); it draws its own top bar and handles its insets.
 */
@Composable
fun LightlyAppContent(
    state: AppNavState,
    layout: ShellLayout,
    content: MoreContent,
    actions: ShellActions,
    editor: @Composable () -> Unit,
    /** The shell's toast (Welcome and More; the editor draws its own on the photo stage). */
    toast: String? = null,
) {
    val colors = lightlyColors
    CompositionLocalProvider(LocalContentColor provides colors.ink) {
        Box(
            Modifier
                .fillMaxSize()
                .background(colors.bg)
                // Test tags double as resource ids for the scripted emulator comparison.
                .semantics { testTagsAsResourceId = true },
        ) {
            val page = state.morePage
            // Lightly 2: on phones More and its pages are full screen; elsewhere they are the centred sheet card.
            val fullScreenPage = page != null && layout == ShellLayout.Compact
            if (fullScreenPage) {
                Column(Modifier.fillMaxSize().background(colors.bg).safeDrawingPadding()) { FullScreenMorePage(page, content, actions.more) }
            } else {
                BaseScreenView(state, layout, actions, editor)
                if (page != null) MoreSheet(page, layout, content, actions.more)
            }
            // Top centre under the status bar: Welcome's and More's controls sit at the bottom and in the top corners, so it
            // never covers one (at the bottom it hid Welcome's Camera button on the motorola).
            if (toast != null) ShellToast(toast, Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(top = 14.dp))
        }
    }
}

@Composable
private fun BaseScreenView(state: AppNavState, layout: ShellLayout, actions: ShellActions, editor: @Composable () -> Unit) {
    when (state.base) {
        BaseScreen.WELCOME -> WelcomeScreen(
            layout,
            onChoosePhoto = actions.choosePhoto,
            onCamera = actions.camera,
            onPrivacyPolicy = { actions.navigate(AppNavigator.openPrivacyFromWelcome(state)) },
            onMore = { actions.navigate(AppNavigator.openMore(state)) },
            onEmptyDoubleTap = actions.cycleTheme,
        )
        BaseScreen.CAMERA_DENIED -> MessageScreen(
            layout, StartCopy.CAMERA_DENIED_TITLE, StartCopy.CAMERA_DENIED_BODY,
            primaryLabel = StartCopy.OPEN_SETTINGS, onPrimary = actions.openAppSettings,
            secondaryLabel = StartCopy.CHOOSE_INSTEAD, onSecondary = actions.choosePhoto,
            onBack = { actions.navigate(AppNavigator.toWelcome()) },
        )
        BaseScreen.LOAD_FAILED -> MessageScreen(
            layout, StartCopy.LOAD_FAILED_TITLE, StartCopy.LOAD_FAILED_BODY,
            primaryLabel = StartCopy.CHOOSE_ANOTHER, onPrimary = actions.choosePhoto,
            secondaryLabel = StartCopy.TRY_AGAIN, onSecondary = actions.retryLoad,
            onBack = { actions.navigate(AppNavigator.toWelcome()) },
        )
        BaseScreen.EDITOR -> Box(Modifier.fillMaxSize()) { editor() }
    }
}

/**
 * More as the centred sheet card (Lightly 2 `sheetOverlay` on wide screens): min(560 dp, 60 % of the width), 92 % of
 * the height, 28 dp corners, sheet fill, hairline, shadow, over the scrim; a tap on the scrim closes More.
 */
@Composable
private fun MoreSheet(page: MorePage, layout: ShellLayout, content: MoreContent, actions: MoreActions) {
    val colors = lightlyColors
    BoxWithConstraints(Modifier.fillMaxSize()) {
        Box(
            Modifier
                .fillMaxSize()
                .background(colors.scrim)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { actions.close() }
                .semantics { contentDescription = "Close More" }
                .testTagResource(ShellTags.SHEET_SCRIM),
        )
        // Swallows taps inside the sheet so they never reach the scrim (a pointer handler keeps the page's own nodes); a
        // double tap on the page's empty space cycles the theme.
        val sheetSurface = Modifier.pointerInput(actions.cycleTheme) { detectTapGestures(onDoubleTap = { actions.cycleTheme?.invoke() }) {} }
        val shape = RoundedCornerShape(28.dp)
        Column(
            Modifier
                .align(Alignment.Center)
                .width(min(560.dp, maxWidth * 0.6f))
                .height(maxHeight * 0.92f)
                .shadow(30.dp, shape)
                .clip(shape)
                .background(colors.sheet)
                .border(1.dp, colors.hair, shape)
                .then(sheetSurface)
                .padding(bottom = 14.dp),
        ) {
            MorePageView(page, content, actions, Modifier.weight(1f), inSheet = true)
        }
    }
}
