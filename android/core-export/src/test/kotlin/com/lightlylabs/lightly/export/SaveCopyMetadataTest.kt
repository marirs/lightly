package com.lightlylabs.lightly.export

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.ColorSpace
import android.media.ExifInterface
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.OutputStream
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The four combinations of the two metadata switches, checked on the JPEG bytes Save copy actually
 * writes (host Skia encoder + platform ExifInterface under Robolectric native graphics).
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34])
class SaveCopyMetadataTest {

    @get:Rule
    val temp = TemporaryFolder()

    private val captureTags: Map<String, String> = mapOf(
        ExifInterface.TAG_MAKE to "Google",
        ExifInterface.TAG_MODEL to "Pixel 9 Pro",
        ExifInterface.TAG_F_NUMBER to "1.68",
        ExifInterface.TAG_EXPOSURE_TIME to "0.008",
        ExifInterface.TAG_ISO_SPEED_RATINGS to "49",
        ExifInterface.TAG_DATETIME_ORIGINAL to "2026:09:12 18:04:31",
    )

    private fun ExifInterface.latLongOrNull(): FloatArray? = FloatArray(2).takeIf { getLatLong(it) }

    /** The Original: 64x48 JPEG carrying capture data, GPS and things that must never be copied. */
    private fun original(): File {
        val file = temp.newFile("original.jpg")
        val bitmap = Bitmap.createBitmap(64, 48, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.rgb(90, 140, 200)) }
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) }
        ExifInterface(file).apply {
            captureTags.forEach { (tag, value) -> setAttribute(tag, value) }
            setAttribute(ExifInterface.TAG_GPS_LATITUDE, "51/1,30/1,254/100")
            setAttribute(ExifInterface.TAG_GPS_LATITUDE_REF, "N")
            setAttribute(ExifInterface.TAG_GPS_LONGITUDE, "0/1,7/1,2856/100")
            setAttribute(ExifInterface.TAG_GPS_LONGITUDE_REF, "W")
            setAttribute(ExifInterface.TAG_GPS_ALTITUDE, "12/1")
            setAttribute(ExifInterface.TAG_GPS_ALTITUDE_REF, "0")
            // Stale values the copy must not inherit: the copy is upright and a different size.
            setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
            setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, "4000")
            setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, "3000")
            setAttribute(ExifInterface.TAG_SOFTWARE, "Camera firmware")
            saveAttributes()
        }
        return file
    }

    private class MemoryGateway : MediaStoreGateway<String> {
        val written = ByteArrayOutputStream()
        override fun insertPending(spec: NewImageSpec) = "content://media/external_primary/images/media/2001"
        override fun openForWrite(handle: String): OutputStream = written
        override fun publish(handle: String) = true
        override fun delete(handle: String) = Unit
    }

    private fun saveCopy(policy: MetadataPolicy): File {
        val originalFile = original()
        val gateway = MemoryGateway()
        val step = ExportMetadataStep<String>(
            reader = { _, tags -> originalFile.inputStream().use { PlatformExifMetadata.readTags(it, tags) } },
            writer = PlatformExifMetadata.writer,
            scratchDirectory = temp.newFolder(),
        )
        val exporter = SaveCopyExporter(gateway, BitmapJpegEncoder(), metadataStep = step)
        // Rendered result: 32x24, i.e. NOT the Original's size, in sRGB like BitmapExportFrame.
        val rendered = Bitmap.createBitmap(32, 24, Bitmap.Config.ARGB_8888, true, ColorSpace.get(ColorSpace.Named.SRGB)).apply { eraseColor(Color.rgb(200, 120, 60)) }

        exporter.save("content://media/picker/0/42", NewImageSpec("copy.jpg", metadataPolicy = policy), rendered)

        return temp.newFile("copy-${policy.keepPhotoMetadata}-${policy.includeLocation}.jpg").apply { writeBytes(gateway.written.toByteArray()) }
    }

    @Test
    fun `defaults keep capture metadata and drop location`() {
        assertEquals(MetadataPolicy(keepPhotoMetadata = true, includeLocation = false), MetadataPolicy.DEFAULT)
        val copy = saveCopy(MetadataPolicy.DEFAULT)
        val exif = ExifInterface(copy)

        captureTags.forEach { (tag, value) -> assertEquals(value, exif.getAttribute(tag), tag) }
        assertNull(exif.latLongOrNull(), "location must not be copied")
        assertNull(exif.getAttribute(ExifInterface.TAG_GPS_ALTITUDE))
        assertSafeInEveryCombination(copy)
    }

    @Test
    fun `metadata and location both on`() {
        val copy = saveCopy(MetadataPolicy(keepPhotoMetadata = true, includeLocation = true))
        val exif = ExifInterface(copy)

        captureTags.forEach { (tag, value) -> assertEquals(value, exif.getAttribute(tag), tag) }
        val latLong = exif.latLongOrNull()!!
        assertEquals(51.5007f, latLong[0], 1e-3f)
        assertEquals(-0.1246f, latLong[1], 1e-3f)
        assertEquals("12/1", exif.getAttribute(ExifInterface.TAG_GPS_ALTITUDE))
        assertSafeInEveryCombination(copy)
    }

    @Test
    fun `location only, without capture metadata`() {
        val copy = saveCopy(MetadataPolicy(keepPhotoMetadata = false, includeLocation = true))
        val exif = ExifInterface(copy)

        captureTags.keys.forEach { tag -> assertNull(exif.getAttribute(tag), "$tag must be dropped") }
        assertEquals(51.5007f, exif.latLongOrNull()!![0], 1e-3f)
        assertSafeInEveryCombination(copy)
    }

    @Test
    fun `both off writes no EXIF block at all`() {
        val copy = saveCopy(MetadataPolicy(keepPhotoMetadata = false, includeLocation = false))
        val exif = ExifInterface(copy)

        captureTags.keys.forEach { tag -> assertNull(exif.getAttribute(tag), "$tag must be dropped") }
        assertNull(exif.latLongOrNull())
        assertFalse(JpegSegments.of(copy.readBytes()).any { it.isExif }, "no APP1 Exif segment")
        assertSafeInEveryCombination(copy)
    }

    /** Colour profile kept; nothing describing the Original's pixels carried over. */
    private fun assertSafeInEveryCombination(copy: File) {
        val bytes = copy.readBytes()
        assertTrue(JpegSegments.of(bytes).any { it.isIccProfile }, "the copy must keep its ICC colour profile")
        val exif = ExifInterface(copy)
        val orientation = exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        assertTrue(orientation == ExifInterface.ORIENTATION_NORMAL || orientation == ExifInterface.ORIENTATION_UNDEFINED, "orientation $orientation")
        assertFalse(exif.hasThumbnail(), "no thumbnail")
        assertNull(exif.getAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION), "no stale PixelXDimension")
        assertNull(exif.getAttribute(ExifInterface.TAG_SOFTWARE), "only whitelisted tags are copied")
        // If ExifInterface reports image dimensions, they are the copy's own (from its SOF marker).
        exif.getAttribute(ExifInterface.TAG_IMAGE_WIDTH)?.let { assertEquals("32", it) }
        exif.getAttribute(ExifInterface.TAG_IMAGE_LENGTH)?.let { assertEquals("24", it) }
    }

    @Test
    fun `an unreadable original still saves, without metadata`() {
        val gateway = MemoryGateway()
        val step = ExportMetadataStep<String>(
            reader = { _, _ -> throw java.io.FileNotFoundException("gone") },
            writer = PlatformExifMetadata.writer,
            scratchDirectory = temp.newFolder(),
        )
        val rendered = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888, true, ColorSpace.get(ColorSpace.Named.SRGB))

        SaveCopyExporter(gateway, BitmapJpegEncoder(), metadataStep = step).save("src", NewImageSpec("c.jpg"), rendered)

        assertFalse(JpegSegments.of(gateway.written.toByteArray()).any { it.isExif })
    }

    @Test
    fun `the scratch file is removed after saving`() {
        val scratch = temp.newFolder()
        val step = ExportMetadataStep<String>(
            reader = { _, tags -> original().inputStream().use { PlatformExifMetadata.readTags(it, tags) } },
            writer = PlatformExifMetadata.writer,
            scratchDirectory = scratch,
        )
        val rendered = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888, true, ColorSpace.get(ColorSpace.Named.SRGB))

        SaveCopyExporter(MemoryGateway(), BitmapJpegEncoder(), metadataStep = step).save("src", NewImageSpec("c.jpg"), rendered)

        assertEquals(emptyList(), scratch.listFiles()!!.toList())
    }
}

/** Minimal JPEG marker walk (SOI … SOS) for the segment assertions. */
internal data class JpegSegment(val marker: Int, val payload: ByteArray) {
    val isExif: Boolean get() = marker == 0xE1 && payload.size >= 6 && String(payload, 0, 4, Charsets.US_ASCII) == "Exif"
    val isIccProfile: Boolean get() = marker == 0xE2 && payload.size >= 12 && String(payload, 0, 11, Charsets.US_ASCII) == "ICC_PROFILE"
}

internal object JpegSegments {
    fun of(jpeg: ByteArray): List<JpegSegment> {
        require(jpeg[0] == 0xFF.toByte() && jpeg[1] == 0xD8.toByte()) { "not a JPEG" }
        val segments = mutableListOf<JpegSegment>()
        var offset = 2
        while (offset + 4 <= jpeg.size) {
            if (jpeg[offset] != 0xFF.toByte()) break
            val marker = jpeg[offset + 1].toInt() and 0xFF
            if (marker == 0xDA || marker == 0xD9) break // start of scan: no more metadata segments
            val length = ((jpeg[offset + 2].toInt() and 0xFF) shl 8) or (jpeg[offset + 3].toInt() and 0xFF)
            segments += JpegSegment(marker, jpeg.copyOfRange(offset + 4, offset + 2 + length))
            offset += 2 + length
        }
        return segments
    }
}
