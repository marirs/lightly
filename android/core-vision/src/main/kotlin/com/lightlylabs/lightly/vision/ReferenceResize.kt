package com.lightlylabs.lightly.vision

import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.max

/**
 * `skimage.transform.resize(image, (outHeight, outWidth), mode='constant')` for an 8-bit RGB image, as U²-Netp's
 * reference pipeline uses it (u2net_test.py RescaleT; scikit-image 0.26 `_warps.resize`):
 * 1. uint8 → [0, 1] (`img_as_float`);
 * 2. anti-aliasing when an axis shrinks: `scipy.ndimage.gaussian_filter`, σ = max(0, (in/out − 1) / 2) per axis,
 *    truncate 4 (radius = int(4σ + 0.5)), mode 'constant' (zero outside the image);
 * 3. `scipy.ndimage.zoom(order=1, mode='grid-constant', grid_mode=True)`: sample (o + 0.5)·in/out − 0.5,
 *    linear, zero outside;
 * 4. the clip to the input's range is a no-op for linear interpolation of non-negative values.
 *
 * Why exact: a plain bilinear stretch (no anti-aliasing) changed U²-Netp's output by up to 0.99 on the desk
 * fixtures and turned the bar scene into a "subject" (docs/v1/android-vision-evaluation.md §5).
 *
 * The filter is separable and linear, so it is evaluated only at the rows and columns the zoom samples (at most
 * two per output pixel per axis); the values equal filtering the whole image. Float32 arithmetic (the reference
 * is float64): golden-checked within 1e-5 (ReferenceResizeTest).
 */
object ReferenceResize {
    const val TRUNCATE = 4.0

    /** Interleaved RGB (outHeight × outWidth × 3) in [0, 1]. */
    fun resize(image: RgbaImage, outWidth: Int, outHeight: Int): FloatArray {
        val w = image.width
        val h = image.height
        val kernelY = gaussianKernel(sigmaFor(h, outHeight))
        val kernelX = gaussianKernel(sigmaFor(w, outWidth))
        val rowsY = samples(h, outHeight)
        val colsX = samples(w, outWidth)
        // The source rows and columns the zoom reads (in range; out-of-range taps read zero).
        val neededRows = rowsY.flatMap { listOf(it.index, it.index + 1) }.filter { it in 0 until h }.distinct().sorted()
        val neededCols = colsX.flatMap { listOf(it.index, it.index + 1) }.filter { it in 0 until w }.distinct().sorted()
        val rowSlot = IntArray(h) { -1 }.also { slots -> neededRows.forEachIndexed { i, r -> slots[r] = i } }
        val colSlot = IntArray(w) { -1 }.also { slots -> neededCols.forEachIndexed { i, c -> slots[c] = i } }
        val out = FloatArray(outWidth * outHeight * 3)
        val radiusY = kernelY.size / 2
        val radiusX = kernelX.size / 2
        for (c in 0 until 3) {
            // Axis 0 (rows) first, as scipy: filtered rows, full width.
            val vertical = Array(neededRows.size) { FloatArray(w) }
            for ((slot, row) in neededRows.withIndex()) {
                val target = vertical[slot]
                for (k in kernelY.indices) {
                    val sy = row + k - radiusY
                    if (sy < 0 || sy >= h) continue
                    val weight = kernelY[k]
                    val base = sy * w * 4 + c
                    for (x in 0 until w) target[x] += weight * ((image.pixels[base + x * 4].toInt() and 0xff) / 255f)
                }
            }
            // Axis 1 (columns) at the needed columns only.
            val filtered = Array(neededRows.size) { FloatArray(neededCols.size) }
            for (slot in neededRows.indices) {
                val source = vertical[slot]
                val target = filtered[slot]
                for ((j, col) in neededCols.withIndex()) {
                    var sum = 0f
                    for (k in kernelX.indices) {
                        val sx = col + k - radiusX
                        if (sx in 0 until w) sum += kernelX[k] * source[sx]
                    }
                    target[j] = sum
                }
            }
            fun at(row: Int, col: Int): Float =
                if (row !in 0 until h || col !in 0 until w) 0f else filtered[rowSlot[row]][colSlot[col]]
            for ((oy, sy) in rowsY.withIndex()) for ((ox, sx) in colsX.withIndex()) {
                val top = at(sy.index, sx.index) * (1 - sx.fraction) + at(sy.index, sx.index + 1) * sx.fraction
                val bottom = at(sy.index + 1, sx.index) * (1 - sx.fraction) + at(sy.index + 1, sx.index + 1) * sx.fraction
                out[(oy * outWidth + ox) * 3 + c] = top * (1 - sy.fraction) + bottom * sy.fraction
            }
        }
        return out
    }

    /** scikit-image's anti-aliasing σ for one axis: only when it shrinks. */
    fun sigmaFor(input: Int, output: Int): Double = max(0.0, (input.toDouble() / output - 1) / 2)

    /** scipy `_gaussian_kernel1d(σ, 0, int(truncate·σ + 0.5))`, normalised; [1] when σ = 0 (axis not filtered). */
    fun gaussianKernel(sigma: Double): FloatArray {
        if (sigma <= 1e-15) return floatArrayOf(1f)
        val radius = (TRUNCATE * sigma + 0.5).toInt()
        val weights = DoubleArray(2 * radius + 1) { i -> val x = (i - radius).toDouble(); exp(-0.5 / (sigma * sigma) * x * x) }
        val total = weights.sum()
        return FloatArray(weights.size) { (weights[it] / total).toFloat() }
    }

    /** The zoom's source coordinate for each output index: floor and fraction of (o + 0.5)·in/out − 0.5. */
    private fun samples(input: Int, output: Int): List<Sample> {
        val scale = input.toDouble() / output
        return List(output) { o ->
            val coordinate = (o + 0.5) * scale - 0.5
            val index = floor(coordinate).toInt()
            Sample(index, (coordinate - index).toFloat())
        }
    }

    private data class Sample(val index: Int, val fraction: Float)
}
