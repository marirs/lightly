package com.lightlylabs.lightly.editor

import android.app.Application
import android.content.ContentProvider
import android.content.ContentValues
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.test.core.app.ApplicationProvider
import com.lightlylabs.lightly.decode.ProxyDecoder
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.FileNotFoundException
import kotlin.test.assertFailsWith

/**
 * The production loader turns "this URI can no longer be read" into [PhotoAccessLostException], so a
 * restore after process death with a revoked or never-persisted grant becomes the recoverable
 * PhotoAccessLost phase instead of a generic LoadFailed (Codex finding 4).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ContentResolverPhotoLoaderTest {

    /** A provider that refuses every read the way MediaProvider does without a grant, or that lost the item. */
    abstract class RefusingProvider(private val refusal: () -> Exception) : ContentProvider() {
        override fun onCreate() = true
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = throw refusal()
        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor = throw refusal()
        override fun openAssetFile(uri: Uri, mode: String): AssetFileDescriptor = throw refusal()
        override fun openTypedAssetFile(uri: Uri, mimeTypeFilter: String, opts: android.os.Bundle?): AssetFileDescriptor = throw refusal()
        override fun getType(uri: Uri): String = "image/jpeg"
        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    }

    class RevokedGrantProvider : RefusingProvider({ SecurityException("Permission Denial: opening provider requires a grant") })
    class DeletedItemProvider : RefusingProvider({ FileNotFoundException("No item at this Uri") })

    private val resolver = ApplicationProvider.getApplicationContext<Application>().contentResolver
    private val loader = ContentResolverPhotoLoader(resolver, ProxyDecoder(), screenLongestPx = 1080)

    @Test
    fun `a revoked grant is reported as access lost`() {
        Robolectric.setupContentProvider(RevokedGrantProvider::class.java, "revoked.test")
        assertFailsWith<PhotoAccessLostException> { runBlocking { loader.load("content://revoked.test/media/1000") } }
    }

    @Test
    fun `a deleted item is reported as access lost`() {
        Robolectric.setupContentProvider(DeletedItemProvider::class.java, "deleted.test")
        assertFailsWith<PhotoAccessLostException> { runBlocking { loader.load("content://deleted.test/media/1000") } }
    }
}
