package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.session.LookRef

/**
 * How a saved [LookRef] resolves against this build's pack (shared/fixtures/edit-state/README.md).
 * Resolution is by exact `lookId`, then exact `lookVersion`; another Look is never substituted.
 */
sealed interface LookResolution {
    /** Both match: the Look renders normally. */
    data class Available(val definition: LookDefinition) : LookResolution

    /** The pack has no Look with this ID. */
    data class Unavailable(val saved: LookRef) : LookResolution

    /** The pack has this Look, at another version (every migrated `legacy-v1-*` edit lands here). */
    data class Changed(val saved: LookRef, val current: LookDefinition) : LookResolution
}

/**
 * Why the committed Look is not rendered. Shown as a notice for as long as the edit holds that Look,
 * including after Save copy, because the export matches the screen (without the Look).
 */
sealed interface LookIssue {
    val saved: LookRef
    val notice: String

    /** Only a changed Look can be brought up to date; an unavailable one has nothing to switch to. */
    val offersCurrentVersion: Boolean

    data class Unavailable(override val saved: LookRef) : LookIssue {
        override val notice: String get() = UNAVAILABLE_NOTICE
        override val offersCurrentVersion: Boolean get() = false
    }

    data class Changed(override val saved: LookRef, val currentVersion: String) : LookIssue {
        override val notice: String get() = CHANGED_NOTICE
        override val offersCurrentVersion: Boolean get() = true
    }

    companion object {
        const val UNAVAILABLE_NOTICE = "This Look isn't in this version of Lightly. The photo is shown without it."
        const val CHANGED_NOTICE = "This Look has changed since this edit. The photo is shown without it."
        const val USE_CURRENT_VERSION = "Use current version"

        fun of(resolution: LookResolution?): LookIssue? = when (resolution) {
            null, is LookResolution.Available -> null
            is LookResolution.Unavailable -> Unavailable(resolution.saved)
            is LookResolution.Changed -> Changed(resolution.saved, resolution.current.lookVersion)
        }
    }
}
