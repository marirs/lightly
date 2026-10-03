package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.develop.ColourMath.LUMA_B
import com.lightlylabs.lightly.develop.ColourMath.LUMA_G
import com.lightlylabs.lightly.develop.ColourMath.LUMA_R
import com.lightlylabs.lightly.develop.ColourMath.linearToSrgb
import com.lightlylabs.lightly.develop.ColourMath.smoothstep
import com.lightlylabs.lightly.develop.ColourMath.srgbToLinear
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Stage develop.global for one preset: a line-by-line port of `reference_model.develop_global`
 * (rendering-v2.md §4.1, steps G1–G11), in float64.
 *
 * Everything that depends only on the recipe (calibration matrix, white-balance gains, curve tables,
 * tone responses, band products) is computed once in the constructor, so [evaluate] is the per-pixel
 * part only. Instances are immutable and safe to share between bake threads.
 */
class DevelopGlobal(recipe: GlobalRecipe, model: DevelopModel) {
    private val c = model.global

    // G1 calibration: present → matrix (each row sums to 1), absent → only the clamp at 0.
    private val calibration: DoubleArray? = recipe.calibration?.let { calibrationMatrix(it, c) }

    // G2 white balance gains, normalised to keep luminance.
    private val gainR: Double
    private val gainG: Double
    private val gainB: Double

    // G3 exposure.
    private val exposureGain = 2.0.pow(recipe.exposureEv)

    // G4 shadow tint: green gain at full shadow weight.
    private val greenGain = exp(-recipe.shadowTint * c.kShadowTint * 10)
    private val hasShadowTint = recipe.shadowTint != 0.0

    // G5 basic tone.
    private val contrast = (recipe.toneSliders?.contrast ?: 0.0) / 100
    private val highlights = (recipe.toneSliders?.highlights ?: 0.0) / 100
    private val shadows = (recipe.toneSliders?.shadows ?: 0.0) / 100
    private val whites = (recipe.toneSliders?.whites ?: 0.0) / 100
    private val blacks = (recipe.toneSliders?.blacks ?: 0.0) / 100

    /** Per active tone row (contrast, highlights, shadows, whites, blacks, dehaze): tone_A·s + tone_B·s² per knot. */
    private val toneRowResponses: Array<DoubleArray> = run {
        val sliders = doubleArrayOf(contrast, highlights, shadows, whites, blacks, recipe.dehaze / 100)
        sliders.indices.filter { sliders[it] != 0.0 }.map { row ->
            DoubleArray(TONE_KNOTS) { knot -> c.toneA[row][knot] * sliders[row] + c.toneB[row][knot] * sliders[row] * sliders[row] }
        }.toTypedArray()
    }
    private val veil = c.kDehaze * recipe.dehaze / 100 * c.dehazeAir * 0.05

    // G6 parametric curve.
    private val parametric = recipe.parametricCurve

    // G7 point curves.
    private val masterCurve = recipe.toneCurve?.master?.let(CurveTable::of)
    private val redCurve = recipe.toneCurve?.red?.let(CurveTable::of)
    private val greenCurve = recipe.toneCurve?.green?.let(CurveTable::of)
    private val blueCurve = recipe.toneCurve?.blue?.let(CurveTable::of)

    // G8 HSL, per band: adjustment × calibrated band factor.
    private val hueAdjust: DoubleArray? = recipe.hsl?.let { h -> DoubleArray(BANDS) { h.hue[it] / 100 * c.hueBand[it] } }
    private val satAdjust: DoubleArray? = recipe.hsl?.let { h -> DoubleArray(BANDS) { h.saturation[it] / 100 * c.satBand[it] } }
    private val lumAdjust: DoubleArray? = recipe.hsl?.let { h -> DoubleArray(BANDS) { h.luminance[it] / 100 * c.lumBand[it] } }

    // G9.
    private val vibrance = (recipe.vibranceSaturation?.vibrance ?: 0.0) / 100
    private val saturationGain = maxOf(1 + c.kSat * (recipe.vibranceSaturation?.saturation ?: 0.0) / 100, 0.0)

    // G10 colour grading: per active zone, the a/b offsets and lightness step at full weight.
    private val grading = recipe.colorGrading
    private val gradeZones: List<GradeTerm> = grading?.let { cg ->
        listOf(cg.shadows, cg.midtones, cg.highlights, cg.global).mapIndexedNotNull { index, zone ->
            if (zone.saturation == 0.0 && zone.luminance == 0.0) return@mapIndexedNotNull null
            val angle = Math.toRadians(zone.hue + 25) // Lightroom wheel 0 = red; OKLab red is ~29 degrees
            val strength = c.kGrade * c.gradeZone[index] * zone.saturation / 100
            GradeTerm(index, strength * cos(angle), strength * sin(angle), c.kGradeLum * zone.luminance / 100 * 0.5)
        }
    }.orEmpty()

    // G11.
    private val grayscaleMix: DoubleArray? = recipe.grayscaleMix?.let { mix -> DoubleArray(BANDS) { mix[it] / 100 } }

    private class GradeTerm(val zone: Int, val deltaA: Double, val deltaB: Double, val deltaL: Double)

    init {
        val wb = recipe.whiteBalance
        val t = (wb?.temperature ?: 0.0) * c.kTemp
        val u = (wb?.tint ?: 0.0) * c.kTint
        val r = exp(t)
        val g = exp(-u)
        val b = exp(-t)
        val norm = r * LUMA_R + g * LUMA_G + b * LUMA_B
        gainR = r / norm
        gainG = g / norm
        gainB = b / norm
    }

    /**
     * develop.global of one sRGB-encoded colour, written to out[0..2] in [0, 1]. [scratch] must hold
     * at least [SCRATCH_SIZE] doubles; passing it avoids per-pixel allocation in the bake loop.
     */
    fun evaluate(red: Double, green: Double, blue: Double, out: DoubleArray, scratch: DoubleArray = DoubleArray(SCRATCH_SIZE)) {
        var lr = srgbToLinear(red)
        var lg = srgbToLinear(green)
        var lb = srgbToLinear(blue)

        // G1: rotated primaries can go below zero; negative light breaks the tone ratio, so clip.
        val m = calibration
        if (m != null) {
            val r = m[0] * lr + m[1] * lg + m[2] * lb
            val g = m[3] * lr + m[4] * lg + m[5] * lb
            val b = m[6] * lr + m[7] * lg + m[8] * lb
            lr = maxOf(r, 0.0); lg = maxOf(g, 0.0); lb = maxOf(b, 0.0)
        } else {
            lr = maxOf(lr, 0.0); lg = maxOf(lg, 0.0); lb = maxOf(lb, 0.0)
        }
        // G2, G3.
        lr *= gainR * exposureGain
        lg *= gainG * exposureGain
        lb *= gainB * exposureGain

        // G4: Y is taken before the multiply and reused by G5.
        val luma = maxOf(lr * LUMA_R + lg * LUMA_G + lb * LUMA_B, 1e-6)
        if (hasShadowTint) {
            val shadowWeight = 1 - smoothstep(0.0, 0.25, luma)
            lg *= greenGain.pow(shadowWeight)
        }

        // G5: tone delta on the encoded luminance, applied as a luminance ratio.
        val e = linearToSrgb(luma)
        var delta = c.kContrast * contrast * (e - 0.5) * 4 * e * (1 - e)
        delta += c.kHi * highlights * exp(-sq((e - c.cHi) / c.wHi)) * e
        delta += c.kSh * shadows * exp(-sq((e - c.cSh) / c.wSh)) * (1 - e)
        delta += c.kWh * whites * e * e * e * e
        delta += c.kBl * blacks * (1 - e) * (1 - e) * (1 - e) * (1 - e)
        // Accumulated row by row, as the reference adds `(basis @ response) * 0.1` per row.
        for (row in toneRowResponses) delta += hatProduct(e, row) * 0.1
        val target = srgbToLinear(maxOf(e + delta, 0.0))
        applyLuminance(lr, lg, lb, target, scratch)
        lr = (scratch[0] - veil) / (1 - veil)
        lg = (scratch[1] - veil) / (1 - veil)
        lb = (scratch[2] - veil) / (1 - veil)

        var er = linearToSrgb(lr)
        var eg = linearToSrgb(lg)
        var eb = linearToSrgb(lb)

        // G6 (x is not clamped here).
        val p = parametric
        if (p != null) {
            er += parametricDelta(er, p)
            eg += parametricDelta(eg, p)
            eb += parametricDelta(eb, p)
        }
        // G7: master on every channel, then each channel's own curve.
        if (masterCurve != null) {
            er = masterCurve.apply(er); eg = masterCurve.apply(eg); eb = masterCurve.apply(eb)
        }
        if (redCurve != null) er = redCurve.apply(er)
        if (greenCurve != null) eg = greenCurve.apply(eg)
        if (blueCurve != null) eb = blueCurve.apply(eb)

        // G8–G11 in OKLCh.
        ColourMath.linearToOklab(srgbToLinear(er.coerceIn(0.0, 1.0)), srgbToLinear(eg.coerceIn(0.0, 1.0)), srgbToLinear(eb.coerceIn(0.0, 1.0)), scratch)
        var lightness = scratch[0]
        val a = scratch[1]
        val b = scratch[2]
        var chroma = sqrt(a * a + b * b + 1e-9)
        var hue = ColourMath.pyMod(Math.toDegrees(atan2(b, a + 1e-9)), 360.0)
        val weights = scratch // reuse slots 3..10 for the band weights
        bandWeights(hue, weights, WEIGHT_OFFSET)
        val colourful = (chroma / 0.08).coerceIn(0.0, 1.0)
        if (hueAdjust != null && satAdjust != null && lumAdjust != null) {
            hue += c.kHue * dot(weights, hueAdjust) * colourful
            chroma *= maxOf(1 + c.kHslSat * dot(weights, satAdjust), 0.0)
            lightness += c.kHslLum * dot(weights, lumAdjust) * colourful * lightness
        }
        chroma *= maxOf(1 + c.kVib * vibrance * (1 - (chroma / 0.25).coerceIn(0.0, 1.0)), 0.0)
        chroma *= saturationGain
        var a2 = chroma * cos(Math.toRadians(hue))
        var b2 = chroma * sin(Math.toRadians(hue))
        val cg = grading
        if (cg != null && gradeZones.isNotEmpty()) {
            // Weights come from the L that G8 produced, once, before the loop.
            val balance = cg.balance / 100
            val blend = 0.15 + 0.35 * cg.blending / 100
            val wHigh = smoothstep(0.5 + 0.25 * balance - blend, 0.5 + 0.25 * balance + blend, lightness)
            val wShadow = 1 - wHigh
            val wMid = 1 - abs(wShadow - wHigh)
            for (term in gradeZones) {
                val weight = when (term.zone) { 0 -> wShadow; 1 -> wMid; 2 -> wHigh; else -> 1.0 }
                a2 += term.deltaA * weight
                b2 += term.deltaB * weight
                lightness += term.deltaL * weight
            }
        }
        val mix = grayscaleMix
        if (mix != null) {
            // Band weights and colourfulness from before the HSL edits.
            lightness *= 1 + 0.3 * dot(weights, mix) * colourful
            a2 = 0.0
            b2 = 0.0
        }
        ColourMath.oklabToLinear(lightness, a2, b2, scratch)
        out[0] = linearToSrgb(scratch[0]).coerceIn(0.0, 1.0)
        out[1] = linearToSrgb(scratch[1]).coerceIn(0.0, 1.0)
        out[2] = linearToSrgb(scratch[2]).coerceIn(0.0, 1.0)
    }

    /** apply_luminance: scale to the target luminance keeping hue; overflow past 1 is filled with neutral. */
    private fun applyLuminance(r: Double, g: Double, b: Double, target: Double, out: DoubleArray) {
        val luma = maxOf(r * LUMA_R + g * LUMA_G + b * LUMA_B, 1e-6)
        val ratio = target / luma
        val sr = r * ratio
        val sg = g * ratio
        val sb = b * ratio
        if (maxOf(sr, maxOf(sg, sb)) > 1) {
            val peak = maxOf(r, maxOf(g, b))
            val k = maxOf((1 - target) / maxOf(peak - luma, 1e-9), 0.0)
            val offset = target - k * luma
            out[0] = r * k + offset
            out[1] = g * k + offset
            out[2] = b * k + offset
        } else {
            out[0] = sr; out[1] = sg; out[2] = sb
        }
    }

    /** Σ_j hat_j(e)·response_j, with only the two non-zero hats evaluated. */
    private fun hatProduct(e: Double, response: DoubleArray): Double {
        var sum = 0.0
        for (j in 0 until TONE_KNOTS) {
            val hat = 1 - abs(e - j / 11.0) * 11
            if (hat > 0) sum += hat * response[j]
        }
        return sum
    }

    private fun parametricDelta(x: Double, p: ParametricCurve): Double {
        val s1 = p.shadowSplit / 100
        val s2 = p.midtoneSplit / 100
        val s3 = p.highlightSplit / 100
        val regions = p.shadows * bump(x, -s1, s1 * 2) + p.darks * bump(x, s1 - (s2 - s1), s2) +
            p.lights * bump(x, s2, s3 + (s3 - s2)) + p.highlights * bump(x, s3 - (1 - s3), 1 + (1 - s3))
        return c.kParam * regions / 100 * 0.25
    }

    private fun bump(x: Double, lower: Double, upper: Double): Double {
        val t = ((x - lower) / maxOf(upper - lower, 1e-3)).coerceIn(0.0, 1.0)
        val s = sin(PI * t)
        return s * s
    }

    private fun dot(weights: DoubleArray, values: DoubleArray): Double {
        var sum = 0.0
        for (i in 0 until BANDS) sum += weights[WEIGHT_OFFSET + i] * values[i]
        return sum
    }

    companion object {
        const val BANDS = 8
        const val TONE_KNOTS = 12
        private const val WEIGHT_OFFSET = 3

        /** Doubles a caller-provided scratch buffer must hold (3 colour slots + 8 band weights). */
        const val SCRATCH_SIZE = 16

        /** HSL band centres in degrees, red…magenta (circular). */
        private val CENTRES = doubleArrayOf(29.0, 55.0, 105.0, 142.0, 195.0, 264.0, 300.0, 328.0)
        private val SPAN_BELOW = DoubleArray(BANDS) { ColourMath.pyMod(CENTRES[it] - CENTRES[(it + BANDS - 1) % BANDS], 360.0) }
        private val SPAN_ABOVE = DoubleArray(BANDS) { ColourMath.pyMod(CENTRES[(it + 1) % BANDS] - CENTRES[it], 360.0) }

        private fun sq(x: Double) = x * x

        /** hsl_band_weights: the piecewise-linear partition of unity, written to out[offset..offset+7]. */
        internal fun bandWeights(hueDegrees: Double, out: DoubleArray, offset: Int) {
            var sum = 0.0
            for (i in 0 until BANDS) {
                val o = ColourMath.pyMod(hueDegrees - CENTRES[i] + 180, 360.0) - 180
                val w = if (o < 0) (1 + o / SPAN_BELOW[i]).coerceIn(0.0, 1.0) else (1 - o / SPAN_ABOVE[i]).coerceIn(0.0, 1.0)
                out[offset + i] = w
                sum += w
            }
            val norm = maxOf(sum, 1e-6)
            for (i in 0 until BANDS) out[offset + i] /= norm
        }

        /** calibration_matrix: rotate each primary toward its neighbour, scale its saturation; rows sum to 1. */
        internal fun calibrationMatrix(calibration: Calibration, c: GlobalConstants): DoubleArray {
            val hues = doubleArrayOf(calibration.redHue, calibration.greenHue, calibration.blueHue)
            val sats = doubleArrayOf(calibration.redSaturation, calibration.greenSaturation, calibration.blueSaturation)
            val matrix = DoubleArray(9) // row-major; column i is the transformed primary i
            for (i in 0 until 3) {
                val primary = DoubleArray(3).also { it[i] = 1.0 }
                val hueShift = hues[i] / 100 * c.kCalHue * c.calHue[i]
                primary[(i + 1) % 3] += maxOf(hueShift, 0.0)
                primary[(i + 2) % 3] += maxOf(-hueShift, 0.0)
                val saturation = 1 + sats[i] / 100 * c.kCalSat * c.calSat[i]
                val grey = (primary[0] + primary[1] + primary[2]) / 3
                for (row in 0 until 3) matrix[row * 3 + i] = grey + saturation * (primary[row] - grey)
            }
            for (row in 0 until 3) {
                val sum = matrix[row * 3] + matrix[row * 3 + 1] + matrix[row * 3 + 2]
                for (column in 0 until 3) matrix[row * 3 + column] /= sum
            }
            return matrix
        }
    }
}
