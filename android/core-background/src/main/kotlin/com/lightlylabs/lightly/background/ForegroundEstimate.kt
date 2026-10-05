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
        val bf = FloatArray(3)
        val bb = FloatArray(3)
        for (level in 0..levels) {
            val w = w0.toDouble().pow(level.toDouble() / levels).roundToInt()
            val h = h0.toDouble().pow(level.toDouble() / levels).roundToInt()
            val img = nearest(image, w, h)
            val a = nearest(alpha, w, h)
            val f = nearest(fPrev, w, h)
            val b = nearest(bPrev, w, h)
            val iterations = if (w <= SMALL_SIZE && h <= SMALL_SIZE) SMALL_ITERATIONS else BIG_ITERATIONS
            repeat(iterations) {
                for (y in 0 until h) for (x in 0 until w) {
                    val p = y * w + x
                    val a0 = a.values[p]
                    val a1 = 1f - a0
                    var a00 = a0 * a0
                    val a01 = a0 * a1
                    var a11 = a1 * a1
                    for (c in 0 until 3) { bf[c] = a0 * img.data[p * 3 + c]; bb[c] = a1 * img.data[p * 3 + c] }
                    for (d in 0 until 4) {
                        val x2 = min(max(x + DX[d], 0), w - 1)
                        val y2 = min(max(y + DY[d], 0), h - 1)
                        val q = y2 * w + x2
                        val da = REGULARIZATION + GRADIENT_WEIGHT * abs(a0 - a.values[q])
                        a00 += da
                        a11 += da
                        for (c in 0 until 3) { bf[c] += da * f.data[q * 3 + c]; bb[c] += da * b.data[q * 3 + c] }
                    }
                    val inv = 1f / (a00 * a11 - a01 * a01)
                    for (c in 0 until 3) {
                        f.data[p * 3 + c] = (inv * a11 * bf[c] - inv * a01 * bb[c]).coerceIn(0f, 1f)
                        b.data[p * 3 + c] = (-inv * a01 * bf[c] + inv * a00 * bb[c]).coerceIn(0f, 1f)
                    }
                }
            }
            fPrev = f
            bPrev = b
        }
        return fPrev
    }

    private val DX = intArrayOf(-1, 1, 0, 0)
    private val DY = intArrayOf(0, 0, -1, 1)

    private fun nearest(src: FloatImage, width: Int, height: Int) = FloatImage(width, height, src.channels, FloatArray(width * height * src.channels) { i ->
        val p = i / src.channels
        val sx = min(src.width - 1, (p % width) * src.width / width)
        val sy = min(src.height - 1, (p / width) * src.height / height)
        src.data[(sy * src.width + sx) * src.channels + i % src.channels]
    })

    private fun nearest(src: FloatPlane, width: Int, height: Int) = FloatPlane(width, height, FloatArray(width * height) { p ->
        val sx = min(src.width - 1, (p % width) * src.width / width)
        val sy = min(src.height - 1, (p / width) * src.height / height)
        src.values[sy * src.width + sx]
    })
}
