package com.lightlylabs.lightly.shell

/**
 * The pages reachable from ⋮ More, with the page each one returns to (prototype morePage `back`).
 * Titles are the approved ones verbatim.
 */
enum class MorePage(val title: String, val parent: MorePage?) {
    MORE("More", null),
    PREFERENCES("Preferences", MORE),
    FAVOURITES("Favourite presets", PREFERENCES),
    SIGNATURE("Saved signature", PREFERENCES),
    PREFERRED_BORDER("Preferred border", PREFERENCES),
    LEGAL("Legal", MORE),
    PRIVACY("Privacy Policy", LEGAL),
    TERMS("Terms of Use", LEGAL),
    ABOUT("About", MORE),
    SUPPORT("Support", ABOUT),
}

/** The full-screen destination underneath any More page. */
enum class BaseScreen { WELCOME, EDITOR, CAMERA_DENIED, LOAD_FAILED }

/**
 * Where the app is. [morePage] is shown above [base] (as a page on phones, a sheet elsewhere; see
 * [ShellLayout]). [privacyFromWelcome] records that Privacy Policy was opened from Welcome's link, so
 * its Back returns straight to Welcome instead of to Legal (prototype `closeWelcomePrivacy`).
 */
data class AppNavState(
    val base: BaseScreen = BaseScreen.WELCOME,
    val morePage: MorePage? = null,
    val privacyFromWelcome: Boolean = false,
)

/**
 * Pure navigation rules, so the JVM tests can check every transition. No Android types.
 *
 * Opening a photo is not a navigation decision made here: the caller hands the URI to the editor and
 * then calls [openEditor]. A cancelled picker or camera simply never calls anything, which is how
 * "cancellation returns unchanged" holds.
 */
object AppNavigator {
    fun openMore(state: AppNavState) = state.copy(morePage = MorePage.MORE, privacyFromWelcome = false)

    fun openPage(state: AppNavState, page: MorePage) = state.copy(morePage = page, privacyFromWelcome = false)

    /** Welcome's Privacy Policy link: the policy, then straight back to Welcome. */
    fun openPrivacyFromWelcome(state: AppNavState) = state.copy(morePage = MorePage.PRIVACY, privacyFromWelcome = true)

    /** The close (✕) on the root More page, or a tap on the scrim. */
    fun closeMore(state: AppNavState) = state.copy(morePage = null, privacyFromWelcome = false)

    fun openEditor() = AppNavState(base = BaseScreen.EDITOR)

    fun showCameraDenied() = AppNavState(base = BaseScreen.CAMERA_DENIED)

    fun showLoadFailed() = AppNavState(base = BaseScreen.LOAD_FAILED)

    fun toWelcome() = AppNavState(base = BaseScreen.WELCOME)

    /**
     * System Back. Returns null when Back should leave the app (Welcome with nothing open). In the
     * editor with nothing open above it, the Activity asks the editor first (it may show the approved
     * "Leave without saving?" dialog) and only then calls this.
     */
    fun back(state: AppNavState): AppNavState? {
        val page = state.morePage
        return when {
            page == MorePage.PRIVACY && state.privacyFromWelcome -> closeMore(state)
            page != null -> state.copy(morePage = page.parent)
            state.base != BaseScreen.WELCOME -> toWelcome()
            else -> null
        }
    }

    /** Compact encoding for SavedStateHandle (survives process death). */
    fun encode(state: AppNavState): String = listOf(state.base.name, state.morePage?.name.orEmpty(), state.privacyFromWelcome.toString()).joinToString("|")

    fun decode(encoded: String?): AppNavState {
        val parts = encoded?.split("|") ?: return AppNavState()
        if (parts.size != 3) return AppNavState()
        return AppNavState(
            base = BaseScreen.entries.firstOrNull { it.name == parts[0] } ?: BaseScreen.WELCOME,
            morePage = MorePage.entries.firstOrNull { it.name == parts[1] },
            privacyFromWelcome = parts[2].toBoolean(),
        )
    }
}
