package com.lightlylabs.lightly.editor

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri

/**
 * [PhotoAccessGrants] backed by the platform's persistable URI permissions
 * (developer.android.com/training/data-storage/shared/photo-picker#persist-media-file-access).
 *
 * Only READ is requested: the editor never writes to the original (Save copy inserts a new item).
 */
class ContentResolverPhotoAccessGrants internal constructor(private val permissions: PersistableReadPermissions) : PhotoAccessGrants {

    constructor(resolver: ContentResolver) : this(ResolverReadPermissions(resolver))

    /** Seam over the two ContentResolver calls, so the SecurityException paths are testable. */
    internal interface PersistableReadPermissions {
        fun take(uri: Uri)
        fun release(uri: Uri)
    }

    override fun retain(assetId: String): Boolean = try {
        permissions.take(Uri.parse(assetId))
        true
    } catch (notPersistable: SecurityException) {
        // The URI was handed out without FLAG_GRANT_PERSISTABLE_URI_PERMISSION (seen with some
        // API 29 picker fallbacks). Editing still works in this process; a later restore reports
        // PhotoAccessLost and offers to choose the photo again.
        false
    }

    override fun release(assetId: String) {
        try {
            permissions.release(Uri.parse(assetId))
        } catch (noGrantHeld: SecurityException) {
            // Nothing was persisted for this URI (retain returned false, or it was already
            // revoked). Releasing is best effort: it only frees a slot under the per-app cap.
        }
    }

    private class ResolverReadPermissions(private val resolver: ContentResolver) : PersistableReadPermissions {
        override fun take(uri: Uri) = resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        override fun release(uri: Uri) = resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
}
