package com.lightlylabs.lightly.background

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * background.replace's subject colour (rendering-v2 revision 5): the foreground colour F behind a soft matte edge,
 * Germer et al., "Fast multi-level foreground estimation" (2020), exactly as pymatting's `estimate_foreground_ml`
 * and the contract reference `experiments/depth/refocus.py estimate_foreground` (float32, Gauss-Seidel in row-major
 * order, nearest-neighbour level resizing). Golden-checked against shared/fixtures/rendering `foreground`.
 *
 * Why: where the matte is soft (hair), the observed pixel is a mix of subject and old background; compositing it
 * over a replacement kept the old background's colour (a red wall through hair). The earlier Android fix subtracted
 * a coarse plate of the old background (f47c3c1), which over-corrected to cyan wherever the plate was wrong.
 */
object ForegroundEstimate {
    const val REGULARIZATION = 1e-5f
    const val GRADIENT_WEIGHT = 1f
    const val SMALL_ITERATIONS = 10
    const val BIG_ITERATIONS = 2
    const val SMALL_SIZE = 32

    /** F (interleaved linear RGB, clipped to [0, 1]) of [image] (interleaved linear RGB) given [alpha]. */
    fun estimate(image: FloatImage, alpha: FloatPlane): FloatImage {
        require(image.channels == 3 && image.width == alpha.width && image.height == alpha.height)
        val w0 = image.width
        val h0 = image.height
        val fMean = FloatArray(3)
        val bMean = FloatArray(3)
        var fCount = 0
        var bCount = 0
        for (p in 0 until w0 * h0) {
            val a = alpha.values[p]
            if (a > 0.9f) { for (c in 0 until 3) fMean[c] += image.data[p * 3 + c]; fCount++ }
            if (a < 0.1f) { for (c in 0 until 3) bMean[c] += image.data[p * 3 + c]; bCount++ }
        }
        for (c in 0 until 3) { fMean[c] /= fCount + 1e-5f; bMean[c] /= bCount + 1e-5f }
        var fPrev = FloatImage(1, 1, 3, fMean.copyOf())
        var bPrev = FloatImage(1, 1, 3, bMean.copyOf())
        val levels = ceil(ln(max(w0, h0).toDouble()) / ln(2.0)).toInt()
        for (level in 0..levels) {
            val w = w0.toDouble().pow(level.toDouble() / levels).roundToInt()
            val h = h0.toDouble().pow(level.toDouble() / levels).roundToInt()
            val img = nearest(image, w, h)
            val a = nearest(alpha, w, h)
            val f = nearest(fPrev, w, h)
            val b = nearest(bPrev, w, h)
            val iterations = if (w <= SMALL_SIZE && h <= SMALL_SIZE) SMALL_ITERATIONS else BIG_ITERATIONS
            repeat(iterations) { sweep(img.data, a.values, f.data, b.data, w, h) }
            fPrev = f
            bPrev = b
        }
        return fPrev
    }

    /**
     * One Gauss-Seidel sweep in row-major order. Speed (2026-10-07, drag frames): the three channels in local floats
     * instead of two arrays, and the clamp written out; each value is the same expression evaluated in the same order
     * as before (the four neighbours left, right, up, down, each adding to all channels), so every float is unchanged
     * (BackgroundExactnessTest).
     */
    private fun sweep(img: FloatArray, a: FloatArray, f: FloatArray, b: FloatArray, w: Int, h: Int) {
        for (y in 0 until h) for (x in 0 until w) {
            val p = y * w + x
            val a0 = a[p]
            val a1 = 1f - a0
            var a00 = a0 * a0
            val a01 = a0 * a1
            var a11 = a1 * a1
            var bf0 = a0 * img[p * 3]; var bf1 = a0 * img[p * 3 + 1]; var bf2 = a0 * img[p * 3 + 2]
            var bb0 = a1 * img[p * 3]; var bb1 = a1 * img[p * 3 + 1]; var bb2 = a1 * img[p * 3 + 2]
            for (d in 0 until 4) {
                val x2 = min(max(x + DX[d], 0), w - 1)
                val y2 = min(max(y + DY[d], 0), h - 1)
                val q = y2 * w + x2
                val da = REGULARIZATION + GRADIENT_WEIGHT * abs(a0 - a[q])
                a00 += da
                a11 += da
                bf0 += da * f[q * 3]; bb0 += da * b[q * 3]
                bf1 += da * f[q * 3 + 1]; bb1 += da * b[q * 3 + 1]
                bf2 += da * f[q * 3 + 2]; bb2 += da * b[q * 3 + 2]
            }
            val inv = 1f / (a00 * a11 - a01 * a01)
            f[p * 3] = clamp01(inv * a11 * bf0 - inv * a01 * bb0)
            b[p * 3] = clamp01(-inv * a01 * bf0 + inv * a00 * bb0)
            f[p * 3 + 1] = clamp01(inv * a11 * bf1 - inv * a01 * bb1)
            b[p * 3 + 1] = clamp01(-inv * a01 * bf1 + inv * a00 * bb1)
            f[p * 3 + 2] = clamp01(inv * a11 * bf2 - inv * a01 * bb2)
            b[p * 3 + 2] = clamp01(-inv * a01 * bf2 + inv * a00 * bb2)
        }
    }

    /** Exactly Float.coerceIn(0f, 1f) (NaN and -0f pass through unchanged), without the call. */
    @Suppress("NOTHING_TO_INLINE")
    private inline fun clamp01(v: Float): Float = if (v < 0f) 0f else if (v > 1f) 1f else v

    private val DX = intArrayOf(-1, 1, 0, 0)
    private val DY = intArrayOf(0, 0, -1, 1)

    // Speed (2026-10-07): the source column and row of each output column and row computed once, not per element;
    // the same integer expressions, so the same samples.
    private fun sourceIndex(size: Int, srcSize: Int) = IntArray(size) { min(srcSize - 1, it * srcSize / size) }

    private fun nearest(src: FloatImage, width: Int, height: Int): FloatImage {
        val ch = src.channels
        val sx = sourceIndex(width, src.width)
        val sy = sourceIndex(height, src.height)
        val out = FloatArray(width * height * ch)
        for (y in 0 until height) for (x in 0 until width) {
            val from = (sy[y] * src.width + sx[x]) * ch
            System.arraycopy(src.data, from, out, (y * width + x) * ch, ch)
        }
        return FloatImage(width, height, ch, out)
    }

    private fun nearest(src: FloatPlane, width: Int, height: Int): FloatPlane {
        val sx = sourceIndex(width, src.width)
        val sy = sourceIndex(height, src.height)
        val out = FloatArray(width * height)
        for (y in 0 until height) for (x in 0 until width) out[y * width + x] = src.values[sy[y] * src.width + sx[x]]
        return FloatPlane(width, height, out)
    }
}
