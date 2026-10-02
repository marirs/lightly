package com.lightlylabs.lightly.export

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import androidx.test.core.app.ApplicationProvider
import android.app.Application
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.io.IOException
import java.io.OutputStream
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * The real [ContentResolverGateway] against Android's ContentResolver, with a fake MediaStore
 * provider registered for the "media" authority. Verifies the exact column values (IS_PENDING=1 on
 * insert, 0 on publish) that a fake gateway cannot. Runs on API 29, the minimum SDK and the first
 * level with IS_PENDING.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [29])
class ContentResolverGatewayTest {

    /** Records every call; backs each inserted row with a temp file. */
    class FakeMediaProvider : ContentProvider() {
        val inserted = mutableListOf<Pair<Uri, ContentValues>>()
        val updated = mutableListOf<Pair<Uri, ContentValues>>()
        val deleted = mutableListOf<Uri>()
        val opened = mutableListOf<Pair<Uri, String>>()
        val files = mutableMapOf<Uri, File>()
        private var nextId = 1000

        override fun onCreate() = true

        override fun insert(uri: Uri, values: ContentValues?): Uri {
            val row = Uri.withAppendedPath(uri, (nextId++).toString())
            inserted += row to ContentValues(values)
            files[row] = File.createTempFile("mediastore-row", ".jpg")
            return row
        }

        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int {
            updated += uri to ContentValues(values)
            return if (uri in files) 1 else 0
        }

        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int {
            deleted += uri
            return if (files.remove(uri) != null) 1 else 0
        }

        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
            opened += uri to mode
            val file = files[uri] ?: throw java.io.FileNotFoundException("no row $uri")
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.parseMode(mode))
        }

        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null

        override fun getType(uri: Uri): String = "image/jpeg"
    }

    private lateinit var provider: FakeMediaProvider
    private lateinit var gateway: ContentResolverGateway
    private val source = Uri.parse("content://media/external/images/media/42")
    private val spec = NewImageSpec(displayName = "IMG_0042_lightly.jpg", dateTakenMillis = 1_700_000_000_000)
    private val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 9, 8, 7, 0xFF.toByte(), 0xD9.toByte())

    private class CountingEncoder(private val failure: IOException? = null) : JpegEncoder<ByteArray> {
        var calls = 0
        override fun encode(image: ByteArray, quality: Int, sink: OutputStream) {
            calls++
            failure?.let { throw it }
            sink.write(image)
        }
    }

    @Before
    fun setUp() {
        provider = Robolectric.setupContentProvider(FakeMediaProvider::class.java, MediaStore.AUTHORITY)
        val resolver = ApplicationProvider.getApplicationContext<Application>().contentResolver
        gateway = ContentResolverGateway(resolver)
    }

    @Test
    fun `save inserts with IS_PENDING 1, writes once, then sets IS_PENDING 0`() {
        val encoder = CountingEncoder()

        val saved = SaveCopyExporter(gateway, encoder).save(source, spec, jpeg)

        val (row, insertValues) = provider.inserted.single()
        assertEquals(saved, row)
        assertEquals(1, insertValues.getAsInteger(MediaStore.MediaColumns.IS_PENDING))
        assertEquals("image/jpeg", insertValues.getAsString(MediaStore.MediaColumns.MIME_TYPE))
        assertEquals("Pictures/Lightly", insertValues.getAsString(MediaStore.MediaColumns.RELATIVE_PATH))
        assertEquals("IMG_0042_lightly.jpg", insertValues.getAsString(MediaStore.MediaColumns.DISPLAY_NAME))
        assertEquals(1_700_000_000_000, insertValues.getAsLong(MediaStore.MediaColumns.DATE_TAKEN))
        assertTrue(row.toString().startsWith(MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY).toString()))

        val (updatedRow, updateValues) = provider.updated.single()
        assertEquals(row, updatedRow)
        assertEquals(0, updateValues.getAsInteger(MediaStore.MediaColumns.IS_PENDING))

        assertEquals(1, encoder.calls)
        assertContentEquals(jpeg, provider.files.getValue(row).readBytes())
        assertTrue(provider.deleted.isEmpty())
    }

    @Test
    fun `only the new row is opened, with mode w, and the Original is never opened`() {
        val saved = SaveCopyExporter(gateway, CountingEncoder()).save(source, spec, jpeg)

        assertEquals(listOf(saved to "w"), provider.opened)
        assertTrue(provider.opened.none { it.first == source })
    }

    @Test
    fun `write failure deletes the pending row and never publishes`() {
        val encoder = CountingEncoder(failure = IOException("write failed: ENOSPC (No space left on device)"))

        assertFailsWith<SaveCopyFailure.OutOfStorage> { SaveCopyExporter(gateway, encoder).save(source, spec, jpeg) }

        val row = provider.inserted.single().first
        assertEquals(listOf(row), provider.deleted)
        assertTrue(provider.updated.isEmpty(), "IS_PENDING must never be cleared on a failed write")
        assertEquals(1, encoder.calls)
    }
}
