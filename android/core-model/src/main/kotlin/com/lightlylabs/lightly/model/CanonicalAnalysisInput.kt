package com.lightlylabs.lightly.model

import com.lightlylabs.lightly.render.image.Rgba8Image
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Canonical analysis input (spec §4.6): the whole decoded, oriented, sRGB frame resized — aspect
 * ignored — to 256×256 with the pinned antialiased bilinear filter, as float32 NCHW `[1,3,256,256]`,
 * sRGB-encoded [0,1], no mean/std.
 *
 * The filter is `torch.nn.functional.interpolate(mode="bilinear", antialias=True,
 * align_corners=False)` (itself Pillow's ImagingResample triangle filter): the support widens with
 * the downscale factor, so the result is independent of the source resolution. A non-antialiased
 * or different resampler moved Auto weights by up to 0.43 (14/255 of output) in M1, which is why
 * the algorithm is pinned rather than "any good resize".
 *
 * Ported from the LUTBench harness (experiments/lut3d/android/LUTBench/ImageUtil.kt), which matched
 * the golden tensors to 2.4e-7 on an emulator. Separable: horizontal pass, then vertical.
 */
object CanonicalAnalysisInput {
    const val SIZE = 256
    const val CHANNELS = 3

    /** Spec §4.6: the analysis source must have a long edge of at least 1024 px (or be the full Original). */
    const val MIN_SOURCE_LONG_EDGE = 1024

    /**
     * @param originalLongEdge long edge of the full-resolution Original. A reduced decode is allowed
     *   only while its long edge stays ≥ 1024; a smaller Original must be used at full size.
     */
    fun prepare(source: Rgba8Image, originalLongEdge: Int): FloatArray {
        val sourceLongEdge = max(source.width, source.height)
        require(sourceLongEdge >= min(MIN_SOURCE_LONG_EDGE, originalLongEdge)) {
            "Analysis source long edge $sourceLongEdge is below ${min(MIN_SOURCE_LONG_EDGE, originalLongEdge)}; " +
                "the display Proxy must never be the model input (spec §4.6)"
        }
        return resizeToChw(source, SIZE)
    }

    private class AxisCoefficients(val firstTap: IntArray, val weights: Array<FloatArray>)

    private fun triangleFilter(x: Double): Double {
        val ax = abs(x)
        return if (ax < 1.0) 1.0 - ax else 0.0
    }

    /** Per-output-index tap range and normalised weights, computed in double as PyTorch does. */
    private fun computeCoefficients(inputSize: Int, outputSize: Int): AxisCoefficients {
        val scale = inputSize.toDouble() / outputSize
        val support = if (scale >= 1.0) scale else 1.0
        val inverseScale = if (scale >= 1.0) 1.0 / scale else 1.0
        val firstTap = IntArray(outputSize)
        val weights = Array(outputSize) { FloatArray(0) }
        for (outIndex in 0 until outputSize) {
            val center = scale * (outIndex + 0.5)
            // Truncation toward zero (not floor) matches the C++ `(int64_t)(center - support + 0.5)`.
            val xmin = max((center - support + 0.5).toLong().toInt(), 0)
            val xsize = min((center + support + 0.5).toLong().toInt(), inputSize) - xmin
            val raw = DoubleArray(xsize) { j -> triangleFilter((j + xmin - center + 0.5) * inverseScale) }
            val total = raw.sum()
            firstTap[outIndex] = xmin
            weights[outIndex] = FloatArray(xsize) { j -> if (total != 0.0) (raw[j] / total).toFloat() else 0f }
        }
        return AxisCoefficients(firstTap, weights)
    }

    /** Returns NCHW float32 `[3, outSize, outSize]` in [0,1]. */
    internal fun resizeToChw(source: Rgba8Image, outSize: Int): FloatArray {
        val width = source.width
        val height = source.height
        val rgba = source.pixels
        val horizontal = computeCoefficients(width, outSize)
        val vertical = computeCoefficients(height, outSize)

        // Horizontal pass into an interleaved [height][outSize][3] float buffer.
        val intermediate = FloatArray(height * outSize * 3)
        for (y in 0 until height) {
            val rowBase = y * width * 4
            for (outX in 0 until outSize) {
                val start = horizontal.firstTap[outX]
                val taps = horizontal.weights[outX]
                var red = 0f
                var green = 0f
                var blue = 0f
                for (tap in taps.indices) {
                    val offset = rowBase + (start + tap) * 4
                    val weight = taps[tap]
                    red += weight * ((rgba[offset].toInt() and 0xff) / 255f)
                    green += weight * ((rgba[offset + 1].toInt() and 0xff) / 255f)
                    blue += weight * ((rgba[offset + 2].toInt() and 0xff) / 255f)
                }
                val dst = (y * outSize + outX) * 3
                intermediate[dst] = red
                intermediate[dst + 1] = green
                intermediate[dst + 2] = blue
            }
        }

        // Vertical pass into planar output.
        val plane = outSize * outSize
        val chw = FloatArray(CHANNELS * plane)
        for (outY in 0 until outSize) {
            val start = vertical.firstTap[outY]
            val taps = vertical.weights[outY]
            for (outX in 0 until outSize) {
                var red = 0f
                var green = 0f
                var blue = 0f
                for (tap in taps.indices) {
                    val src = ((start + tap) * outSize + outX) * 3
                    val weight = taps[tap]
                    red += weight * intermediate[src]
                    green += weight * intermediate[src + 1]
                    blue += weight * intermediate[src + 2]
                }
                val pixel = outY * outSize + outX
                chw[pixel] = red
                chw[plane + pixel] = green
                chw[2 * plane + pixel] = blue
            }
        }
        return chw
    }
}
