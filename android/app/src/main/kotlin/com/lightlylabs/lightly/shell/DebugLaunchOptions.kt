package com.lightlylabs.lightly.shell

import android.content.Intent
import com.lightlylabs.lightly.BuildConfig
import com.lightlylabs.lightly.prefs.PreferencesStore

/**
 * Debug builds only: opens a given slice-1 screen directly, so the scripted emulator comparison can
 * capture every screen without tapping through. Release builds ignore the extras entirely
 * (BuildConfig.DEBUG is a compile-time false there, so this is dead code R8 removes).
 *
 * ```
 * adb shell am start -n com.lightlylabs.lightly/.MainActivity \
 *   --es lightly.debug.screen preferences --es lightly.debug.favourites look-a,look-b
 * ```
 * Screens: welcome, camera-denied, load-failed, and every [MorePage] name in lower case
 * (more, preferences, favourites, signature, preferred_border, legal, privacy, terms, about, support).
 */
object DebugLaunchOptions {
    private const val EXTRA_SCREEN = "lightly.debug.screen"
    private const val EXTRA_FAVOURITES = "lightly.debug.favourites"

    fun apply(intent: Intent?, shell: AppViewModel, preferences: PreferencesStore) {
        if (!BuildConfig.DEBUG || intent == null) return
        intent.getStringExtra(EXTRA_FAVOURITES)?.let { ids ->
            preferences.update { it.copy(favouritePresetIds = ids.split(",").filter(String::isNotBlank).take(5)) }
        }
        val screen = intent.getStringExtra(EXTRA_SCREEN) ?: return
        val state = when (screen) {
            "welcome" -> AppNavigator.toWelcome()
            "camera-denied" -> AppNavigator.showCameraDenied()
            "load-failed" -> AppNavigator.showLoadFailed()
            "welcome-privacy" -> AppNavigator.openPrivacyFromWelcome(AppNavigator.toWelcome())
            else -> MorePage.entries.firstOrNull { it.name.lowercase() == screen }?.let { AppNavigator.openPage(AppNavigator.toWelcome(), it) }
        } ?: return
        shell.navigate(state)
    }
}
