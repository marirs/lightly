package com.lightlylabs.lightly.develop

import kotlin.math.floor
import kotlin.math.pow

/**
 * Colour helpers of rendering-v2.md §2, in float64 like reference_model.py. Each function mirrors
 * the NumPy expression it is named after, including the clamps and floors that look redundant: they
 * are part of the contract (for example the 1e-7 floor before the OKLab cube root).
 */
object ColourMath {
    const val LUMA_R = 0.2126
    const val LUMA_G = 0.7152
    const val LUMA_B = 0.0722

    private const val INVERSE_GAMMA = 1.0 / 2.4

    /** `srgb_to_linear`. Defined for any input; values above 1 follow the power branch. */
    fun srgbToLinear(e: Double): Double = if (e <= 0.04045) e / 12.92 else ((maxOf(e, 0.04045) + 0.055) / 1.055).pow(2.4)

    /** `linear_to_srgb`, with the input clamped to ≥ 0 first. */
    fun linearToSrgb(linear: Double): Double {
        val l = if (linear > 0.0) linear else 0.0
        return if (l <= 0.0031308) l * 12.92 else 1.055 * maxOf(l, 0.0031308).pow(INVERSE_GAMMA) - 0.055
    }

    fun smoothstep(edge0: Double, edge1: Double, x: Double): Double {
        val t = ((x - edge0) / (edge1 - edge0)).coerceIn(0.0, 1.0)
        return t * t * (3 - 2 * t)
    }

    /** Python's float `%`: the result takes the sign of the divisor. */
    fun pyMod(x: Double, m: Double): Double {
        var r = x % m
        if (r != 0.0 && ((m < 0) != (r < 0))) r += m
        return r
    }

    // Ottosson's OKLab matrices (reference_model.OKLAB_M1 / OKLAB_M2), row-major.
    val M1 = doubleArrayOf(
        0.4122214708, 0.5363325363, 0.0514459929,
        0.2119034982, 0.6806995451, 0.1073969566,
        0.0883024619, 0.2817188376, 0.6299787005,
    )
    val M2 = doubleArrayOf(
        0.2104542553, 0.7936177850, -0.0040720468,
        1.9779984951, -2.4285922050, 0.4505937099,
        0.0259040371, 0.7827717662, -0.8086757660,
    )

    /** The exact inverses, as np.linalg.inv computes them (to float64 rounding). */
    val M1_INV = invert3x3(M1)
    val M2_INV = invert3x3(M2)

    /** linear sRGB → OKLab into out[0..2]. */
    fun linearToOklab(r: Double, g: Double, b: Double, out: DoubleArray) {
        // Math.cbrt equals NumPy's x ** (1/3) to within an ulp and is several times faster than pow.
        val l = Math.cbrt(maxOf(M1[0] * r + M1[1] * g + M1[2] * b, 1e-7))
        val m = Math.cbrt(maxOf(M1[3] * r + M1[4] * g + M1[5] * b, 1e-7))
        val s = Math.cbrt(maxOf(M1[6] * r + M1[7] * g + M1[8] * b, 1e-7))
        out[0] = M2[0] * l + M2[1] * m + M2[2] * s
        out[1] = M2[3] * l + M2[4] * m + M2[5] * s
        out[2] = M2[6] * l + M2[7] * m + M2[8] * s
    }

    /** OKLab → linear sRGB into out[0..2] (no clamp; the caller encodes with [linearToSrgb]). */
    fun oklabToLinear(lightness: Double, a: Double, b: Double, out: DoubleArray) {
        val l = M2_INV[0] * lightness + M2_INV[1] * a + M2_INV[2] * b
        val m = M2_INV[3] * lightness + M2_INV[4] * a + M2_INV[5] * b
        val s = M2_INV[6] * lightness + M2_INV[7] * a + M2_INV[8] * b
        val l3 = l * l * l
        val m3 = m * m * m
        val s3 = s * s * s
        out[0] = M1_INV[0] * l3 + M1_INV[1] * m3 + M1_INV[2] * s3
        out[1] = M1_INV[3] * l3 + M1_INV[4] * m3 + M1_INV[5] * s3
        out[2] = M1_INV[6] * l3 + M1_INV[7] * m3 + M1_INV[8] * s3
    }

    fun invert3x3(m: DoubleArray): DoubleArray {
        val (a, b, c) = Triple(m[0], m[1], m[2])
        val (d, e, f) = Triple(m[3], m[4], m[5])
        val (g, h, i) = Triple(m[6], m[7], m[8])
        val det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        require(det != 0.0) { "singular matrix" }
        return doubleArrayOf(
            (e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
            (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
            (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det,
        )
    }

    internal fun floorInt(value: Double): Int = floor(value).toInt()
}
