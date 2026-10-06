package com.lightlylabs.lightly.background

import org.junit.Assume.assumeTrue
import org.junit.Test
import kotlin.test.assertEquals

class SrgbBytesTest {
    @Test
    fun `decode table equals srgbToLinear of every byte`() {
        for (b in 0..255) assertEquals(Refocus.srgbToLinear(b / 255f), SrgbBytes.TO_LINEAR[b])
    }

    @Test
    fun `encode equals the per-pixel function near every byte boundary and across the range`() {
        // Every float within 4096 ulps of each byte boundary, plus 2 M random floats in [-0.1, 1.1] and the specials.
        val specials = floatArrayOf(0f, -0f, 1f, -1f, 2f, Float.NaN, Float.MIN_VALUE, 0.0031308f, Float.POSITIVE_INFINITY)
        for (v in specials) assertEquals(SrgbBytes.reference(v), SrgbBytes.encodeLinear(v), "v=$v")
        for (k in 1..255) {
            var lo = 0f; var hi = 1f
            // the boundary: bisection on the reference itself
            repeat(60) { val mid = (lo + hi) / 2; if ((SrgbBytes.reference(mid).toInt() and 0xff) >= k) hi = mid else lo = mid }
            val bits = java.lang.Float.floatToRawIntBits(hi)
            for (d in -4096..4096) {
                val v = java.lang.Float.intBitsToFloat(bits + d)
                assertEquals(SrgbBytes.reference(v), SrgbBytes.encodeLinear(v), "v=$v")
            }
        }
        val random = java.util.Random(7)
        repeat(2_000_000) {
            val v = random.nextFloat() * 1.2f - 0.1f
            assertEquals(SrgbBytes.reference(v), SrgbBytes.encodeLinear(v), "v=$v")
        }
    }

    /** Every float in [0, 1] (about 1.07 billion); run once with -Plightly.probe. */
    @Test
    fun `encode equals the per-pixel function for every float in 0 to 1`() {
        assumeTrue(System.getProperty("lightly.probe") == "true")
        val last = java.lang.Float.floatToRawIntBits(1f)
        val mismatches = java.util.concurrent.atomic.AtomicLong()
        java.util.stream.IntStream.rangeClosed(0, last).parallel().forEach { bits ->
            val v = java.lang.Float.intBitsToFloat(bits)
            if (SrgbBytes.reference(v) != SrgbBytes.encodeLinear(v)) mismatches.incrementAndGet()
        }
        println("PROBE exhaustive encode mismatches: ${mismatches.get()}")
        assertEquals(0L, mismatches.get())
    }
}
