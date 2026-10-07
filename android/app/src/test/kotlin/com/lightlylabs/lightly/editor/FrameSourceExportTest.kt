package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.render.image.ImageFrameSource
import com.lightlylabs.lightly.render.image.Rgba8Image
import org.junit.Test
import kotlin.test.assertContentEquals

/**
 * Save copy reads its frame by region (FrameSource, 2026-10-07): the working-size resize and Remove's fills, read by
 * region, give exactly the bytes of the whole-image versions.
 */
class FrameSourceExportTest {
    private fun image(w: Int, h: Int) = Rgba8Image(w, h, ByteArray(w * h * 4) { i -> if (i % 4 == 3) -1 else ((i * 37 + i / (w * 4) * 11) % 251).toByte() })

    @Test
    fun `the streamed resize equals the whole-image resize`() {
        val source = image(301, 187)
        for ((w, h) in listOf(150 to 93, 97 to 61, 40 to 25, 301 to 187)) {
            assertContentEquals(BackgroundSession.resize(source, w, h).pixels, BackgroundSession.resize(ImageFrameSource(source), w, h).pixels, "${w}x$h")
        }
    }

    @Test
    fun `Remove's fills composited per region equal the whole-frame composite`() {
        val frame = image(120, 80)
        // Patches at the source size (one to one) and at a smaller analysis size (scaled), overlapping region edges.
        val patches = listOf(
            RemovePatch(10, 12, 30, 20, ByteArray(30 * 20 * 4) { i -> if (i % 4 == 3) (i % 255).toByte() else (i * 7).toByte() }, 120, 80),
            RemovePatch(20, 5, 15, 12, ByteArray(15 * 12 * 4) { i -> if (i % 4 == 3) -1 else (i * 3).toByte() }, 60, 40),
        )
        val whole = RemoveEngine.composite(patches, frame)
        val patched = RemoveEngine.PatchedFrameSource(ImageFrameSource(frame), patches)
        val stitched = ByteArray(whole.pixels.size)
        for (y in 0 until 80 step 33) for (x in 0 until 120 step 47) {
            val w = minOf(47, 120 - x); val h = minOf(33, 80 - y)
            val part = patched.region(x, y, w, h)
            for (row in 0 until h) System.arraycopy(part.pixels, row * w * 4, stitched, ((y + row) * 120 + x) * 4, w * 4)
        }
        assertContentEquals(whole.pixels, stitched)
    }
}
