package com.lightlylabs.lightly.export

import android.content.ContentResolver
import android.content.ContentValues
import android.graphics.Bitmap
import android.net.Uri
import android.provider.MediaStore
import java.io.IOException
import java.io.OutputStream

/** The real MediaStore gateway (API 29+). */
class ContentResolverGateway(
    private val resolver: ContentResolver,
    private val collection: Uri = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY),
) : MediaStoreGateway<Uri> {

    override fun insertPending(spec: NewImageSpec): Uri? {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, spec.displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, spec.mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, spec.relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
            spec.dateTakenMillis?.let { put(MediaStore.MediaColumns.DATE_TAKEN, it) }
        }
        return resolver.insert(collection, values)
    }

    override fun openForWrite(handle: Uri): OutputStream =
        // "w" (not "rw"/"wa"): the row is new and empty; truncating write is the only mode needed.
        resolver.openOutputStream(handle, "w") ?: throw IOException("No output stream for $handle")

    override fun publish(handle: Uri): Boolean {
        val values = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
        return resolver.update(handle, values, null, null) == 1
    }

    override fun delete(handle: Uri) {
        resolver.delete(handle, null, null)
    }
}

/**
 * Bitmap → JPEG via the platform encoder.
 *
 * PENDING (M3): sRGB ICC embedding, EXIF orientation = 1 and the safe-metadata copy (capture date,
 * make/model, lens; location per U7) via androidx.exifinterface are not implemented yet.
 */
class BitmapJpegEncoder : JpegEncoder<Bitmap> {
    override fun encode(image: Bitmap, quality: Int, sink: OutputStream) {
        if (!image.compress(Bitmap.CompressFormat.JPEG, quality, sink)) throw IOException("Bitmap.compress returned false")
    }
}
