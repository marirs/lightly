package com.lightlylabs.lightly.export

import android.graphics.Color
import com.lightlylabs.lightly.render.gpu.Tile
import com.lightlylabs.lightly.render.image.Rgba8Image
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The Android export target under Robolectric native graphics (host Skia). Device JPEG output
 * (ICC, quality, vendor encoder) remains PENDING.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34])
class BitmapExportFrameTest {

    private fun solidTile(width: Int, height: Int, r: Int, g: Int, b: Int) =
        Rgba8Image(width, height, ByteArray(width * height * 4) { i -> when (i % 4) { 0 -> r; 1 -> g; 2 -> b; else -> 255 }.toByte() })

    @Test
    fun `tiles land at their offsets with RGBA to ARGB conversion`() {
        val frame = BitmapExportFrame.factory.allocate(8, 4)

        frame.writeTile(Tile(0, 0, 4, 4), solidTile(4, 4, 200, 100, 50))
        frame.writeTile(Tile(4, 0, 4, 4), solidTile(4, 4, 10, 20, 30))

        assertEquals(Color.argb(255, 200, 100, 50), frame.bitmap.getPixel(3, 3))
        assertEquals(Color.argb(255, 10, 20, 30), frame.bitmap.getPixel(4, 0))
        assertTrue(frame.bitmap.colorSpace!!.isSrgb)
    }

    @Test
    fun `the frame bitmap is what gets compressed`() {
        val frame = BitmapExportFrame.factory.allocate(16, 16)
        frame.writeTile(Tile(0, 0, 16, 16), solidTile(16, 16, 120, 130, 140))
        val out = ByteArrayOutputStream()

        BitmapFrameJpegEncoder().encode(frame, SaveCopyExporter.DEFAULT_QUALITY, out)

        val jpeg = out.toByteArray()
        assertTrue(jpeg.size > 4 && jpeg[0] == 0xFF.toByte() && jpeg[1] == 0xD8.toByte(), "JPEG SOI marker")
        assertTrue(jpeg[jpeg.size - 2] == 0xFF.toByte() && jpeg[jpeg.size - 1] == 0xD9.toByte(), "JPEG EOI marker")
    }
}
