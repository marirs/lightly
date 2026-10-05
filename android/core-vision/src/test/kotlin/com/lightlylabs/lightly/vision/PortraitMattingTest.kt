package com.lightlylabs.lightly.vision

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** MODNet's input and output mapping: letterbox in, the photo's part back out at the photo's size. */
class PortraitMattingTest {
    /** A stand-in model whose alpha is 1 wherever the input is not padding (padding is −1 on every channel). */
    private val photoDetector = TensorModel { input ->
        val side = PortraitMatting.INPUT
        listOf(FloatArray(side * side) { i -> if (input[i * 3] > -0.999f || input[i * 3 + 1] > -0.999f || input[i * 3 + 2] > -0.999f) 1f else 0f })
    }

    private fun grey(width: Int, height: Int) = RgbaImage(width, height, ByteArray(width * height * 4) { if (it % 4 == 3) -1 else 100 })

    @Test
    fun `a portrait photo is letterboxed and its whole area comes back as the photo`() {
        val matte = PortraitMatting(photoDetector).segment(grey(300, 450))
        assertEquals(300, matte.width); assertEquals(450, matte.height)
        assertTrue(matte.values.all { it == 1f }, "padding leaked into the photo's matte")
    }

    @Test
    fun `the letterbox padding never reaches a landscape photo either`() {
        val matte = PortraitMatting(photoDetector).segment(grey(640, 360))
        assertEquals(640, matte.width); assertEquals(360, matte.height)
        assertTrue(matte.values.all { it == 1f })
    }

    @Test
    fun `area downsampling averages the source pixels`() {
        val image = RgbaImage(4, 2, ByteArray(4 * 2 * 4) { i -> if (i % 4 == 3) -1 else if ((i / 4) % 2 == 0) 0 else -1 })   // 0, 255 alternating columns
        val down = PortraitMatting.areaDownsample(image, 2, 1)
        assertEquals(0.5f, down[0], 1e-6f)
        assertEquals(0.5f, down[3], 1e-6f)
    }
}
