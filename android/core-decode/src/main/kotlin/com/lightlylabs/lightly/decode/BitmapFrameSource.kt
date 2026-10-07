package com.lightlylabs.lightly.decode

import android.graphics.Bitmap
import com.lightlylabs.lightly.render.image.FrameSource
import com.lightlylabs.lightly.render.image.Rgba8Image
import java.nio.ByteBuffer

/**
 * Save copy's full-resolution source in a native Bitmap (2026-10-07): a Bitmap's pixels are not in the Java heap, so a
 * 48 MP photo (192 MB as RGBA8) no longer needs one Java array the 192 MB app heap refused. A region is copied out with
 * Bitmap.createBitmap (no scaling, so the same pixels) and read with copyPixelsToBuffer, the bytes the whole-frame
 * [ProxyDecoder.toRgba8] produced for the same pixels.
 */
class BitmapFrameSource(private var bitmap: Bitmap?) : FrameSource {
    init { require(bitmap!!.config == Bitmap.Config.ARGB_8888) { "Expected ARGB_8888, was ${bitmap!!.config}" } }

    override val width: Int = bitmap!!.width
    override val height: Int = bitmap!!.height

    override fun region(x: Int, y: Int, width: Int, height: Int): Rgba8Image {
        val source = checkNotNull(bitmap) { "frame already closed" }
        require(x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= this.width && y + height <= this.height) {
            "region ($x, $y, $width, $height) outside ${this.width}x${this.height}"
        }
        val part = Bitmap.createBitmap(source, x, y, width, height)
        try {
            val bytes = ByteArray(width * height * Rgba8Image.CHANNELS)
            part.copyPixelsToBuffer(ByteBuffer.wrap(bytes))
            return Rgba8Image(width, height, bytes)
        } finally {
            // createBitmap returns the source itself for the whole, unchanged frame.
            if (part !== source) part.recycle()
        }
    }

    override fun close() {
        bitmap?.recycle()
        bitmap = null
    }
}
