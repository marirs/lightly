package com.lightlylabs.lightly.prefs

import android.content.SharedPreferences
import com.lightlylabs.lightly.export.MetadataPolicy
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Preferences › Appearance. Applies app-wide and immediately. */
enum class Appearance { SYSTEM, LIGHT, DARK }

/** Preferences › Preferred border. It only decides which Border option opens first; never applied automatically. */
enum class PreferredBorder(val label: String) {
    NONE("None"),
    SOLID("Solid"),
    PHOTO_FRAME("Photo Frame"),
    POLAROID("Polaroid"),
}

/**
 * Everything the user sets in Preferences. Defaults are the approved ones: System appearance, no
 * favourites, border None, Keep photo metadata ON, Include location OFF.
 */
data class UserPreferences(
    val appearance: Appearance = Appearance.SYSTEM,
    /** Preset ids from presets/develop-design-ui.json, in the user's order. At most [MAX_FAVOURITES]. */
    val favouritePresetIds: List<String> = emptyList(),
    val preferredBorder: PreferredBorder = PreferredBorder.NONE,
    val keepPhotoMetadata: Boolean = true,
    val includeLocation: Boolean = false,
) {
    /** The two switches are independent: location is never implied by keeping metadata. */
    val metadataPolicy: MetadataPolicy get() = MetadataPolicy(keepPhotoMetadata = keepPhotoMetadata, includeLocation = includeLocation)

    val favouritesAreFull: Boolean get() = favouritePresetIds.size >= MAX_FAVOURITES

    /**
     * Adds [presetId] at the end. Returns this unchanged when it is already a favourite or the list
     * is full: replacing one is an explicit user choice (Develop's "Replace a favourite", slice 2).
     */
    fun withFavouriteAdded(presetId: String): UserPreferences =
        if (presetId in favouritePresetIds || favouritesAreFull) this else copy(favouritePresetIds = favouritePresetIds + presetId)

    fun withFavouriteRemoved(presetId: String): UserPreferences = copy(favouritePresetIds = favouritePresetIds - presetId)

    /** Moves the favourite at [fromIndex] to [toIndex] (both clamped); the order is the shortcut order. */
    fun withFavouriteMoved(fromIndex: Int, toIndex: Int): UserPreferences {
        if (fromIndex !in favouritePresetIds.indices) return this
        val reordered = favouritePresetIds.toMutableList()
        val moved = reordered.removeAt(fromIndex)
        reordered.add(toIndex.coerceIn(0, reordered.size), moved)
        return copy(favouritePresetIds = reordered)
    }

    companion object {
        const val MAX_FAVOURITES = 5
    }
}

/** The app's preference store: one observable value, changed only through [update]. */
interface PreferencesStore {
    val preferences: StateFlow<UserPreferences>
    fun update(change: (UserPreferences) -> UserPreferences)
}

/**
 * [PreferencesStore] on SharedPreferences. DataStore is not a project dependency and slice 1 adds no
 * downloads, so the platform store is used; every write is `apply()` (async to disk, immediate in
 * memory) and the in-memory value is the source of truth for the UI.
 */
class SharedPreferencesStore(private val sharedPreferences: SharedPreferences) : PreferencesStore {

    private val state = MutableStateFlow(read())
    override val preferences: StateFlow<UserPreferences> = state.asStateFlow()

    override fun update(change: (UserPreferences) -> UserPreferences) {
        val updated = synchronized(this) {
            change(state.value).also { state.value = it }
        }
        write(updated)
    }

    private fun read(): UserPreferences {
        val defaults = UserPreferences()
        return UserPreferences(
            appearance = enumOrDefault(sharedPreferences.getString(KEY_APPEARANCE, null), defaults.appearance),
            favouritePresetIds = sharedPreferences.getString(KEY_FAVOURITES, null)
                ?.split(FAVOURITE_SEPARATOR)?.filter { it.isNotBlank() }?.distinct()?.take(UserPreferences.MAX_FAVOURITES)
                ?: defaults.favouritePresetIds,
            preferredBorder = enumOrDefault(sharedPreferences.getString(KEY_BORDER, null), defaults.preferredBorder),
            keepPhotoMetadata = sharedPreferences.getBoolean(KEY_KEEP_METADATA, defaults.keepPhotoMetadata),
            includeLocation = sharedPreferences.getBoolean(KEY_INCLUDE_LOCATION, defaults.includeLocation),
        )
    }

    private fun write(preferences: UserPreferences) {
        sharedPreferences.edit()
            .putString(KEY_APPEARANCE, preferences.appearance.name)
            .putString(KEY_FAVOURITES, preferences.favouritePresetIds.joinToString(FAVOURITE_SEPARATOR))
            .putString(KEY_BORDER, preferences.preferredBorder.name)
            .putBoolean(KEY_KEEP_METADATA, preferences.keepPhotoMetadata)
            .putBoolean(KEY_INCLUDE_LOCATION, preferences.includeLocation)
            .apply()
    }

    private inline fun <reified E : Enum<E>> enumOrDefault(stored: String?, default: E): E =
        enumValues<E>().firstOrNull { it.name == stored } ?: default

    companion object {
        const val FILE_NAME = "lightly_preferences"
        // Preset ids are "look-<hex>" (develop-design-ui.json), so a comma can never occur in one.
        private const val FAVOURITE_SEPARATOR = ","
        private const val KEY_APPEARANCE = "appearance"
        private const val KEY_FAVOURITES = "favourite_preset_ids"
        private const val KEY_BORDER = "preferred_border"
        private const val KEY_KEEP_METADATA = "keep_photo_metadata"
        private const val KEY_INCLUDE_LOCATION = "include_location"
    }
}
