package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.image.Rgba8Image
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Stage 11 (rendering-v2 §7 `border`): insets as fractions of the frame width, the mat inside the frame band. */
class BorderStageTest {
    private fun frame(w: Int, h: Int) = Rgba8Image(w, h, ByteArray(w * h * 4) { i -> if (i % 4 == 3) -1 else ((i / 4) % 200 + 20).toByte() })
    private fun px(image: Rgba8Image, x: Int, y: Int) = IntArray(3) { image.pixels[(y * image.width + x) * 4 + it].toInt() and 0xff }

    @Test
    fun `insets are the contract's`() {
        assertEquals(BorderStage.Insets(0.05, 0.05, 0.05), BorderStage.insets(BorderParams("solid", width = 5.0)))
        assertEquals(BorderStage.Insets(0.08, 0.08, 0.08), BorderStage.insets(BorderParams("frame", width = 3.0, spacing = 5.0)))
        assertEquals(BorderStage.Insets(0.055, 0.055, 0.24), BorderStage.insets(BorderParams("polaroid")))
        val p = BorderStage.placement(BorderParams("polaroid"), 1000, 600)
        assertEquals(1110 to 895, p.canvasWidth to p.canvasHeight)
    }

    @Test
    fun `none returns the frame and solid places it on its colour`() {
        val f = frame(100, 60)
        assertTrue(BorderStage.apply(BorderParams(), f) === f)
        val c = BorderStage.apply(BorderParams("solid", "#3C4A55", width = 5.0), f)
        assertEquals(110 to 70, c.width to c.height)
        assertContentEquals(intArrayOf(0x3C, 0x4A, 0x55), px(c, 2, 2))
        assertContentEquals(px(f, 0, 0), px(c, 5, 5))
    }

    @Test
    fun `the photo frame has its mat inside the frame band`() {
        val c = BorderStage.apply(BorderParams("frame", "#111111", width = 3.0, spacing = 5.0, mat = "#F4F1EC"), frame(100, 60))
        assertEquals(116 to 76, c.width to c.height)
        assertContentEquals(intArrayOf(0x11, 0x11, 0x11), px(c, 1, 40))
        assertContentEquals(intArrayOf(0xF4, 0xF1, 0xEC), px(c, 5, 40))
    }

    @Test
    fun `a canvas rendered tile by tile equals the whole and the image box finds the photo`() {
        val b = BorderParams("polaroid", "#F4F1EC")
        val f = frame(90, 70)
        val whole = BorderStage.apply(b, f)
        val p = BorderStage.placement(b, 90, 70)
        val tile = PixelRect(0, 60, whole.width, whole.height - 60)
        val cut = BorderStage.renderTile(b, p, tile) { r -> Rgba8Image(r.width, r.height, ByteArray(r.width * r.height * 4).also { out ->
            for (row in 0 until r.height) System.arraycopy(f.pixels, ((r.y + row) * 90 + r.x) * 4, out, row * r.width * 4, r.width * 4) }) }
        for (y in 0 until tile.height) for (x in 0 until tile.width) assertContentEquals(px(whole, x, 60 + y), px(cut, x, y))
        val box = BorderStage.imageBox(b, whole.width, whole.height)
        assertEquals(p.side.toDouble() / whole.width, box[0], 1e-12)
        assertEquals(70.0 / whole.height, box[3], 1e-12)
    }
}
