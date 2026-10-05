package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.image.Rgba8Image
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** A kept colour, as OKLab sampled when it was picked (rendering-v2 §6 Selective colour). */
data class KeptColour(val lightness: Double, val a: Double, val b: Double)

/**
 * `effects.selectiveColour` (rendering-v2 revision 4, §6): the kept colours stay, everything else is blended
 * towards its linear luminance by Strength. Matching is by hue in OKLCh, gated by saturation s = C / max(L, 0.05)
 * relative to the pick, symmetric in the ratio. Lightness does not count, so the shadowed parts of a red dress stay
 * red. Colour matching only: it does not know what an object is (picking red keeps red lips too).
 * Reference: shared/look-pack/reference_model.py `apply_selective_colour`.
 */
class SelectiveColour private constructor(colours: List<KeptColour>, range: Double, strength: Double) {
    private val pickSaturation = DoubleArray(colours.size) { saturationOf(colours[it].lightness, colours[it].a, colours[it].b) }
    private val pickHue = DoubleArray(colours.size) { hueOf(colours[it].a, colours[it].b) }
    private val hueWindow = 6 + 0.5 * range
    private val gateStart = 0.65 - 0.0055 * range
    private val gateFull = gateStart + 0.25
    private val outsideColourfulness = 1 - strength / 100

    /** The 'stays in colour' weight of a pixel with OKLab (l, a, b). */
    fun keep(l: Double, a: Double, b: Double): Double {
        val saturation = saturationOf(l, a, b)
        val hue = hueOf(a, b)
        var keep = 0.0
        for (i in pickSaturation.indices) {
            val match = if (pickSaturation[i] < NEUTRAL_PICK) {
                1 - ColourMath.smoothstep(NEUTRAL_PICK, 2 * NEUTRAL_PICK, saturation)
            } else {
                val hueDistance = abs(ColourMath.pyMod(hue - pickHue[i] + 180, 360.0) - 180)
                val byHue = ((hueWindow - hueDistance) / (0.5 * hueWindow)).coerceIn(0.0, 1.0)
                val ratio = saturation / pickSaturation[i]
                // Symmetric: far less saturated (greys, pale skin for a red) and far more saturated (a red sign
                // for a picked skin tone) are both left out.
                byHue * ColourMath.smoothstep(gateStart, gateFull, min(ratio, 1 / max(ratio, 1e-6)))
            }
            keep = max(keep, match)
        }
        return keep
    }

    /** rgb sRGB-encoded in [0, 1], in place. [work] holds ≥ 3 doubles. */
    fun apply(rgb: FloatArray, work: DoubleArray) {
        val r = ColourMath.srgbToLinear(rgb[0].toDouble())
        val g = ColourMath.srgbToLinear(rgb[1].toDouble())
        val b = ColourMath.srgbToLinear(rgb[2].toDouble())
        ColourMath.linearToOklab(r, g, b, work)
        val keep = keep(work[0], work[1], work[2])
        val colourfulness = keep + (1 - keep) * outsideColourfulness
        val luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        rgb[0] = ColourMath.linearToSrgb(luminance + (r - luminance) * colourfulness).toFloat()
        rgb[1] = ColourMath.linearToSrgb(luminance + (g - luminance) * colourfulness).toFloat()
        rgb[2] = ColourMath.linearToSrgb(luminance + (b - luminance) * colourfulness).toFloat()
    }

    companion object {
        /** s = C / max(L, this): near-black pixels have no reliable hue. */
        private const val MIN_LIGHTNESS = 0.05
        /** A pick less saturated than this keeps only near-neutral pixels. */
        private const val NEUTRAL_PICK = 0.04

        private fun saturationOf(l: Double, a: Double, b: Double) = hypot(a, b) / max(l, MIN_LIGHTNESS)
        private fun hueOf(a: Double, b: Double) = ColourMath.pyMod(Math.toDegrees(atan2(b, a)), 360.0)

        /** Null when there is nothing to keep: the operator then does nothing. */
        fun of(e: EffectsParams): SelectiveColour? =
            if (e.selectiveColours.isEmpty()) null else SelectiveColour(e.selectiveColours, e.selectiveRange, e.selectiveStrength)

        /**
         * The kept colour for a tap at ([xFraction], [yFraction]) of [frame] (this stage's input): OKLab of the mean
         * linear colour over a square of side max(3, round(1 % of the long edge)) px centred on the tapped pixel,
         * clipped to the frame.
         */
        fun sample(frame: Rgba8Image, xFraction: Double, yFraction: Double): KeptColour =
            sample(frame.width, frame.height, xFraction, yFraction) { x, y, c ->
                ColourMath.srgbToLinear((frame.pixels[(y * frame.width + x) * 4 + c].toInt() and 0xff) / 255.0)
            }

        /** As [sample] for any frame whose linear colour channel c at (x, y) is [linearAt]. */
        inline fun sample(width: Int, height: Int, xFraction: Double, yFraction: Double, linearAt: (Int, Int, Int) -> Double): KeptColour {
            val side = max(3, (0.01 * max(width, height)).roundToInt())
            val half = side / 2
            val cx = min(width - 1, (xFraction * width).toInt().coerceAtLeast(0))
            val cy = min(height - 1, (yFraction * height).toInt().coerceAtLeast(0))
            val sum = DoubleArray(3)
            var n = 0
            for (y in max(0, cy - half)..min(height - 1, cy + half)) for (x in max(0, cx - half)..min(width - 1, cx + half)) {
                for (c in 0 until 3) sum[c] += linearAt(x, y, c)
                n++
            }
            val lab = DoubleArray(3)
            ColourMath.linearToOklab(sum[0] / n, sum[1] / n, sum[2] / n, lab)
            return KeptColour(lab[0], lab[1], lab[2])
        }
    }
}
