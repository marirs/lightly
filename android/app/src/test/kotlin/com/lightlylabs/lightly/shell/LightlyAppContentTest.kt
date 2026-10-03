package com.lightlylabs.lightly.shell

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.getBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.Density
import com.lightlylabs.lightly.prefs.Appearance
import com.lightlylabs.lightly.prefs.PreferredBorder
import com.lightlylabs.lightly.prefs.PresetCatalogue
import com.lightlylabs.lightly.prefs.ReleaseText
import com.lightlylabs.lightly.prefs.UserPreferences
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The slice-1 shell on Robolectric: Welcome, More and its pages, Preferences persistence through the
 * callbacks, the message screens, and where sheets go per layout. Pixels are compared on emulators
 * (docs/v1/slice1-android.md).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w427dp-h952dp")
class LightlyAppContentTest {

    @get:Rule
    val compose = createComposeRule()

    private var nav by mutableStateOf(AppNavState())
    private var preferences by mutableStateOf(UserPreferences())
    private val calls = mutableListOf<String>()

    private val catalogue = PresetCatalogue.parse(
        """{"categories":[{"id":"portrait","name":"Portrait","presets":[{"id":"look-1","displayName":"01 Fitness 01","stop":1},{"id":"look-2","displayName":"01 Light & Airy 01","stop":2}]}]}""",
    )

    private fun show(layout: ShellLayout = ShellLayout.Compact, start: AppNavState = AppNavState(), fontScale: Float = 1f) {
        nav = start
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale)) {
            LightlyTheme(dark = preferences.appearance == Appearance.DARK) {
                LightlyAppContent(
                    state = nav,
                    layout = layout,
                    content = MoreContent(preferences, catalogue, ReleaseText.NONE, "1.0 (1)", nav.privacyFromWelcome),
                    actions = ShellActions(
                        choosePhoto = { calls += "choosePhoto" },
                        camera = { calls += "camera" },
                        openAppSettings = { calls += "settings" },
                        retryLoad = { calls += "retry" },
                        navigate = { nav = it },
                        more = MoreActions(
                            openPage = { nav = AppNavigator.openPage(nav, it) },
                            back = { AppNavigator.back(nav)?.let { previous -> nav = previous } },
                            close = { nav = AppNavigator.closeMore(nav) },
                            updatePreferences = { change -> preferences = change(preferences) },
                            openSupport = { calls += "support:$it" },
                        ),
                    ),
                    editor = {},
                )
            }
            }
        }
        compose.waitForIdle()
    }

    @Test
    fun `Welcome shows the approved content and no sign-in`() {
        show()

        listOf("Lightly", "See it as you remember it.", "Choose a photo", "Camera", "Your photos stay on your device by default.", "Privacy Policy")
            .forEach { compose.onNodeWithText(it).assertIsDisplayed() }
        compose.onNodeWithTag(ShellTags.CHOOSE_PHOTO).performClick()
        compose.onNodeWithTag(ShellTags.CAMERA).performClick()
        assertEquals(listOf("choosePhoto", "camera"), calls)
        assertEquals(AppNavState(), nav, "launching the picker or camera does not navigate by itself")
    }

    @Test
    fun `Privacy Policy link opens the policy and Back returns to Welcome`() {
        show()

        compose.onNodeWithTag(ShellTags.PRIVACY_LINK).performClick()
        compose.onNodeWithTag("document-unavailable").assertIsDisplayed()
        compose.onNodeWithText(ReleaseText.UNAVAILABLE_DOCUMENT).assertIsDisplayed()

        compose.onNodeWithTag("page-navigation").performClick()
        assertEquals(AppNavState(), nav)
        compose.onNodeWithText("See it as you remember it.").assertIsDisplayed()
    }

    @Test
    fun `phone - More is a sheet over Welcome, its pages are full screen`() {
        show()

        compose.onNodeWithTag(ShellTags.MORE).performClick()
        compose.onNodeWithTag(ShellTags.SHEET_SCRIM).assertExists()
        compose.onNodeWithText("Choose a photo").assertExists() // still underneath

        compose.onNodeWithTag("row-preferences").performClick()
        compose.onNodeWithTag(ShellTags.SHEET_SCRIM).assertDoesNotExist()
        compose.onNodeWithText("Choose a photo").assertDoesNotExist()
        compose.onNodeWithText("Appearance".uppercase()).assertIsDisplayed()

        compose.onNodeWithTag("page-navigation").performClick() // back to the More sheet
        assertEquals(MorePage.MORE, nav.morePage)
        compose.onNodeWithTag("page-navigation").performClick() // ✕ closes it
        assertEquals(AppNavState(), nav)
    }

    @Test
    fun `Preferences change Appearance, border and the two independent switches`() {
        show(start = AppNavigator.openPage(AppNavState(), MorePage.PREFERENCES))

        compose.onNodeWithTag("segment-Dark").performClick()
        assertEquals(Appearance.DARK, preferences.appearance)
        compose.onNodeWithTag("segment-Dark").assertIsSelected()

        compose.onNodeWithTag(ShellTags.KEEP_METADATA).performScrollTo().assertIsOn()
        compose.onNodeWithTag(ShellTags.INCLUDE_LOCATION).performScrollTo().assertIsOff()
        compose.onNodeWithTag(ShellTags.INCLUDE_LOCATION).performClick()
        assertEquals(true to true, preferences.keepPhotoMetadata to preferences.includeLocation)
        compose.onNodeWithTag(ShellTags.KEEP_METADATA).performClick()
        assertEquals(false to true, preferences.keepPhotoMetadata to preferences.includeLocation)

        compose.onNodeWithTag("row-preferred-border").performScrollTo().performClick()
        compose.onNodeWithTag("border-polaroid").performClick()
        assertEquals(PreferredBorder.POLAROID, preferences.preferredBorder)
    }

    @Test
    fun `favourites show catalogue names, remove, and say how many are free`() {
        preferences = UserPreferences(favouritePresetIds = listOf("look-1", "look-2"))
        show(start = AppNavigator.openPage(AppNavState(), MorePage.FAVOURITES))

        compose.onNodeWithText("01 Fitness 01").assertIsDisplayed()
        compose.onNodeWithText("3 free. Star a preset in Develop to add it.").assertIsDisplayed()
        compose.onNodeWithTag("favourite-remove-0").performClick()
        assertEquals(listOf("look-2"), preferences.favouritePresetIds)
        compose.onNodeWithText("4 free. Star a preset in Develop to add it.").assertIsDisplayed()
    }

    @Test
    fun `About shows the build version and Support offers no invented destination`() {
        show(start = AppNavigator.openPage(AppNavState(), MorePage.ABOUT))

        compose.onNodeWithText("Version 1.0 (1)").assertIsDisplayed()
        compose.onNodeWithTag("row-support").performClick()
        compose.onNodeWithText(ReleaseText.UNAVAILABLE_SUPPORT).assertIsDisplayed()
        compose.onNodeWithText("Contact support").assertDoesNotExist()
    }

    @Test
    fun `signature page has the structure but no mock signature`() {
        show(start = AppNavigator.openPage(AppNavState(), MorePage.SIGNATURE))

        compose.onNodeWithText("Draw a new signature").assertIsDisplayed()
        compose.onNodeWithText("Import from a photo").assertIsDisplayed()
        compose.onNodeWithText("Delete saved signature").assertDoesNotExist()
    }

    @Test
    fun `camera denied offers Settings and the picker`() {
        show(start = AppNavigator.showCameraDenied())

        compose.onNodeWithText("Camera access is off").assertIsDisplayed()
        compose.onNodeWithTag(ShellTags.MESSAGE_PRIMARY).performClick()
        compose.onNodeWithTag(ShellTags.MESSAGE_SECONDARY).performClick()
        assertEquals(listOf("settings", "choosePhoto"), calls)
        compose.onNodeWithTag(ShellTags.BACK).performClick()
        assertEquals(AppNavState(), nav)
    }

    @Test
    fun `load failed offers another photo and a retry`() {
        show(start = AppNavigator.showLoadFailed())

        compose.onNodeWithText("This photo can’t be opened").assertIsDisplayed()
        compose.onNodeWithTag(ShellTags.MESSAGE_PRIMARY).performClick()
        compose.onNodeWithTag(ShellTags.MESSAGE_SECONDARY).performClick()
        assertEquals(listOf("choosePhoto", "retry"), calls)
    }

    @Test
    @Config(qualifiers = "w800dp-h1280dp")
    fun `tablet - More pages are a centred form sheet over Welcome`() {
        show(layout = ShellLayout.Large, start = AppNavigator.openPage(AppNavState(), MorePage.PREFERENCES))

        compose.onNodeWithTag(ShellTags.SHEET_SCRIM).assertExists()
        compose.onNodeWithText("Choose a photo").assertExists()
        val page = compose.onNodeWithTag("more-page-preferences").getBoundsInRoot()
        val root = compose.onRoot().getBoundsInRoot()
        assertTrue(page.left.value > 100f && page.right.value < root.right.value - 100f, "centred and narrower than the window: $page")
    }

    @Test
    @Config(qualifiers = "w852dp-h883dp")
    fun `unfolded - Welcome splits at the fold and More stays in the right pane`() {
        show(layout = ShellLayout.SplitVertical(foldXDp = 426f))

        val brand = compose.onNodeWithText("Lightly").getBoundsInRoot()
        val actions = compose.onNodeWithTag(ShellTags.CHOOSE_PHOTO).getBoundsInRoot()
        assertTrue(brand.right.value <= 426f, "brand left of the fold: $brand")
        assertTrue(actions.left.value >= 426f, "actions right of the fold: $actions")

        compose.onNodeWithTag(ShellTags.MORE).performClick()
        val sheet = compose.onNodeWithTag("more-page-more").getBoundsInRoot()
        assertTrue(sheet.left.value >= 426f, "the More sheet never crosses the fold: $sheet")
    }

    @Test
    @Config(qualifiers = "w883dp-h852dp")
    fun `unfolded landscape - brand above the fold, actions below`() {
        show(layout = ShellLayout.SplitHorizontal(foldYDp = 426f))

        val brand = compose.onNodeWithText("Lightly").getBoundsInRoot()
        val actions = compose.onNodeWithTag(ShellTags.CHOOSE_PHOTO).getBoundsInRoot()
        assertTrue(brand.bottom.value <= 426f, "brand above the fold: $brand")
        assertTrue(actions.top.value >= 426f, "actions below the fold: $actions")
    }

    @Test
    @Config(qualifiers = "w427dp-h952dp")
    fun `large text keeps every Welcome action on screen`() {
        // Prototype "large" is ×1.24; Android's next step up is 1.3.
        show(fontScale = 1.3f)

        val root = compose.onRoot().getBoundsInRoot()
        listOf(ShellTags.CHOOSE_PHOTO, ShellTags.CAMERA, ShellTags.PRIVACY_LINK).forEach { tag ->
            val bounds = compose.onNodeWithTag(tag).getBoundsInRoot()
            assertTrue(bounds.bottom <= root.bottom, "$tag is on screen at 1.3× text: $bounds")
        }
    }
}
