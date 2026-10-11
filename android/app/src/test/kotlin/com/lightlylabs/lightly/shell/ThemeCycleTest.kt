package com.lightlylabs.lightly.shell

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.doubleClick
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import com.lightlylabs.lightly.prefs.Appearance
import com.lightlylabs.lightly.prefs.PresetCatalogue
import com.lightlylabs.lightly.prefs.ReleaseText
import com.lightlylabs.lightly.prefs.UserPreferences
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertEquals

/**
 * Owner amendment 2026-10-11 (`theme-cycle`): a double tap on empty space cycles System → Light → Dark → System, through
 * the Appearance preference, with the toast naming the new theme; a double tap on a control does not.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w427dp-h952dp")
class ThemeCycleTest {
    @get:Rule
    val compose = createComposeRule()

    private var nav by mutableStateOf(AppNavState())
    private var preferences by mutableStateOf(UserPreferences())
    private var toast by mutableStateOf<String?>(null)

    private val catalogue = PresetCatalogue.parse("""{"categories":[]}""")

    /** As MainActivity: the next theme is written to the preference and named in the shell's toast. */
    private fun cycle() {
        val next = ThemeCycle.next(preferences.appearance)
        preferences = preferences.copy(appearance = next)
        toast = ThemeCycle.toast(next)
    }

    private fun show(start: AppNavState = AppNavState()) {
        nav = start
        compose.setContent {
            LightlyTheme(dark = preferences.appearance == Appearance.DARK) {
                LightlyAppContent(
                    state = nav,
                    layout = ShellLayout.Compact,
                    content = MoreContent(preferences, catalogue, ReleaseText.NONE, "1.0 (1)", nav.privacyFromWelcome),
                    actions = ShellActions(
                        choosePhoto = {}, camera = {}, openAppSettings = {}, retryLoad = {}, navigate = { nav = it },
                        more = MoreActions(
                            openPage = { nav = AppNavigator.openPage(nav, it) }, back = {}, close = { nav = AppNavigator.closeMore(nav) },
                            updatePreferences = { change -> preferences = change(preferences) }, openSupport = {}, cycleTheme = ::cycle,
                        ),
                        cycleTheme = ::cycle,
                    ),
                    editor = {},
                    toast = toast,
                )
            }
        }
        compose.waitForIdle()
    }

    @Test
    fun `the cycle order and the toast copy are the approved ones`() {
        assertEquals(Appearance.LIGHT, ThemeCycle.next(Appearance.SYSTEM))
        assertEquals(Appearance.DARK, ThemeCycle.next(Appearance.LIGHT))
        assertEquals(Appearance.SYSTEM, ThemeCycle.next(Appearance.DARK))
        assertEquals("System theme", ThemeCycle.toast(Appearance.SYSTEM))
        assertEquals("Light theme", ThemeCycle.toast(Appearance.LIGHT))
        assertEquals("Dark theme", ThemeCycle.toast(Appearance.DARK))
    }

    @Test
    fun `double tapping Welcome's background cycles System, Light, Dark and back, with the toast`() {
        show()
        val expected = listOf(Appearance.LIGHT to "Light theme", Appearance.DARK to "Dark theme", Appearance.SYSTEM to "System theme")
        for ((appearance, text) in expected) {
            // Near the top start: the background, away from More, the brand and the buttons.
            compose.onNodeWithTag("welcome-background").performTouchInput { doubleClick(androidx.compose.ui.geometry.Offset(width * 0.2f, height * 0.25f)) }
            compose.waitForIdle()
            assertEquals(appearance, preferences.appearance)
            compose.onNodeWithTag("shell-toast").assertIsDisplayed()
            assertEquals(text, toast)
        }
    }

    @Test
    fun `double tapping a control does not cycle the theme`() {
        show()
        compose.onNodeWithTag(ShellTags.CHOOSE_PHOTO).performTouchInput { doubleClick() }
        compose.waitForIdle()
        assertEquals(Appearance.SYSTEM, preferences.appearance)
    }

    @Test
    fun `double tapping the More page background cycles the theme`() {
        show(AppNavigator.openMore(AppNavState()))
        // The page's 16 dp side margin: background, not a card or a row.
        compose.onNodeWithTag("more-background").performTouchInput { doubleClick(androidx.compose.ui.geometry.Offset(8f, height * 0.5f)) }
        compose.waitForIdle()
        assertEquals(Appearance.LIGHT, preferences.appearance)
        assertEquals("Light theme", toast)
    }
}
