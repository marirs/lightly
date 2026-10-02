package com.lightlylabs.lightly.editor

import java.io.FileNotFoundException
import java.io.IOException

/**
 * Read access to the picked photo beyond the picker's temporary grant (Codex finding 4).
 *
 * A Photo Picker (or ACTION_OPEN_DOCUMENT fallback) URI is readable only until the app process
 * ends. The editor saves the URI for process-death restore, so it must persist a read grant when
 * the photo is picked, and give the previous photo's grant back when the user moves on: the
 * platform caps persisted grants per app (128 before API 30, 512 from API 30).
 */
interface PhotoAccessGrants {
    /**
     * Persists read access to [assetId]. Returns false when the grant cannot be persisted (for
     * example a picker fallback on API 29 that hands out a non-persistable URI). The photo is still
     * readable for the rest of this process; only a restore after process death can then fail,
     * which the editor reports as [EditorPhase.PhotoAccessLost].
     */
    fun retain(assetId: String): Boolean

    /** Gives back a grant taken by [retain]. A no-op when no grant is held; never throws. */
    fun release(assetId: String)
}

/**
 * The photo can no longer be read: the grant was never persisted, was revoked, or the item was
 * deleted. The editor offers to choose the photo again instead of a generic LoadFailed.
 */
class PhotoAccessLostException(cause: Throwable) : IOException("This photo is no longer available to Lightly.", cause) {
    companion object {
        /**
         * A SecurityException ("Permission Denial") means the grant is gone; FileNotFoundException
         * means the provider no longer serves the item. Both can be wrapped by ImageDecoder or the
         * resolver, so the whole cause chain is checked.
         */
        fun isAccessLoss(failure: Throwable): Boolean =
            generateSequence(failure) { it.cause }.any { it is SecurityException || it is FileNotFoundException }
    }
}
