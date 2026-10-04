package com.lightlylabs.lightly.background

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Change background over a soft matte edge (hair): the original background's colour must not carry
 * into the result. Photo: a red wall with a grey subject in the middle whose matte falls off softly
 * over 12 px; replacement: blue. Edge pixels were a·grey + (1 − a)·red; composited as they are, they
 * kept a red fringe in front of the blue.
 */
class BackgroundDecontaminationTest {
    private val w = 120
    private val h = 60
    private val grey = 0.5f
    private val red = floatArrayOf(0.9f, 0.1f, 0.1f)
    private val blue = floatArrayOf(0.1f, 0.2f, 0.9f)

    /** Matte 1 in the middle columns, falling linearly to 0 over 12 px on each side. */
    private fun alphaAt(x: Int): Float {
        val distance = abs(x + 0.5f - w / 2f)
        return ((30f - distance) / 12f).coerceIn(0f, 1f)
    }

    private fun encode(linear: Float) = (Refocus.linearToSrgb(linear.coerceIn(0f, 1f)) * 255f + 0.5f).toInt().coerceIn(0, 255).toByte()

    @Test
    fun `soft edges take the subject colour, not the old background, over a replacement`() {
        val developed = ByteArray(w * h * 4)
        val matte = FloatPlane(w, h, FloatArray(w * h) { alphaAt(it % w) })
        for (p in 0 until w * h) {
            val a = matte.values[p]
            for (c in 0 until 3) developed[p * 4 + c] = encode(a * grey + (1 - a) * red[c])
            developed[p * 4 + 3] = -1
        }
        // Replacement in sRGB [0,1] at the working size, and as RGBA8 for the full-resolution composite.
        val replacementSrgb = FloatImage(w, h, 3, FloatArray(w * h * 3) { Refocus.linearToSrgb(blue[it % 3]) })
        val replacementBytes = ByteArray(w * h * 4) { i -> if (i % 4 == 3) -1 else encode(blue[i % 4]) }
        val analysis = BackgroundAnalysis(w, h, null, matte)
        val plan = BackgroundPlan(replacementSrgb, FocusParams(0.0, 40.0, "lens", "round", 50.0), 0.5,
            replacementFull = ReplacementPixels(w, h, replacementBytes))

        val working = BackgroundStage.renderWorking(developed, analysis, plan, Refocus.FocusConstants.LAYERS_PER_SIDE_PREVIEW)
        val out = BackgroundStage.applyRegion(developed, 0, 0, w, h, w, h, working, plan.replacementFull)

        // Expected at every pixel: a·grey + (1 − a)·blue. The red channel is where the fringe showed.
        var worstRedExcess = 0f
        for (y in 0 until h) for (x in 0 until w) {
            val a = alphaAt(x)
            if (a <= 0.05f || a >= 0.999f) continue
            val p = y * w + x
            val gotRed = Refocus.srgbToLinear((out[p * 4].toInt() and 0xff) / 255f)
            val wantRed = a * grey + (1 - a) * blue[0]
            worstRedExcess = maxOf(worstRedExcess, gotRed - wantRed)
        }
        // Without decontamination the excess is up to (1 − a)·(0.9 − 0.1) ≈ 0.6 in linear red.
        assertTrue(worstRedExcess < 0.03f, "red fringe on the soft edge: excess $worstRedExcess")
    }
}
