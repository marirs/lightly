package com.lightlylabs.lightly.prefs

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.lightlylabs.lightly.export.MetadataPolicy
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Preferences persistence, defaults, favourites rules, the bundled catalogue and release text. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PreferencesTest {

    private val context: Context = ApplicationProvider.getApplicationContext()

    /** A new store over the same file: what the next launch reads. */
    private fun relaunch() = SharedPreferencesStore(context.getSharedPreferences(SharedPreferencesStore.FILE_NAME, Context.MODE_PRIVATE))

    @Test
    fun `defaults are the approved ones`() {
        val preferences = relaunch().preferences.value

        assertEquals(Appearance.SYSTEM, preferences.appearance)
        assertEquals(emptyList(), preferences.favouritePresetIds)
        assertEquals(PreferredBorder.NONE, preferences.preferredBorder)
        assertTrue(preferences.keepPhotoMetadata, "Keep photo metadata is on by default")
        assertEquals(false, preferences.includeLocation, "Include location is off by default")
        assertEquals(MetadataPolicy(keepPhotoMetadata = true, includeLocation = false), preferences.metadataPolicy)
    }

    @Test
    fun `every preference persists across launches`() {
        relaunch().update {
            it.copy(appearance = Appearance.DARK, preferredBorder = PreferredBorder.POLAROID, keepPhotoMetadata = false, includeLocation = true)
                .withFavouriteAdded("look-a").withFavouriteAdded("look-b")
        }

        val reread = relaunch().preferences.value

        assertEquals(Appearance.DARK, reread.appearance)
        assertEquals(PreferredBorder.POLAROID, reread.preferredBorder)
        assertEquals(listOf("look-a", "look-b"), reread.favouritePresetIds)
        assertEquals(MetadataPolicy(keepPhotoMetadata = false, includeLocation = true), reread.metadataPolicy)
    }

    @Test
    fun `the two metadata switches are independent in all four combinations`() {
        val store = relaunch()
        for (keep in listOf(true, false)) {
            for (location in listOf(true, false)) {
                store.update { it.copy(keepPhotoMetadata = keep, includeLocation = location) }
                assertEquals(MetadataPolicy(keep, location), relaunch().preferences.value.metadataPolicy)
            }
        }
        // Turning one off never changes the other.
        store.update { it.copy(keepPhotoMetadata = true, includeLocation = true) }
        store.update { it.copy(keepPhotoMetadata = false) }
        assertTrue(relaunch().preferences.value.includeLocation)
    }

    @Test
    fun `favourites hold at most five, never duplicate, and reorder`() {
        var preferences = UserPreferences()
        listOf("a", "b", "c", "d", "e", "f", "a").forEach { preferences = preferences.withFavouriteAdded(it) }

        assertEquals(listOf("a", "b", "c", "d", "e"), preferences.favouritePresetIds, "a sixth star needs an explicit replace (slice 2)")
        assertEquals(listOf("b", "c", "a", "d", "e"), preferences.withFavouriteMoved(0, 2).favouritePresetIds)
        assertEquals(listOf("e", "a", "b", "c", "d"), preferences.withFavouriteMoved(4, -3).favouritePresetIds)
        assertEquals(listOf("a", "b", "d", "e"), preferences.withFavouriteRemoved("c").favouritePresetIds)
    }

    @Test
    fun `a corrupted stored value falls back to the default`() {
        context.getSharedPreferences(SharedPreferencesStore.FILE_NAME, Context.MODE_PRIVATE).edit()
            .putString("appearance", "PURPLE").putString("preferred_border", "").commit()

        val preferences = relaunch().preferences.value

        assertEquals(Appearance.SYSTEM, preferences.appearance)
        assertEquals(PreferredBorder.NONE, preferences.preferredBorder)
    }

    @Test
    fun `the approved catalogue resolves preset ids to names and categories`() {
        val catalogue = PresetCatalogue.parse(File(System.getProperty("lightly.presetCatalogue")!!).readText())

        assertEquals(2591, catalogue.size)
        val first = catalogue.preset("look-b101de2ee5d340ac5621")!!
        assertEquals("01 Fitness 01", first.displayName)
        assertEquals("Portrait", first.categoryName)
        assertNull(catalogue.preset("look-not-in-catalogue"))
    }

    @Test
    fun `the shipped release text is the website's Privacy Policy and Terms, with Support at hello@lightly_pro`() {
        // Generated from lightly.pro's privacy.md and terms.md by scripts/make_release_text.py; never placeholder text.
        val text = ReleaseText.parse(File("src/main/assets/legal/release-text.json").readText())
        val privacy = text.privacyPolicy!!.sections
        val terms = text.termsOfUse!!.sections
        assertTrue(privacy.any { it.heading == "Editing on your device" })
        assertTrue(terms.any { it.heading == "Your photographs" })
        assertEquals("https://lightly.pro/support", text.supportDestination)
        val all = (privacy + terms).joinToString(" ") { it.body }
        for (marker in listOf("[OWNER", "lorem", "TODO", "](http")) assertTrue(marker !in all, marker)
    }

    @Test
    fun `supplied release text is read section by section`() {
        val text = ReleaseText.parse(
            """{"privacyPolicy":{"sections":[{"heading":"H","body":"B"},{"heading":"","body":" "}]},"supportDestination":"mailto:x@example.com"}""",
        )

        assertEquals(listOf(TextSection("H", "B")), text.privacyPolicy!!.sections)
        assertNull(text.termsOfUse)
        assertEquals("mailto:x@example.com", text.supportDestination)
    }
}
