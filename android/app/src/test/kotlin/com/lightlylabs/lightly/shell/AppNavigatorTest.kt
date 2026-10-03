package com.lightlylabs.lightly.shell

import android.content.pm.ActivityInfo
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull

/** Navigation rules for slice 1 (pure JVM). */
class AppNavigatorTest {

    private val welcome = AppNavState()

    @Test
    fun `More opens over Welcome and its pages step back to their parents`() {
        val more = AppNavigator.openMore(welcome)
        val preferences = AppNavigator.openPage(more, MorePage.PREFERENCES)
        val favourites = AppNavigator.openPage(preferences, MorePage.FAVOURITES)

        assertEquals(AppNavState(BaseScreen.WELCOME, MorePage.FAVOURITES), favourites)
        assertEquals(preferences, AppNavigator.back(favourites))
        assertEquals(more, AppNavigator.back(preferences))
        assertEquals(welcome, AppNavigator.back(more), "Back on the root More page closes it")
        assertNull(AppNavigator.back(welcome), "Back on Welcome leaves the app")
    }

    @Test
    fun `every More page returns to the approved parent`() {
        val parents = MorePage.entries.associateWith { it.parent }
        assertEquals(
            mapOf(
                MorePage.MORE to null, MorePage.PREFERENCES to MorePage.MORE, MorePage.FAVOURITES to MorePage.PREFERENCES,
                MorePage.SIGNATURE to MorePage.PREFERENCES, MorePage.PREFERRED_BORDER to MorePage.PREFERENCES,
                MorePage.LEGAL to MorePage.MORE, MorePage.PRIVACY to MorePage.LEGAL, MorePage.TERMS to MorePage.LEGAL,
                MorePage.ABOUT to MorePage.MORE, MorePage.SUPPORT to MorePage.ABOUT,
            ),
            parents,
        )
    }

    @Test
    fun `Privacy Policy from Welcome returns straight to Welcome`() {
        val privacy = AppNavigator.openPrivacyFromWelcome(welcome)

        assertEquals(MorePage.PRIVACY, privacy.morePage)
        assertEquals(welcome, AppNavigator.back(privacy))
    }

    @Test
    fun `Privacy Policy reached through Legal returns to Legal`() {
        val legal = AppNavigator.openPage(AppNavigator.openMore(welcome), MorePage.LEGAL)
        val privacy = AppNavigator.openPage(legal, MorePage.PRIVACY)

        assertEquals(legal, AppNavigator.back(privacy))
    }

    @Test
    fun `More from the editor closes back to the editor`() {
        val editor = AppNavigator.openEditor()
        val more = AppNavigator.openMore(editor)

        assertEquals(editor, AppNavigator.closeMore(more))
        assertEquals(editor, AppNavigator.back(more))
        assertEquals(welcome, AppNavigator.back(editor))
    }

    @Test
    fun `camera denied and load failed go back to Welcome`() {
        assertEquals(welcome, AppNavigator.back(AppNavigator.showCameraDenied()))
        assertEquals(welcome, AppNavigator.back(AppNavigator.showLoadFailed()))
    }

    @Test
    fun `state survives process death through its encoding`() {
        val states = listOf(
            welcome,
            AppNavigator.openPrivacyFromWelcome(welcome),
            AppNavigator.openPage(AppNavigator.openEditor(), MorePage.PREFERRED_BORDER),
            AppNavigator.showCameraDenied(),
        )
        states.forEach { assertEquals(it, AppNavigator.decode(AppNavigator.encode(it))) }
        assertEquals(welcome, AppNavigator.decode(null))
        assertEquals(welcome, AppNavigator.decode("garbage"))
    }

    @Test
    fun `layouts follow window size and fold, never the model`() {
        assertIs<ShellLayout.Compact>(ShellLayout.decide(427f, 952f, null)) // Pixel 9 Pro
        assertIs<ShellLayout.Compact>(ShellLayout.decide(443f, 994f, null)) // Fold, folded
        assertIs<ShellLayout.Large>(ShellLayout.decide(800f, 1280f, null)) // Pixel Tablet portrait
        assertIs<ShellLayout.Large>(ShellLayout.decide(1280f, 800f, null)) // Pixel Tablet landscape
        assertEquals(ShellLayout.SplitVertical(426f), ShellLayout.decide(852f, 883f, FoldGeometry(isVertical = true, centerDp = 426f)))
        assertEquals(ShellLayout.SplitHorizontal(426f), ShellLayout.decide(883f, 852f, FoldGeometry(isVertical = false, centerDp = 426f)))
        // A fold reported outside this window (e.g. split screen on the other half) does not split it.
        assertIs<ShellLayout.Compact>(ShellLayout.decide(420f, 883f, FoldGeometry(isVertical = true, centerDp = 426f)))
    }

    @Test
    fun `phones and folded foldables are portrait only, larger displays rotate freely`() {
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, OrientationPolicy.requestedOrientation(427f, inMultiWindow = false))
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, OrientationPolicy.requestedOrientation(443f, inMultiWindow = false))
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED, OrientationPolicy.requestedOrientation(852f, inMultiWindow = false))
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED, OrientationPolicy.requestedOrientation(800f, inMultiWindow = false))
        assertEquals(ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED, OrientationPolicy.requestedOrientation(427f, inMultiWindow = true))
    }
}
