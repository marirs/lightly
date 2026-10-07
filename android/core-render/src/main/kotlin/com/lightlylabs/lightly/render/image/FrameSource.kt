package com.lightlylabs.lightly.render.image

/**
 * A full-resolution frame read by region (Save copy's source, 2026-10-07). On Android the frame is a Bitmap held
 * outside the Java heap: a 48 MP photo as one RGBA8 array is 192 MB, which the 192 MB app heap refused, so Save copy of
 * a 48 MP photo saved nothing. Every export stage reads the regions (tiles, aprons, row bands) it needs instead.
 */
interface FrameSource : AutoCloseable {
    val width: Int
    val height: Int

    /** The pixels of the rectangle (x, y, width, height), which lies inside the frame, as a new RGBA8 image. */
    fun region(x: Int, y: Int, width: Int, height: Int): Rgba8Image

    /** Frees the frame's pixels (a native Bitmap); no region may be read afterwards. */
    override fun close() {}
}

/** A frame already held as one RGBA8 image (previews, JVM tests, small photos). Regions are copies. */
class ImageFrameSource(val image: Rgba8Image) : FrameSource {
    override val width: Int get() = image.width
    override val height: Int get() = image.height

    override fun region(x: Int, y: Int, width: Int, height: Int): Rgba8Image {
        require(x >= 0 && y >= 0 && width >= 0 && height >= 0 && x + width <= image.width && y + height <= image.height) {
            "region ($x, $y, $width, $height) outside ${image.width}x${image.height}"
        }
        val rowBytes = width * Rgba8Image.CHANNELS
        val out = ByteArray(height * rowBytes)
        for (row in 0 until height) {
            System.arraycopy(image.pixels, ((y + row) * image.width + x) * Rgba8Image.CHANNELS, out, row * rowBytes, rowBytes)
        }
        return Rgba8Image(width, height, out)
    }
}

fun Rgba8Image.asFrameSource(): FrameSource = ImageFrameSource(this)
