package com.lightlylabs.lightly.vision

import com.lightlylabs.lightly.background.FloatPlane
import com.lightlylabs.lightly.background.PlaneOps
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Closed-form matting (Levin, Lischinski and Weiss 2008) of a prior matte (2026-10-06, completion plan A4).
 *
 * Why: MODNet's alpha is too low in dense curls over a saturated wall (median 0.62 where the compositing equation
 * needs ~0.99), so the foreground-colour estimate over-subtracts the wall and leaves a teal cast, and its soft tail
 * leaves a grey haze around hair. Solving the matting equation in the uncertain band, with MODNet's confident parts as
 * the trimap, fixes the opacity from the photo's own colours. Offline on the recorded stages (both approved portraits,
 * light and dark replacements): teal 56,379 → 31,998 / 2,966 → 53 px, haze 5.5 → 2.4 / 26.2 → 13.1, red excess not
 * worse, hair crisp (experiments/depth/portrait_edges/exp_alpha_opacity.py). Same equations and constants as
 * pymatting's estimate_alpha_cf (window radius 1, ε = 1e-7, unknown pixels solved with known ones fixed); converges to
 * its solution (cf_matrix_free.py, max difference 0).
 *
 * Matrix-free: the Laplacian is applied window by window and only windows touching an unknown pixel are kept, so the
 * cost follows the hair band (~8 % of a 768 px frame), not the image.
 */
object ClosedFormMatting {
    /** The working long edge: the Save-copy Background working size, where the offline result was measured. */
    const val WORKING_LONG_EDGE = 768
    const val EPSILON = 1e-7
    /** Trimap: sure foreground ≥ this, sure background ≤ 1 − this, each eroded by [TRIMAP_ERODE_RADIUS] (square). */
    const val SURE = 0.95f
    const val TRIMAP_ERODE_RADIUS = 3
    const val MAX_ITERATIONS = 2000
    /**
     * Relative residuals. Full size 1e-4 after the coarse start: within 0.007 of the converged alpha at the 99th
     * percentile, 0.024 at most (pd03, 768 px; under 2/255 for 99 % of the band). The half-size level 1e-5.
     */
    const val TOLERANCE = 1e-4
    const val COARSE_TOLERANCE = 1e-5
    const val COARSE_ERODE_RADIUS = 2

    /** The last [refine]'s duration and size of its uncertain band, for diagnostics (the app logs them). */
    @Volatile var lastRefineMillis: Long = 0
    @Volatile var lastUnknownPixels: Int = 0

    /**
     * [prior] refined on [rgba] (8-bit sRGB RGBA, same size as [prior]): solved at [WORKING_LONG_EDGE] and returned at
     * the prior's size. Where the solve does not apply (no uncertain band) the prior is returned unchanged.
     */
    fun refine(rgba: ByteArray, width: Int, height: Int, prior: FloatPlane, checkpoint: () -> Unit = {}): FloatPlane {
        require(prior.width == width && prior.height == height) { "prior ${prior.width}x${prior.height} is not ${width}x$height" }
        val started = System.nanoTime()
        try {
            return refineTimed(rgba, width, height, prior, checkpoint)
        } finally {
            lastRefineMillis = (System.nanoTime() - started) / 1_000_000
        }
    }

    private fun refineTimed(rgba: ByteArray, width: Int, height: Int, prior: FloatPlane, checkpoint: () -> Unit): FloatPlane {
        val scale = min(1.0, WORKING_LONG_EDGE.toDouble() / max(width, height))
        val w = max(3, (width * scale).roundToInt())
        val h = max(3, (height * scale).roundToInt())
        val image = Array(3) { c -> com.lightlylabs.lightly.background.DepthModelInput.resizeArea(FloatPlane(width, height, FloatArray(width * height) { (rgba[it * 4 + c].toInt() and 0xff) / 255f }), w, h) }
        val alpha = PlaneOps.resizeBilinear(prior, w, h)
        val trimap = trimap(alpha, TRIMAP_ERODE_RADIUS)
        // Coarse to fine: the same problem at half size (a quarter of the unknowns) gives the full-size solve its start,
        // where conjugate gradients are slowest to remove the smooth part of the error (pd03: 316 → 111 iterations at
        // full size, within 0.007 of the converged alpha at the 99th percentile; cf_matrix_free.py).
        val start = coarseStart(image, alpha, w, h, checkpoint) ?: alpha
        val solved = solve(image, trimap, w, h, checkpoint, start = start, tolerance = TOLERANCE) ?: return prior
        return PlaneOps.resizeBilinear(FloatPlane(w, h, FloatArray(w * h) { solved[it].coerceIn(0.0, 1.0).toFloat() }), width, height)
    }

    /** The half-size solution, resized to w × h, as the full-size start; null when there is nothing to solve. */
    private fun coarseStart(image: Array<FloatPlane>, alpha: FloatPlane, w: Int, h: Int, checkpoint: () -> Unit): FloatPlane? {
        val hw = w / 2
        val hh = h / 2
        if (hw < 3 || hh < 3) return null
        val small = Array(3) { c -> com.lightlylabs.lightly.background.DepthModelInput.resizeArea(image[c], hw, hh) }
        val smallAlpha = PlaneOps.resizeBilinear(alpha, hw, hh)
        val solved = solve(small, trimap(smallAlpha, COARSE_ERODE_RADIUS), hw, hh, checkpoint, start = smallAlpha, tolerance = COARSE_TOLERANCE) ?: return null
        return PlaneOps.resizeBilinear(FloatPlane(hw, hh, FloatArray(hw * hh) { solved[it].coerceIn(0.0, 1.0).toFloat() }), w, h)
    }

    /** 1 sure foreground, 0 sure background, NaN unknown. */
    internal fun trimap(alpha: FloatPlane, erodeRadius: Int = TRIMAP_ERODE_RADIUS): DoubleArray {
        val w = alpha.width
        val h = alpha.height
        val fg = erode(BooleanArray(w * h) { alpha.values[it] >= SURE }, w, h, erodeRadius)
        val bg = erode(BooleanArray(w * h) { alpha.values[it] <= 1 - SURE }, w, h, erodeRadius)
        return DoubleArray(w * h) { if (fg[it]) 1.0 else if (bg[it]) 0.0 else Double.NaN }
    }

    /** Square erosion; outside the frame counts as set (as cv2.erode's default border). Separable: rows, then columns. */
    private fun erode(mask: BooleanArray, w: Int, h: Int, r: Int): BooleanArray {
        val rows = BooleanArray(w * h) { p -> val x = p % w; val y = p / w; (max(0, x - r)..min(w - 1, x + r)).all { mask[y * w + it] } }
        return BooleanArray(w * h) { p -> val x = p % w; val y = p / w; (max(0, y - r)..min(h - 1, y + r)).all { rows[it * w + x] } }
    }

    /**
     * The kept windows (3×3, touching an unknown pixel), flattened for the solver:
     * - [variable]: for each window's 9 pixels, the pixel's index among the unknowns, or −1 for a known pixel;
     * - [offset]: each pixel's colour minus the window mean (9 × 3);
     * - [inverse]: (Σ + ε/9 I)⁻¹, symmetric, 6 values.
     */
    private class Windows(val count: Int, val centre: IntArray, val variable: IntArray, val offset: DoubleArray, val inverse: DoubleArray)

    private val OFFSETS_X = intArrayOf(-1, 0, 1, -1, 0, 1, -1, 0, 1)
    private val OFFSETS_Y = intArrayOf(-1, -1, -1, 0, 0, 0, 1, 1, 1)

    private fun windows(image: Array<FloatPlane>, variableOf: IntArray, w: Int, h: Int): Windows {
        val centres = ArrayList<Int>()
        for (y in 1 until h - 1) for (x in 1 until w - 1) {
            var touches = false
            for (k in 0 until 9) if (variableOf[(y + OFFSETS_Y[k]) * w + x + OFFSETS_X[k]] >= 0) { touches = true; break }
            if (touches) centres += y * w + x
        }
        val n = centres.size
        val variable = IntArray(n * 9)
        val offset = DoubleArray(n * 27)
        val inverse = DoubleArray(n * 6)
        java.util.stream.IntStream.range(0, n).parallel().forEach { k ->
            val c = centres[k]
            var m0 = 0.0; var m1 = 0.0; var m2 = 0.0
            for (j in 0 until 9) { val p = c + OFFSETS_Y[j] * w + OFFSETS_X[j]; m0 += image[0].values[p]; m1 += image[1].values[p]; m2 += image[2].values[p] }
            m0 /= 9; m1 /= 9; m2 /= 9
            var s00 = 0.0; var s01 = 0.0; var s02 = 0.0; var s11 = 0.0; var s12 = 0.0; var s22 = 0.0
            for (j in 0 until 9) {
                val p = c + OFFSETS_Y[j] * w + OFFSETS_X[j]
                val d0 = image[0].values[p] - m0; val d1 = image[1].values[p] - m1; val d2 = image[2].values[p] - m2
                offset[k * 27 + j * 3] = d0; offset[k * 27 + j * 3 + 1] = d1; offset[k * 27 + j * 3 + 2] = d2
                variable[k * 9 + j] = variableOf[p]
                s00 += d0 * d0; s01 += d0 * d1; s02 += d0 * d2; s11 += d1 * d1; s12 += d1 * d2; s22 += d2 * d2
            }
            val reg = EPSILON / 9
            s00 = s00 / 9 + reg; s11 = s11 / 9 + reg; s22 = s22 / 9 + reg; s01 /= 9; s02 /= 9; s12 /= 9
            // Inverse of the symmetric 3×3 by cofactors.
            val c00 = s11 * s22 - s12 * s12; val c01 = s02 * s12 - s01 * s22; val c02 = s01 * s12 - s02 * s11
            val c11 = s00 * s22 - s02 * s02; val c12 = s01 * s02 - s00 * s12; val c22 = s00 * s11 - s01 * s01
            val det = s00 * c00 + s01 * c01 + s02 * c02
            inverse[k * 6] = c00 / det; inverse[k * 6 + 1] = c01 / det; inverse[k * 6 + 2] = c02 / det
            inverse[k * 6 + 3] = c11 / det; inverse[k * 6 + 4] = c12 / det; inverse[k * 6 + 5] = c22 / det
        }
        return Windows(n, centres.toIntArray(), variable, offset, inverse)
    }

    /**
     * out = L_UU · x over the unknowns (x and out indexed by unknown; known pixels count as 0). Per window,
     * s = Σ x_j and v = M Σ d_j x_j; each unknown pixel i of the window then gets x_i − (s + d_i·v) / 9. Windows are
     * split into [chunks] ranges, each accumulating into its own buffer (no write conflicts), summed afterwards.
     */
    private fun applyLaplacian(x: DoubleArray, win: Windows, out: DoubleArray, buffers: Array<DoubleArray>) {
        val chunks = buffers.size
        val per = (win.count + chunks - 1) / chunks
        java.util.stream.IntStream.range(0, chunks).parallel().forEach { chunk ->
            val acc = buffers[chunk]
            java.util.Arrays.fill(acc, 0.0)
            for (k in chunk * per until min(win.count, (chunk + 1) * per)) {
                val vb = k * 9
                val ob = k * 27
                var s = 0.0; var a0 = 0.0; var a1 = 0.0; var a2 = 0.0
                for (j in 0 until 9) {
                    val v = win.variable[vb + j]
                    if (v < 0) continue
                    val xj = x[v]
                    s += xj; a0 += win.offset[ob + j * 3] * xj; a1 += win.offset[ob + j * 3 + 1] * xj; a2 += win.offset[ob + j * 3 + 2] * xj
                }
                val o = k * 6
                val m = win.inverse
                val v0 = m[o] * a0 + m[o + 1] * a1 + m[o + 2] * a2
                val v1 = m[o + 1] * a0 + m[o + 3] * a1 + m[o + 4] * a2
                val v2 = m[o + 2] * a0 + m[o + 4] * a1 + m[o + 5] * a2
                for (j in 0 until 9) {
                    val v = win.variable[vb + j]
                    if (v < 0) continue
                    acc[v] += x[v] - (s + win.offset[ob + j * 3] * v0 + win.offset[ob + j * 3 + 1] * v1 + win.offset[ob + j * 3 + 2] * v2) / 9
                }
            }
        }
        java.util.Arrays.fill(out, 0.0)
        for (acc in buffers) for (i in out.indices) out[i] += acc[i]
    }

    /**
     * The full-frame alpha with the unknown pixels solved; null when there is nothing to solve. [start]: initial values
     * of the unknowns (the prior), or null for zeros.
     */
    internal fun solve(image: Array<FloatPlane>, trimap: DoubleArray, w: Int, h: Int, checkpoint: () -> Unit = {}, start: FloatPlane? = null,
                       tolerance: Double = COARSE_TOLERANCE): DoubleArray? {
        val variableOf = IntArray(w * h) { -1 }
        var n = 0
        for (p in 0 until w * h) if (trimap[p].isNaN()) variableOf[p] = n++
        lastUnknownPixels = n
        if (n == 0) return null
        val win = windows(image, variableOf, w, h)
        val chunks = max(1, Runtime.getRuntime().availableProcessors())
        val buffers = Array(chunks) { DoubleArray(n) }
        // Right-hand side b = −L_UK x_K: the known pixels' contribution to each unknown row, window by window.
        val b = DoubleArray(n)
        for (k in 0 until win.count) {
            val vb = k * 9; val ob = k * 27
            var s = 0.0; var a0 = 0.0; var a1 = 0.0; var a2 = 0.0
            for (j in 0 until 9) {
                if (win.variable[vb + j] >= 0) continue
                val xj = trimap[win.centre[k] + OFFSETS_Y[j] * w + OFFSETS_X[j]]
                if (xj == 0.0) continue
                s += xj; a0 += win.offset[ob + j * 3] * xj; a1 += win.offset[ob + j * 3 + 1] * xj; a2 += win.offset[ob + j * 3 + 2] * xj
            }
            if (s == 0.0 && a0 == 0.0 && a1 == 0.0 && a2 == 0.0) continue
            val o = k * 6; val m = win.inverse
            val v0 = m[o] * a0 + m[o + 1] * a1 + m[o + 2] * a2
            val v1 = m[o + 1] * a0 + m[o + 3] * a1 + m[o + 4] * a2
            val v2 = m[o + 2] * a0 + m[o + 4] * a1 + m[o + 5] * a2
            for (j in 0 until 9) {
                val v = win.variable[vb + j]
                if (v < 0) continue
                // L_ij for i ≠ j is −(1 + d_i·M d_j)/9; the known x_i term of L·x does not reach an unknown row.
                b[v] += (s + win.offset[ob + j * 3] * v0 + win.offset[ob + j * 3 + 1] * v1 + win.offset[ob + j * 3 + 2] * v2) / 9
            }
        }
        // Jacobi preconditioner: the diagonal of L_UU.
        val diagonal = DoubleArray(n)
        for (k in 0 until win.count) {
            val vb = k * 9; val ob = k * 27; val o = k * 6; val m = win.inverse
            for (j in 0 until 9) {
                val v = win.variable[vb + j]
                if (v < 0) continue
                val d0 = win.offset[ob + j * 3]; val d1 = win.offset[ob + j * 3 + 1]; val d2 = win.offset[ob + j * 3 + 2]
                val q = d0 * (m[o] * d0 + m[o + 1] * d1 + m[o + 2] * d2) + d1 * (m[o + 1] * d0 + m[o + 3] * d1 + m[o + 4] * d2) + d2 * (m[o + 2] * d0 + m[o + 4] * d1 + m[o + 5] * d2)
                diagonal[v] += 1 - (1 + q) / 9
            }
        }
        for (i in 0 until n) diagonal[i] = max(diagonal[i], 1e-12)
        // Preconditioned conjugate gradients, warm-started from the prior when given.
        val x = DoubleArray(n)
        if (start != null) for (p in 0 until w * h) { val v = variableOf[p]; if (v >= 0) x[v] = start.values[p].toDouble() }
        val ax = DoubleArray(n)
        applyLaplacian(x, win, ax, buffers)
        val r = DoubleArray(n) { b[it] - ax[it] }
        val z = DoubleArray(n) { r[it] / diagonal[it] }
        val p = z.copyOf()
        var rz = dot(r, z)
        val bNorm = sqrt(dot(b, b))
        val ap = DoubleArray(n)
        if (bNorm > 0) for (iteration in 0 until MAX_ITERATIONS) {
            if (iteration % 25 == 0) checkpoint()
            if (sqrt(dot(r, r)) <= tolerance * bNorm) break
            applyLaplacian(p, win, ap, buffers)
            val step = rz / dot(p, ap)
            for (i in 0 until n) { x[i] += step * p[i]; r[i] -= step * ap[i] }
            for (i in 0 until n) z[i] = r[i] / diagonal[i]
            val rzNext = dot(r, z)
            val beta = rzNext / rz
            for (i in 0 until n) p[i] = z[i] + beta * p[i]
            rz = rzNext
        }
        return DoubleArray(w * h) { pix -> val v = variableOf[pix]; if (v >= 0) x[v] else trimap[pix] }
    }

    private fun dot(a: DoubleArray, b: DoubleArray): Double { var s = 0.0; for (i in a.indices) s += a[i] * b[i]; return s }
}
