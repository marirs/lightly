package com.lightlylabs.lightly.vision

import com.lightlylabs.lightly.background.FloatPlane
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.assertTrue

class ClosedFormMattingTest {
    private fun floats(name: String): FloatArray {
        val bytes = javaClass.getResourceAsStream("/closed-form/$name")!!.readBytes()
        return FloatArray(bytes.size / 4).also { ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(it) }
    }

    @Test
    fun `matches pymatting estimate_alpha_cf on a hair crop of the dark studio portrait`() {
        val w = 96; val h = 96
        val rgb = floats("image.f32")
        val image = Array(3) { c -> FloatPlane(w, h, FloatArray(w * h) { rgb[it * 3 + c] }) }
        val trimap = floats("trimap.f32").map { it.toDouble() }.toDoubleArray()
        val expected = floats("alpha.f32")
        val solved = ClosedFormMatting.solve(image, trimap, w, h)!!
        var worst = 0.0
        for (i in expected.indices) worst = maxOf(worst, kotlin.math.abs(solved[i].coerceIn(0.0, 1.0) - expected[i]))
        assertTrue(worst < 1e-3, "max |difference| $worst")
    }

    @Test
    fun `recovers the alpha of a two-colour blend from its ends`() {
        // I = a F + (1 − a) B with constant F and B: the colour-line model holds exactly, so the solution is a.
        val w = 40; val h = 12
        val alpha = DoubleArray(w * h) { ((it % w) - 10).coerceIn(0, 20) / 20.0 }
        val f = doubleArrayOf(0.9, 0.2, 0.1); val b = doubleArrayOf(0.1, 0.3, 0.8)
        val image = Array(3) { c -> FloatPlane(w, h, FloatArray(w * h) { (alpha[it] * f[c] + (1 - alpha[it]) * b[c]).toFloat() }) }
        val trimap = DoubleArray(w * h) { val x = it % w; if (x < 6) 0.0 else if (x >= 34) 1.0 else Double.NaN }
        val solved = ClosedFormMatting.solve(image, trimap, w, h)!!
        for (i in solved.indices) assertTrue(kotlin.math.abs(solved[i] - alpha[i]) < 1e-3, "pixel $i: ${solved[i]} vs ${alpha[i]}")
    }
}
