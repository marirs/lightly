package com.lightlylabs.lightly.develop.auto

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class AutoCorrectionTest {
    @Test
    fun `the identity correction bakes the identity LUT`() {
        val lut = AutoCorrection().lut(9)
        val out = FloatArray(3)
        for (r in 0..8) for (g in 0..8) for (b in 0..8) {
            lut.sample(r / 8f, g / 8f, b / 8f, out)
            assertEquals(r / 8f, out[0], 1e-6f); assertEquals(g / 8f, out[1], 1e-6f); assertEquals(b / 8f, out[2], 1e-6f)
        }
    }

    @Test
    fun `the stored correction round-trips and rebuilds the same LUT`() {
        val c = AutoCorrection(vibrance = 0.12, gains = listOf(0.93, 1.0, 1.08), exposure = 1.4, notes = listOf("n"))
        val back = AutoCorrection.fromJson(c.toJson())!!
        assertEquals(c, back)
        assertTrue(c.lut().rgba.contentEquals(back.lut().rgba))
        assertEquals(null, AutoCorrection.fromJson("""{"engine":"coreimage-auto"}"""))
    }

    @Test
    fun `the baked LUT agrees with the per-pixel correction`() {
        val c = AutoCorrection(vibrance = 0.2, gains = listOf(0.9, 1.0, 1.1), exposure = 1.6)
        val lut = c.lut()
        val out = FloatArray(3)
        val random = java.util.Random(3)
        repeat(2000) {
            val rgb = DoubleArray(3) { random.nextDouble() }
            lut.sample(rgb[0].toFloat(), rgb[1].toFloat(), rgb[2].toFloat(), out)
            c.apply(rgb)
            // 33³ trilinear interpolation across a clipping kink (vibrance pushing a channel to 0) is off by up to ~3/255.
            for (k in 0 until 3) assertTrue(kotlin.math.abs(out[k] - rgb[k]) < 0.02, "channel $k: ${out[k]} vs ${rgb[k]}")
        }
    }
}
