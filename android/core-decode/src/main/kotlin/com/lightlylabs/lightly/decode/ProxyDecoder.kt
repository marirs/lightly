package com.lightlylabs.lightly.decode

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.graphics.Paint
import com.lightlylabs.lightly.render.image.Rgba8Image
import java.nio.ByteBuffer

/** A decoded, oriented, sRGB, 8-bit frame plus what was learned from the header. */
class DecodedFrame(
    val image: Rgba8Image,
    /** Oriented size of the Original (before any downscale). */
    val originalSize: PixelSize,
    /** Colour space the file declared; null when the decoder could not tell. */
    val sourceColorSpaceName: String?,
)

/**
 * ImageDecoder → oriented sRGB RGBA8 (spec §2.2, §4.3, §4.6).
 *
 * - **Orientation:** ImageDecoder applies EXIF orientation itself (API 28+) and reports the oriented
 *   size in `ImageInfo.size`, so the result is upright and [DecodedFrame.originalSize] is oriented.
 * - **Colour:** `setTargetColorSpace(sRGB)` converts wide-gamut sources (Display P3, Adobe RGB) to
 *   sRGB. Any bitmap that still is not 8-bit sRGB (e.g. RGBA_F16 from a 10-bit HEIF) is redrawn
 *   into an sRGB ARGB_8888 bitmap, where the Canvas performs the conversion. Out-of-gamut colours
 *   clip (spec §4.3, accepted for V1).
 * - **HDR gain maps** (Ultra HDR) are ignored: only the SDR base image is used (spec U5).
 * - **Size:** the header is checked before allocation; above 100 MP the decode is refused with
 *   [DecodeRejection.TooLarge] (spec §5.3).
 *
 * Blocking; call off the main thread.
 */
class ProxyDecoder {

    fun decodeForAnalysis(source: ImageDecoder.Source): DecodedFrame = decode(source, DecodeTargets::analysisSize)

    fun decodeForDisplay(source: ImageDecoder.Source, screenLongestPx: Int): DecodedFrame =
        decode(source) { original -> DecodeTargets.displaySize(original, screenLongestPx) }

    fun decode(source: ImageDecoder.Source, targetFor: (PixelSize) -> PixelSize): DecodedFrame {
        var originalSize: PixelSize? = null
        var colorSpaceName: String? = null
        val decoded = try {
            ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                val size = PixelSize(info.size.width, info.size.height)
                DecodeTargets.requireDecodable(size)
                originalSize = size
                colorSpaceName = info.colorSpace?.name
                val target = targetFor(size)
                if (target != size) decoder.setTargetSize(target.width, target.height)
                // Software: pixels must be read back (model input, CPU paths, GL upload from bytes).
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.setTargetColorSpace(SRGB)
            }
        } catch (failure: ImageDecoder.DecodeException) {
            // No header means the format itself was not understood: a specific "unsupported" message.
            // A failure after the header (truncated file) stays a generic decode error.
            if (originalSize == null) throw DecodeRejection.Unsupported(null).apply { initCause(failure) }
            throw failure
        }
        val srgb = toSrgbArgb8888(decoded)
        try {
            return DecodedFrame(toRgba8(srgb), checkNotNull(originalSize), colorSpaceName)
        } finally {
            if (srgb !== decoded) srgb.recycle()
            decoded.recycle()
        }
    }

    companion object {
        private val SRGB: ColorSpace = ColorSpace.get(ColorSpace.Named.SRGB)

        /** Returns [bitmap] itself if it already is ARGB_8888 sRGB, else an sRGB ARGB_8888 redraw. */
        fun toSrgbArgb8888(bitmap: Bitmap): Bitmap {
            if (bitmap.config == Bitmap.Config.ARGB_8888 && bitmap.colorSpace == SRGB) return bitmap
            val converted = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888, bitmap.hasAlpha(), SRGB)
            Canvas(converted).drawBitmap(bitmap, 0f, 0f, Paint(Paint.FILTER_BITMAP_FLAG))
            return converted
        }

        /** ARGB_8888 `copyPixelsToBuffer` writes bytes in R, G, B, A order (unpremultiplied for opaque photos). */
        fun toRgba8(bitmap: Bitmap): Rgba8Image {
            require(bitmap.config == Bitmap.Config.ARGB_8888) { "Expected ARGB_8888, was ${bitmap.config}" }
            val bytes = ByteArray(bitmap.width * bitmap.height * Rgba8Image.CHANNELS)
            bitmap.copyPixelsToBuffer(ByteBuffer.wrap(bytes))
            return Rgba8Image(bitmap.width, bitmap.height, bytes)
        }
    }
}
