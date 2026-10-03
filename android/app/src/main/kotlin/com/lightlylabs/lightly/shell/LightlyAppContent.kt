package com.lightlylabs.lightly.shell

import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
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
)

/**
 * The whole app below the Activity: the base screen for [state], with ⋮ More above it presented per
 * [layout]. Pure UI (state in, callbacks out) so Robolectric drives it without launchers.
 *
 * [editor] is the existing M2 editor, hosted under a top row with Back and ⋮ until slice 2 replaces
 * it with the approved editor.
 */
@Composable
fun LightlyAppContent(
    state: AppNavState,
    layout: ShellLayout,
    content: MoreContent,
    actions: ShellActions,
    editor: @Composable () -> Unit,
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
            // Phones: More itself is a sheet over the screen it was opened from; the pages it leads to
            // are full screen (prototype: `welcome-more` / `more` are sheets, `preferences` … are pages).
            val fullScreenPage = page != null && page != MorePage.MORE && layout == ShellLayout.Compact
            if (fullScreenPage) {
                Column(Modifier.fillMaxSize().safeDrawingPadding()) { FullScreenMorePage(page, content, actions.more) }
            } else {
                BaseScreenView(state, layout, actions, editor)
                if (page != null) MoreSheet(page, layout, content, actions.more)
            }
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
        BaseScreen.EDITOR -> Column(Modifier.fillMaxSize().safeDrawingPadding()) {
            // DEFERRED(slice 2): the approved editor top bar (close, undo, redo, compare, Save copy, ⋮).
            TopBar {
                IconTapTarget(LightlyIcons.BackArrow, "Back", { actions.navigate(AppNavigator.toWelcome()) }, tag = ShellTags.BACK)
                Box(Modifier.weight(1f))
                IconTapTarget(LightlyIcons.More, "More", { actions.navigate(AppNavigator.openMore(state)) }, tag = ShellTags.MORE)
            }
            Box(Modifier.weight(1f).fillMaxWidth()) { editor() }
        }
    }
}

/**
 * More as a sheet (prototype `overlayHTML('page')`):
 * - phones: bottom sheet, 92% of the screen, with a grabber;
 * - tablets: centred form sheet, min(540 dp, 92%) wide and 70% tall, no grabber;
 * - unfolded foldables: a bottom sheet confined to the right (vertical fold) or lower (horizontal
 *   fold) pane, as tall as its content, so it never crosses the fold.
 * A tap on the scrim closes More.
 */
@Composable
private fun MoreSheet(page: MorePage, layout: ShellLayout, content: MoreContent, actions: MoreActions) {
    val colors = lightlyColors
    val density = LocalDensity.current
    var originInWindow by remember { mutableStateOf(Offset.Zero) }
    BoxWithConstraints(Modifier.fillMaxSize().onGloballyPositioned { originInWindow = it.positionInWindow() }) {
        Box(
            Modifier
                .fillMaxSize()
                .background(colors.scrim)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { actions.close() }
                .semantics { contentDescription = "Close More" }
                .testTagResource(ShellTags.SHEET_SCRIM),
        )
        // Swallows taps inside the sheet so they never reach the scrim. A pointer handler, not
        // `clickable`: clickable would merge the whole sheet into one accessibility node.
        val sheetSurface = Modifier.pointerInput(Unit) { detectTapGestures {} }
        when (layout) {
            ShellLayout.Compact -> Column(
                Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .height(maxHeight * 0.92f)
                    .clip(RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp))
                    .background(colors.sheet)
                    .then(sheetSurface)
                    .padding(top = 8.dp)
                    .navigationBarsPadding()
                    .padding(bottom = 6.dp),
            ) {
                SheetGrabber()
                MorePageView(page, content, actions, Modifier.weight(1f))
            }
            ShellLayout.Large -> Column(
                Modifier
                    .align(Alignment.Center)
                    .width(min(540.dp, maxWidth * 0.92f))
                    .height(maxHeight * 0.7f)
                    .clip(RoundedCornerShape(14.dp))
                    .background(colors.sheet)
                    .then(sheetSurface)
                    .padding(top = 8.dp, bottom = 16.dp),
            ) {
                MorePageView(page, content, actions, Modifier.weight(1f))
            }
            is ShellLayout.SplitVertical, is ShellLayout.SplitHorizontal -> {
                val paneModifier = if (layout is ShellLayout.SplitVertical) {
                    val foldX = with(density) { (layout.foldXDp.dp.toPx() - originInWindow.x).toDp() }.coerceIn(0.dp, maxWidth)
                    Modifier.align(Alignment.BottomEnd).width(maxWidth - foldX).heightIn(max = maxHeight)
                } else {
                    val foldY = with(density) { ((layout as ShellLayout.SplitHorizontal).foldYDp.dp.toPx() - originInWindow.y).toDp() }.coerceIn(0.dp, maxHeight)
                    Modifier.align(Alignment.BottomCenter).fillMaxWidth().heightIn(max = maxHeight - foldY)
                }
                Column(
                    paneModifier
                        .clip(RoundedCornerShape(topStart = 14.dp, topEnd = 14.dp))
                        .background(colors.sheet)
                        .then(sheetSurface)
                        .padding(top = 8.dp)
                        .navigationBarsPadding()
                        .padding(bottom = 6.dp),
                ) {
                    SheetGrabber()
                    MorePageView(page, content, actions, Modifier.weight(1f, fill = false))
                }
            }
        }
    }
}
