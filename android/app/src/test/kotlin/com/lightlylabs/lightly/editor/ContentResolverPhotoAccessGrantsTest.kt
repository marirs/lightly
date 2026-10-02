package com.lightlylabs.lightly.editor

import android.app.Application
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.FileNotFoundException
import java.io.IOException
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Persistable read grants for picked photos (Codex finding 4), on Robolectric's ContentResolver. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29, 34])
class ContentResolverPhotoAccessGrantsTest {

    private val resolver = ApplicationProvider.getApplicationContext<Application>().contentResolver
    private val photo = "content://media/picker/0/com.android.providers.media.photopicker/media/1000"

    @Test
    fun `retain takes a persistable read grant for the picked photo`() {
        val retained = ContentResolverPhotoAccessGrants(resolver).retain(photo)

        assertTrue(retained)
        val grant = resolver.persistedUriPermissions.single()
        assertEquals(Uri.parse(photo), grant.uri)
        assertTrue(grant.isReadPermission)
        assertFalse(grant.isWritePermission, "the editor never writes to the original")
    }

    @Test
    fun `release gives the persisted grant back`() {
        val grants = ContentResolverPhotoAccessGrants(resolver)
        grants.retain(photo)

        grants.release(photo)

        assertTrue(resolver.persistedUriPermissions.isEmpty())
    }

    @Test
    fun `a grant that cannot be persisted is reported, not thrown`() {
        val denying = object : ContentResolverPhotoAccessGrants.PersistableReadPermissions {
            override fun take(uri: Uri) = throw SecurityException("No persistable permission grants found for UID 10123 and Uri $uri")
            override fun release(uri: Uri) = throw SecurityException("No permission grants found for UID 10123 and Uri $uri")
        }
        val grants = ContentResolverPhotoAccessGrants(denying)

        assertFalse(grants.retain(photo))
        grants.release(photo) // must not throw either
    }

    @Test
    fun `security and missing-file failures anywhere in the cause chain are access loss`() {
        assertTrue(PhotoAccessLostException.isAccessLoss(SecurityException("Permission Denial")))
        assertTrue(PhotoAccessLostException.isAccessLoss(IOException("decode failed", FileNotFoundException("gone"))))
        assertFalse(PhotoAccessLostException.isAccessLoss(IOException("Couldn't open this photo")))
    }
}
