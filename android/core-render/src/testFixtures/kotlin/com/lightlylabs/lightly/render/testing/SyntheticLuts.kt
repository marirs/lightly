package com.lightlylabs.lightly.render.testing

import com.lightlylabs.lightly.render.lut.Lut3D
import kotlin.math.PI
import kotlin.math.pow
import kotlin.math.sin

/** Hand-built LUTs for tests that must not depend on curated Looks (which do not exist until M3). */
object SyntheticLuts {

    /**
     * Port of `look_lut()` in experiments/lut3d/reference/test_lut_composition.py: an S-curve plus a
     * warm/teal split, strong enough that composition error is not trivially small. The mean used
     * for the blue shift is recomputed after the red shift, exactly as the NumPy code does.
     */
    fun strongLook(dimension: Int = Lut3D.CONTRACT_DIMENSION): Lut3D = fromFunction(dimension) { r, g, b, out ->
        var red = r.toDouble().pow(1.1)
        var green = g.toDouble().pow(1.1)
        var blue = b.toDouble().pow(1.1)
        red += 0.12 * sin(PI * (red - 0.5)) * 0.5
        green += 0.12 * sin(PI * (green - 0.5)) * 0.5
        blue += 0.12 * sin(PI * (blue - 0.5)) * 0.5
        red += 0.06 * ((red + green + blue) / 3 - 0.4)
        blue -= 0.06 * ((red + green + blue) / 3 - 0.4)
        out[0] = red.toFloat(); out[1] = green.toFloat(); out[2] = blue.toFloat()
    }

    /**
     * An Auto-like LUT whose entries leave [0,1] at both ends (shadows below 0, highlights above 1),
     * like the real fused Auto LUTs (−0.14…1.48), so the boundary rule is actually exercised.
     */
    fun outOfRangeAuto(dimension: Int = Lut3D.CONTRACT_DIMENSION): Lut3D = fromFunction(dimension) { r, g, b, out ->
        out[0] = 1.35f * r - 0.12f + 0.05f * g
        out[1] = 1.25f * g - 0.08f
        out[2] = 1.30f * b - 0.14f + 0.04f * r
    }

    fun fromFunction(dimension: Int, function: (Float, Float, Float, FloatArray) -> Unit): Lut3D {
        val rgba = FloatArray(Lut3D.floatCount(dimension))
        val out = FloatArray(3)
        for (b in 0 until dimension) for (g in 0 until dimension) for (r in 0 until dimension) {
            function(Lut3D.gridValue(r, dimension), Lut3D.gridValue(g, dimension), Lut3D.gridValue(b, dimension), out)
            val base = (r + dimension * (g + dimension * b)) * 4
            rgba[base] = out[0]; rgba[base + 1] = out[1]; rgba[base + 2] = out[2]; rgba[base + 3] = 1f
        }
        return Lut3D(dimension, rgba)
    }
}
