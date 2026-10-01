package com.lightlylabs.lightly.export

import android.content.ContentResolver
import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.ColorSpace
import android.net.Uri
import android.provider.MediaStore
import com.lightlylabs.lightly.render.image.Rgba8Image
import java.io.IOException
import com.lightlylabs.lightly.render.gpu.Tile
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
 * Export target on Android: an ARGB_8888 sRGB Bitmap that tiles are written into and that
 * [BitmapFrameJpegEncoder] compresses directly, so no extra full-frame copy exists between render
 * and encode. Writing a tile converts RGBA bytes to ARGB ints in a tile-sized scratch array.
 */
class BitmapExportFrame(val bitmap: Bitmap) : ExportFrame {
    init {
        require(bitmap.config == Bitmap.Config.ARGB_8888 && bitmap.isMutable) { "Export frame must be a mutable ARGB_8888 bitmap" }
    }

    override val width: Int get() = bitmap.width
    override val height: Int get() = bitmap.height

    override fun writeTile(tile: Tile, pixels: Rgba8Image) {
        val argb = IntArray(tile.pixelCount)
        val bytes = pixels.pixels
        for (i in argb.indices) {
            val base = i * 4
            argb[i] = ((bytes[base + 3].toInt() and 0xff) shl 24) or
                ((bytes[base].toInt() and 0xff) shl 16) or
                ((bytes[base + 1].toInt() and 0xff) shl 8) or
                (bytes[base + 2].toInt() and 0xff)
        }
        bitmap.setPixels(argb, 0, tile.width, tile.x, tile.y, tile.width, tile.height)
    }

    companion object {
        val factory = ExportFrameFactory { width, height ->
            BitmapExportFrame(Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888, true, ColorSpace.get(ColorSpace.Named.SRGB)))
        }
    }
}

/** Compresses the export frame's Bitmap. PENDING (device): real JPEG output is not verified in M2. */
class BitmapFrameJpegEncoder(private val bitmapEncoder: BitmapJpegEncoder = BitmapJpegEncoder()) : JpegEncoder<BitmapExportFrame> {
    override fun encode(image: BitmapExportFrame, quality: Int, sink: OutputStream) = bitmapEncoder.encode(image.bitmap, quality, sink)
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
