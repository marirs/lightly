package com.lightlylabs.lightly.decode

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.zip.CRC32
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * ImageDecoder path under Robolectric's native graphics (real Skia codecs on the host). This shows
 * the wiring (target size, sRGB conversion, orientation, header checks); behaviour of real device
 * decoders (HEIF, 10-bit, vendor JPEG, Ultra HDR) is PENDING.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34])
class ProxyDecoderTest {

    private val decoder = ProxyDecoder()

    private fun encode(bitmap: Bitmap, format: Bitmap.CompressFormat): ByteArray =
        ByteArrayOutputStream().also { check(bitmap.compress(format, 100, it)) }.toByteArray()

    private fun source(bytes: ByteArray) = ImageDecoder.createSource(ByteBuffer.wrap(bytes))

    private fun rgbAt(frame: DecodedFrame, x: Int, y: Int): IntArray {
        val base = (y * frame.image.width + x) * 4
        return IntArray(3) { frame.image.pixels[base + it].toInt() and 0xff }
    }

    @Test
    fun `analysis decode downscales to long edge 1024 and reports the original size`() {
        val bitmap = Bitmap.createBitmap(2048, 1536, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.rgb(200, 120, 40)) }

        val frame = decoder.decodeForAnalysis(source(encode(bitmap, Bitmap.CompressFormat.PNG)))

        assertEquals(PixelSize(2048, 1536), frame.originalSize)
        assertEquals(1024, frame.image.width)
        assertEquals(768, frame.image.height)
        assertTrue(rgbAt(frame, 500, 300).contentEquals(intArrayOf(200, 120, 40)), "flat colour survives the downscale")
    }

    @Test
    fun `display decode follows the screen, separately from analysis`() {
        val bytes = encode(Bitmap.createBitmap(2048, 1536, Bitmap.Config.ARGB_8888), Bitmap.CompressFormat.PNG)

        val display = decoder.decodeForDisplay(source(bytes), screenLongestPx = 800)
        val analysis = decoder.decodeForAnalysis(source(bytes))

        assertEquals(800 to 600, display.image.width to display.image.height)
        assertEquals(1024 to 768, analysis.image.width to analysis.image.height)
    }

    @Test
    fun `Display P3 source is converted to sRGB`() {
        val p3 = ColorSpace.get(ColorSpace.Named.DISPLAY_P3)
        val p3Value = floatArrayOf(0.8f, 0.3f, 0.2f)
        val bitmap = Bitmap.createBitmap(64, 64, Bitmap.Config.ARGB_8888, false, p3)
        bitmap.eraseColor(Color.pack(p3Value[0], p3Value[1], p3Value[2], 1f, p3))

        val frame = decoder.decodeForAnalysis(source(encode(bitmap, Bitmap.CompressFormat.PNG)))

        val expected = ColorSpace.connect(p3, ColorSpace.get(ColorSpace.Named.SRGB)).transform(p3Value.copyOf())
            .map { (it.coerceIn(0f, 1f) * 255f).roundToInt() }
        val actual = rgbAt(frame, 32, 32)
        assertTrue(frame.sourceColorSpaceName?.contains("P3") == true, "header colour space: ${frame.sourceColorSpaceName}")
        for (channel in 0 until 3) {
            assertTrue(abs(actual[channel] - expected[channel]) <= 2, "sRGB ${actual.toList()} vs expected $expected")
        }
        val unconverted = p3Value.map { (it * 255f).roundToInt() }
        assertTrue(actual.toList() != unconverted, "P3 values must not be passed through as if they were sRGB")
    }

    @Test
    fun `EXIF orientation 6 is applied and the original size is reported upright`() {
        // 40x20, left half red, right half blue; orientation 6 = rotate 90° clockwise for display.
        val bitmap = Bitmap.createBitmap(40, 20, Bitmap.Config.ARGB_8888)
        for (y in 0 until 20) for (x in 0 until 40) bitmap.setPixel(x, y, if (x < 20) Color.RED else Color.BLUE)
        val jpeg = withExifOrientation(encode(bitmap, Bitmap.CompressFormat.JPEG), orientation = 6)

        val frame = decoder.decodeForAnalysis(source(jpeg))

        assertEquals(PixelSize(20, 40), frame.originalSize)
        assertEquals(20 to 40, frame.image.width to frame.image.height)
        val top = rgbAt(frame, 10, 5)
        val bottom = rgbAt(frame, 10, 34)
        assertTrue(top[0] > 200 && top[2] < 60, "after 90° CW the left (red) half is on top: ${top.toList()}")
        assertTrue(bottom[2] > 200 && bottom[0] < 60, "and the right (blue) half at the bottom: ${bottom.toList()}")
    }

    @Test
    fun `header above 100 MP is rejected before decoding pixels`() {
        assertFailsWith<DecodeRejection.TooLarge> { decoder.decodeForAnalysis(source(pngHeaderOnly(width = 12_000, height = 9_000))) }
    }

    @Test
    fun `bytes that are not an image are reported as unsupported`() {
        assertFailsWith<DecodeRejection.Unsupported> { decoder.decodeForAnalysis(source(ByteArray(256) { it.toByte() })) }
    }

    // --- byte-level fixtures -----------------------------------------------------------------

    /** Inserts a minimal big-endian EXIF APP1 segment with one Orientation (0x0112) entry after SOI. */
    private fun withExifOrientation(jpeg: ByteArray, orientation: Int): ByteArray {
        val tiff = byteArrayOf(
            'M'.code.toByte(), 'M'.code.toByte(), 0, 42, 0, 0, 0, 8, // header, IFD0 at offset 8
            0, 1, // one entry
            0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, orientation.toByte(), 0, 0, // Orientation, SHORT, count 1, value
            0, 0, 0, 0, // no next IFD
        )
        val payload = "Exif".toByteArray() + byteArrayOf(0, 0) + tiff
        val length = payload.size + 2
        val app1 = byteArrayOf(0xFF.toByte(), 0xE1.toByte(), (length shr 8).toByte(), length.toByte()) + payload
        return jpeg.copyOfRange(0, 2) + app1 + jpeg.copyOfRange(2, jpeg.size)
    }

    /** A PNG whose IHDR declares [width]×[height]; the pixel data is a stub, never decoded. */
    private fun pngHeaderOnly(width: Int, height: Int): ByteArray {
        fun chunk(type: String, data: ByteArray): ByteArray {
            val typeBytes = type.toByteArray()
            val crc = CRC32().apply { update(typeBytes); update(data) }.value
            return ByteBuffer.allocate(12 + data.size).putInt(data.size).put(typeBytes).put(data).putInt(crc.toInt()).array()
        }
        val ihdr = ByteBuffer.allocate(13).putInt(width).putInt(height).put(8).put(2).put(0).put(0).put(0).array()
        val signature = byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte(), 13, 10, 26, 10)
        return signature + chunk("IHDR", ihdr) + chunk("IDAT", byteArrayOf(0x78, 0x9c.toByte(), 0x03, 0x00)) + chunk("IEND", ByteArray(0))
    }
}
