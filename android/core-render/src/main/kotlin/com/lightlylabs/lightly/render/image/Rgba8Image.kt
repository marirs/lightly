package com.lightlylabs.lightly.render.image

/**
 * A tightly packed 8-bit sRGB-encoded RGBA buffer (R,G,B,A byte order, row-major, no padding).
 *
 * This is the platform-neutral pixel type of the CPU reference path. On Android it is what
 * `Bitmap.copyPixelsToBuffer` produces for an ARGB_8888 bitmap, so the same bytes feed the CPU
 * reference, the model preprocessing and (in M3) the GL texture upload.
 */
class Rgba8Image(val width: Int, val height: Int, val pixels: ByteArray) {
    init {
        require(width > 0 && height > 0) { "Image size must be positive, was ${width}x$height" }
        require(pixels.size.toLong() == width.toLong() * height * CHANNELS) {
            "Expected ${width.toLong() * height * CHANNELS} bytes for ${width}x$height RGBA, got ${pixels.size}"
        }
    }

    val pixelCount: Int get() = width * height

    companion object {
        const val CHANNELS = 4
    }
}
