package com.lightlylabs.lightly.shell

import android.content.Intent
import com.lightlylabs.lightly.BuildConfig
import com.lightlylabs.lightly.editor.AutoState
import com.lightlylabs.lightly.editor.DevelopUi
import com.lightlylabs.lightly.editor.EditorOverlay
import com.lightlylabs.lightly.editor.EditorPhase
import com.lightlylabs.lightly.editor.EditorViewModel
import com.lightlylabs.lightly.editor.PersonPresence
import java.io.File
import com.lightlylabs.lightly.prefs.Appearance
import com.lightlylabs.lightly.prefs.PreferencesStore

/**
 * Debug builds only: opens a given slice-1 screen directly, so the scripted emulator comparison can
 * capture every screen without tapping through. Release builds ignore the extras entirely
 * (BuildConfig.DEBUG is a compile-time false there, so this is dead code R8 removes).
 *
 * ```
 * adb shell am start -n com.lightlylabs.lightly/.MainActivity \
 *   --es lightly.debug.screen preferences --es lightly.debug.favourites look-a,look-b \
 *   --es lightly.debug.appearance dark
 * ```
 * Screens: welcome, camera-denied, load-failed, and every [MorePage] name in lower case
 * (more, preferences, favourites, signature, preferred_border, legal, privacy, terms, about, support).
 *
 * Slice 2 editor states: `--es lightly.debug.photo <absolute path in the app's external files folder>`
 * opens that file as the photo, `--es lightly.debug.editor <prototype screen id>` (dev-preset, dev-amount, …)
 * sets the session as the prototype's screen registry does, and `--es lightly.debug.people present|absent`
 * stands in for the pending person detector (D3) so Portrait matches the reference photo.
 *
 * Every Auto state other than "unavailable" is INJECTED here for layout comparison only: no Auto model
 * ships (D1), so the photo is never corrected; captures made this way are labelled in
 * docs/v1/slice2-android.md.
 */
object DebugLaunchOptions {
    private const val EXTRA_SCREEN = "lightly.debug.screen"
    private const val EXTRA_FAVOURITES = "lightly.debug.favourites"
    private const val EXTRA_APPEARANCE = "lightly.debug.appearance"

    private const val EXTRA_PHOTO = "lightly.debug.photo"
    private const val EXTRA_EDITOR = "lightly.debug.editor"
    private const val EXTRA_PEOPLE = "lightly.debug.people"

    /** One capture state, read from launch extras or (persistent capture runner) a broadcast's extras. */
    data class Request(
        val screen: String?,
        val photo: String?,
        val editor: String?,
        val people: String?,
        val favourites: String?,
        val appearance: String?,
        val benchmark: Boolean = false,
    ) {
        companion object {
            fun from(intent: Intent) = Request(
                screen = intent.getStringExtra(EXTRA_SCREEN),
                photo = intent.getStringExtra(EXTRA_PHOTO),
                editor = intent.getStringExtra(EXTRA_EDITOR),
                people = intent.getStringExtra(EXTRA_PEOPLE),
                favourites = intent.getStringExtra(EXTRA_FAVOURITES),
                appearance = intent.getStringExtra(EXTRA_APPEARANCE),
                benchmark = intent.getBooleanExtra("lightly.debug.benchmark", false),
            )
        }
    }

    fun apply(intent: Intent?, shell: AppViewModel, preferences: PreferencesStore, editor: EditorViewModel): kotlinx.coroutines.Job? {
        if (!BuildConfig.DEBUG || intent == null) return null
        return apply(Request.from(intent), shell, preferences, editor)
    }

    /**
     * Applies [request] to freshly created view models. Returns the job that finishes when the editor
     * state is configured (null when nothing asynchronous was started), so the capture runner can wait
     * for it before it waits for the render.
     */
    fun apply(request: Request, shell: AppViewModel, preferences: PreferencesStore, editor: EditorViewModel): kotlinx.coroutines.Job? {
        if (!BuildConfig.DEBUG) return null
        val editorJob = applyEditor(request, shell, editor)
        request.favourites?.let { ids ->
            preferences.update { it.copy(favouritePresetIds = ids.split(",").filter(String::isNotBlank).take(5)) }
        }
        // Lets the comparison switch light/dark in-app instead of toggling the system night mode,
        // which restarts System UI on every switch.
        request.appearance?.let { name ->
            Appearance.entries.firstOrNull { it.name.equals(name, ignoreCase = true) }?.let { appearance -> preferences.update { it.copy(appearance = appearance) } }
        }
        val screen = request.screen ?: return editorJob
        val state = when (screen) {
            "welcome" -> AppNavigator.toWelcome()
            "camera-denied" -> AppNavigator.showCameraDenied()
            "load-failed" -> AppNavigator.showLoadFailed()
            "welcome-privacy" -> AppNavigator.openPrivacyFromWelcome(AppNavigator.toWelcome())
            else -> MorePage.entries.firstOrNull { it.name.lowercase() == screen }?.let { AppNavigator.openPage(AppNavigator.toWelcome(), it) }
        } ?: return editorJob
        shell.navigate(state)
        return editorJob
    }

    private fun applyEditor(request: Request, shell: AppViewModel, editor: EditorViewModel): kotlinx.coroutines.Job? {
        val path = request.photo ?: return null
        val screen = request.editor ?: "model-unavailable"
        editor.debugPresence = when (request.people) {
            "present" -> PersonPresence.PRESENT
            "absent" -> PersonPresence.ABSENT
            else -> null
        }
        editor.debugHoldLoading = screen == "loading" || screen == "developing"
        editor.debugHoldSeparation = screen == "bg-separating"
        editor.openPhoto("file://" + File(path).absolutePath)
        shell.navigate(if (screen == "more") AppNavigator.openMore(AppNavigator.openEditor()) else AppNavigator.openEditor())
        if (screen == "developing") {
            editor.debugSetPhase(EditorPhase.Developing)
            return null
        }
        if (screen == "loading") return null
        if (request.benchmark) {
            editor.debugBenchmark { line -> android.util.Log.i("LightlyBench", line) }
            return null
        }
        return editor.applyDebugState { api ->
            val auto = when (screen) {
                "model-unavailable" -> AutoState.UNAVAILABLE
                "develop-failed" -> AutoState.FAILED
                "dev-original" -> AutoState.OFF
                else -> AutoState.APPLIED // injected, see the class comment
            }
            api.setAuto(auto)
            fun preset(category: String, stop: Int, amount: Int = 100) = api.applyPreset(category, stop, amount)
            when (screen) {
                "developed" -> api.setUi { it.copy(toast = "Developed") }
                "dev-preset", "compare", "saving", "saved", "leave-unsaved", "more", "dev-starred" -> preset("landscape", 37)
                "dev-dragging" -> {
                    preset("landscape", 37)
                    val target = api.library?.pack?.category("landscape")?.presets?.getOrNull(40)
                    api.setUi { it.copy(develop = DevelopUi(dragStop = 41, fine = true)) }
                    target?.let { api.preview(globalOnly = true, look = com.lightlylabs.lightly.session.LookRef(it.id, it.lookVersion, 1f)) }
                }
                "dev-browse" -> { preset("landscape", 37); api.setUi { it.copy(develop = DevelopUi(category = "cinematic", dragStop = 0)) } }
                "dev-large" -> preset("cinematic", 564)
                "dev-long-name" -> {
                    val stop = api.library?.pack?.category("landscape")?.presets?.indexOfFirst { it.displayName == "Landscape 15 - Winter Wonderland" }?.plus(1) ?: 0
                    if (stop > 0) preset("landscape", stop)
                }
                "dev-amount" -> { preset("landscape", 37, amount = 70); api.setUi { it.copy(develop = DevelopUi(amountOpen = true), rememberedAmounts = emptyMap()) } }
                "dev-favourites" -> { preset("portrait", 13); api.setUi { it.copy(develop = DevelopUi(category = "favourites")) } }
                "dev-fav-full" -> { preset("travel", 5); api.setUi { it.copy(develop = DevelopUi(favouritesFull = true)) } }
                "dev-fav-replace" -> { preset("travel", 5); api.setUi { it.copy(overlay = EditorOverlay.FAVOURITE_REPLACE) } }
                "dev-bw" -> preset("black-white", 8)
                "dev-landscape-photo" -> preset("golden-hour", 12)
                "dev-portrait-photo", "bg-failed" -> preset("portrait", 13)
            }
            // History starts at the configured recipe (Undo disabled, as on the prototype's screens);
            // "Leaving with unsaved changes" keeps the recipe unsaved.
            api.rebaseHistory(keepUnsaved = screen == "leave-unsaved")
            when (screen) {
                "compare" -> api.setUi { it.copy(compareToggled = true) }
                "saving" -> api.setUi { it.copy(overlay = EditorOverlay.SAVING) }
                "saved" -> api.setUi { it.copy(overlay = EditorOverlay.SAVED) }
                "leave-unsaved" -> api.setUi { it.copy(overlay = EditorOverlay.LEAVE) }
                // Slice 3: real separation on this build (no depth model, no segmenter: D3 / LiteRT
                // pending), so bg-failed is the state a user actually sees, not an injected one.
                "bg-separating", "bg-failed" -> api.openBackground(com.lightlylabs.lightly.editor.BackgroundSub.CHANGE)
                "bg-no-subject" -> api.openBackground(com.lightlylabs.lightly.editor.BackgroundSub.FOCUS)
                // docs/ui/app/screens.js: blur 55, and the style for bg-soft / bg-swirl / bg-motion.
                "bg-focus", "bg-soft", "bg-swirl", "bg-motion" -> {
                    val style = when (screen) {
                        "bg-soft" -> com.lightlylabs.lightly.session.FocusStyle.SOFT
                        "bg-swirl" -> com.lightlylabs.lightly.session.FocusStyle.SWIRL
                        "bg-motion" -> com.lightlylabs.lightly.session.FocusStyle.MOTION
                        else -> null
                    }
                    api.openBackground(com.lightlylabs.lightly.editor.BackgroundSub.FOCUS) { api.focus(55.0, style); api.rebaseHistory() }
                }
            }
        }
    }
}
