package com.lightlylabs.lightly.editor.enhance

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.stream.IntStream
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cbrt
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.round
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Enhance (1.3): the pipeline's image maths, moved verbatim from the measured harness
 * (experiments/enhance-2026-11-12/phone/EnhancePipeline.kt, steps 2c-2g) and line for line with the Mac copy
 * (phone_pipeline.py). Float32, interleaved HWC, 0-255. Do not "tidy" the arithmetic: every loop computes each value
 * with the same float operations in the same order as the Mac copy, and phone/mathcheck/run.sh checks that bit for bit.
 * Faster loops are welcome only when they keep that property (README step 2d).
 */
internal object EnhanceMaths {
    class Image(val w: Int, val h: Int, val c: Int, val d: FloatArray = FloatArray(w * h * c))

    class Detection(val box: DoubleArray, val score: Double, val five: Array<DoubleArray>)

    fun floatBuffer(count: Int): ByteBuffer = ByteBuffer.allocateDirect(4 * count).order(ByteOrder.nativeOrder())

    fun ByteBuffer.floats(): FloatArray {
        rewind()
        return FloatArray(capacity() / 4).also { asFloatBuffer().get(it) }
    }

    /** PIL bilinear weights (antialiased when shrinking): per output pixel, the first tap and its weights. */
    class Taps(val first: IntArray, val weights: Array<FloatArray>)

    fun resampleTaps(inSize: Int, outSize: Int): Taps {
        val scale = inSize.toDouble() / outSize
        val filterScale = max(scale, 1.0)
        val first = IntArray(outSize)
        val weights = Array(outSize) { x ->
            val centre = (x + 0.5) * scale
            val lo = max((centre - filterScale + 0.5).toInt(), 0)
            val hi = min((centre + filterScale + 0.5).toInt(), inSize)
            first[x] = lo
            val w = DoubleArray(hi - lo) { i -> max(0.0, 1.0 - abs((lo + i - centre + 0.5) / filterScale)) }
            val sum = w.sum()
            FloatArray(w.size) { i -> if (sum > 0) (w[i] / sum).toFloat() else 0f }
        }
        return Taps(first, weights)
    }

    fun resize(image: Image, width: Int, height: Int): Image {
        val tx = resampleTaps(image.w, width)
        val ty = resampleTaps(image.h, height)
        val c = image.c
        val horizontal = Image(width, image.h, c)
        parallelFor(image.h) { y -> for (x in 0 until width) {
            val weights = tx.weights[x]
            for (ch in 0 until c) {
                var sum = 0f
                for (i in weights.indices) sum += weights[i] * image.d[(y * image.w + tx.first[x] + i) * c + ch]
                horizontal.d[(y * width + x) * c + ch] = sum
            }
        } }
        val out = Image(width, height, c)
        parallelFor(height) { y ->
            val weights = ty.weights[y]
            for (x in 0 until width) for (ch in 0 until c) {
                var sum = 0f
                for (i in weights.indices) sum += weights[i] * horizontal.d[((ty.first[y] + i) * width + x) * c + ch]
                out.d[(y * width + x) * c + ch] = sum
            }
        }
        return out
    }

    /** Output pixel (u, v) samples the source at m (2 x 3, row-major) applied to (u, v); outside taps take `border`. */
    fun warpBilinear(source: Image, m: DoubleArray, width: Int, height: Int, border: FloatArray): Image {
        val c = source.c
        val out = Image(width, height, c)
        val sw = source.w
        val sh = source.h
        val src = source.d
        parallelFor(height) { v -> for (u in 0 until width) {
            val x = m[0] * u + m[1] * v + m[2]
            val y = m[3] * u + m[4] * v + m[5]
            val x0 = floor(x).toInt()
            val y0 = floor(y).toInt()
            val fx = (x - x0).toFloat()
            val fy = (y - y0).toFloat()
            // -1 marks a tap outside the source (it takes the border value).
            val left = x0 in 0 until sw
            val right = x0 + 1 in 0 until sw
            val top = y0 in 0 until sh
            val bottom = y0 + 1 in 0 until sh
            val i00 = if (top && left) (y0 * sw + x0) * c else -1
            val i01 = if (top && right) (y0 * sw + x0 + 1) * c else -1
            val i10 = if (bottom && left) ((y0 + 1) * sw + x0) * c else -1
            val i11 = if (bottom && right) ((y0 + 1) * sw + x0 + 1) * c else -1
            val at = (v * width + u) * c
            for (ch in 0 until c) {
                val b = border[ch]
                val t = (if (i00 >= 0) src[i00 + ch] else b) * (1 - fx) + (if (i01 >= 0) src[i01 + ch] else b) * fx
                val d = (if (i10 >= 0) src[i10 + ch] else b) * (1 - fx) + (if (i11 >= 0) src[i11 + ch] else b) * fx
                out.d[at + ch] = t * (1 - fy) + d * fy
            }
        } }
        return out
    }

    fun gaussianKernel(size: Int, sigmaIn: Double): FloatArray {
        val fixed = mapOf(
            1 to floatArrayOf(1f), 3 to floatArrayOf(0.25f, 0.5f, 0.25f), 5 to floatArrayOf(0.0625f, 0.25f, 0.375f, 0.25f, 0.0625f),
            7 to floatArrayOf(0.03125f, 0.109375f, 0.21875f, 0.28125f, 0.21875f, 0.109375f, 0.03125f),
        )
        if (sigmaIn <= 0 && size in fixed) return fixed.getValue(size)
        val sigma = if (sigmaIn <= 0) 0.3 * ((size - 1) * 0.5 - 1) + 0.8 else sigmaIn
        val k = DoubleArray(size) { val x = it - (size - 1) / 2.0; exp(-(x * x) / (2 * sigma * sigma)) }
        val sum = k.sum()
        return FloatArray(size) { (k[it] / sum).toFloat() }
    }

    fun reflect101(index: Int, size: Int): Int {
        if (size == 1) return 0
        val period = 2 * size - 2
        val i = Math.floorMod(index, period)
        return if (i < size) i else period - i
    }

    fun reflect(index: Int, size: Int): Int {
        val period = 2 * size
        val i = Math.floorMod(index, period)
        return if (i < size) i else period - 1 - i
    }

    // Step 2d speed-ups. Every loop below gives bit-identical results to the step 2c loops: each output value is computed
    // with the same float operations in the same order, only on all cores and with exact shortcuts (see each function).

    /** body(index) for every index on all cores; callers only write disjoint outputs, so the order does not matter. */
    fun parallelFor(count: Int, body: (Int) -> Unit) {
        IntStream.range(0, count).parallel().forEach { body(it) }
    }

    /** w x h plane -> h x w plane, in 32 x 32 blocks for the cache. */
    fun transpose(plane: FloatArray, w: Int, h: Int): FloatArray {
        val out = FloatArray(w * h)
        val block = 32
        parallelFor((h + block - 1) / block) { by ->
            val y0 = by * block
            val y1 = min(y0 + block, h)
            var x0 = 0
            while (x0 < w) {
                val x1 = min(x0 + block, w)
                for (y in y0 until y1) for (x in x0 until x1) out[x * h + y] = plane[y * w + x]
                x0 = x1
            }
        }
        return out
    }

    /**
     * One axis of separableSum: out[y, x] = sum of weights[i] * plane[y, border(x + i - offset)], accumulated from 0f in
     * tap order (step 2c's loop). Shortcut: when all taps of an inside window hold one value c, the terms are all
     * weights[i] * c, so the same accumulation is done once per row and value and reused - the masks are mostly flat 0
     * and 1 areas. Equal floats are the same value (0f and -0f both give +0f sums), so the result does not change.
     */
    fun weightedRows(plane: FloatArray, w: Int, h: Int, weights: FloatArray, offset: Int, border: (Int, Int) -> Int): FloatArray {
        val taps = weights.size
        val columns = IntArray(w * taps) { border(it / taps + it % taps - offset, w) }
        val out = FloatArray(w * h)
        parallelFor(h) { y ->
            val row = y * w
            val runEnd = IntArray(w)                    // last index of the run of equal values that starts at x
            runEnd[w - 1] = w - 1
            for (x in w - 2 downTo 0) runEnd[x] = if (plane[row + x + 1] == plane[row + x]) runEnd[x + 1] else x
            var flatValue = Float.NaN                   // NaN equals nothing, so the first flat window computes its sum
            var flatSum = 0f
            for (x in 0 until w) {
                val first = x - offset
                if (first >= 0 && first + taps <= w && runEnd[first] >= first + taps - 1) {
                    val value = plane[row + first]
                    if (value != flatValue) {
                        var acc = 0f
                        for (i in 0 until taps) acc += weights[i] * value
                        flatValue = value
                        flatSum = acc
                    }
                    out[row + x] = flatSum
                } else {
                    var acc = 0f
                    val base = x * taps
                    for (i in 0 until taps) acc += weights[i] * plane[row + columns[base + i]]
                    out[row + x] = acc
                }
            }
        }
        return out
    }

    /** Separable weighted sum along x then y; the y pass runs as an x pass on the transposed plane (same sums). */
    fun separableSum(plane: FloatArray, w: Int, h: Int, weights: FloatArray, offset: Int, border: (Int, Int) -> Int): FloatArray {
        val horizontal = weightedRows(plane, w, h, weights, offset, border)
        val vertical = weightedRows(transpose(horizontal, w, h), h, w, weights, offset, border)
        return transpose(vertical, h, w)
    }

    fun gaussianBlur(plane: FloatArray, w: Int, h: Int, size: Int, sigma: Double): FloatArray =
        separableSum(plane, w, h, gaussianKernel(size, sigma), size / 2, ::reflect101)

    /**
     * Per row, the minimum over [x - anchor, x - anchor + size - 1] with positions outside the row ignored. van Herk /
     * Gil-Werman: block-wise prefix and suffix minima, three comparisons per pixel whatever the size (step 2c looped over
     * the whole window). A minimum does not depend on the order it is taken in, so the result is the same.
     */
    fun minRows(plane: FloatArray, w: Int, h: Int, size: Int): FloatArray {
        val anchor = size / 2
        val n = w + size - 1                            // padded row: index j holds x = j - anchor, +inf outside
        val out = FloatArray(w * h)
        parallelFor(h) { y ->
            val row = y * w
            val prefix = FloatArray(n)
            val suffix = FloatArray(n)
            for (j in 0 until n) {
                val x = j - anchor
                val value = if (x in 0 until w) plane[row + x] else Float.POSITIVE_INFINITY
                prefix[j] = if (j % size == 0) value else min(prefix[j - 1], value)
                suffix[j] = value
            }
            for (j in n - 2 downTo 0) if (j % size != size - 1) suffix[j] = min(suffix[j + 1], suffix[j])
            for (x in 0 until w) out[row + x] = min(suffix[x], prefix[x + size - 1])
        }
        return out
    }

    /** OpenCV erode, size x size rectangle, anchor size / 2; outside the plane counts as the maximum. */
    fun erode(plane: FloatArray, w: Int, h: Int, size: Int): FloatArray {
        if (size <= 1) return plane.copyOf()
        val horizontal = minRows(plane, w, h, size)
        return transpose(minRows(transpose(horizontal, w, h), h, w, size), h, w)
    }

    fun boxMeanReflect(plane: FloatArray, w: Int, h: Int, radius: Int): FloatArray {
        val n = 2 * radius + 1
        return separableSum(plane, w, h, FloatArray(n) { 1f / n }, radius, ::reflect)
    }

    val SRGB_TO_XYZ = doubleArrayOf(0.412453, 0.357580, 0.180423, 0.212671, 0.715160, 0.072169, 0.019334, 0.119193, 0.950227)
    val XYZ_TO_SRGB = invert3(SRGB_TO_XYZ)
    val WHITE = doubleArrayOf(0.950456, 1.0, 1.088754)

    fun invert3(m: DoubleArray): DoubleArray {
        val (a, b, c, d, e) = m
        val f = m[5]; val g = m[6]; val h = m[7]; val i = m[8]
        val det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return doubleArrayOf(
            (e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
            (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
            (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det,
        )
    }

    fun rgbToLab(r: Float, g: Float, b: Float, out: FloatArray, at: Int) {
        fun linear(v: Float) = if (v <= 0.04045f) v / 12.92 else ((v + 0.055) / 1.055).pow(2.4)
        val lr = linear(r); val lg = linear(g); val lb = linear(b)
        val x = (SRGB_TO_XYZ[0] * lr + SRGB_TO_XYZ[1] * lg + SRGB_TO_XYZ[2] * lb) / WHITE[0]
        val y = (SRGB_TO_XYZ[3] * lr + SRGB_TO_XYZ[4] * lg + SRGB_TO_XYZ[5] * lb) / WHITE[1]
        val z = (SRGB_TO_XYZ[6] * lr + SRGB_TO_XYZ[7] * lg + SRGB_TO_XYZ[8] * lb) / WHITE[2]
        fun f(t: Double) = if (t > 0.008856) cbrt(t) else 7.787 * t + 16.0 / 116
        out[at] = (if (y > 0.008856) 116 * f(y) - 16 else 903.3 * y).toFloat()
        out[at + 1] = (500 * (f(x) - f(y))).toFloat()
        out[at + 2] = (200 * (f(y) - f(z))).toFloat()
    }

    fun labToRgb(l: Float, a: Float, b: Float, out: FloatArray, at: Int) {
        val fy = if (l > 8.0) (l + 16.0) / 116 else l / 903.3 * 7.787 + 16.0 / 116
        val y = if (l > 8.0) fy * fy * fy else l / 903.3
        fun inverse(f: Double) = if (f > 0.206893) f * f * f else (f - 16.0 / 116) / 7.787
        val x = inverse(fy + a / 500.0) * WHITE[0]
        val z = inverse(fy - b / 200.0) * WHITE[2]
        val yy = y * WHITE[1]
        for (ch in 0 until 3) {
            val linear = (XYZ_TO_SRGB[ch * 3] * x + XYZ_TO_SRGB[ch * 3 + 1] * yy + XYZ_TO_SRGB[ch * 3 + 2] * z).coerceIn(0.0, 1.0)
            out[at + ch] = (if (linear <= 0.0031308) 12.92 * linear else 1.055 * linear.pow(1 / 2.4) - 0.055).toFloat()
        }
    }

    /** colour_from_original.py: the restored face's lightness, the original crop's colour through a guided filter. */
    fun originalColour(restored: Image, original: Image, radius: Int = 8, epsilon: Float = 1e-3f): Image {
        val n = restored.w * restored.h
        val w = restored.w
        val h = restored.h
        val restoredLab = FloatArray(n * 3)
        val originalLab = FloatArray(n * 3)
        parallelFor(n) { i ->
            rgbToLab(restored.d[i * 3].coerceIn(0f, 255f) / 255f, restored.d[i * 3 + 1].coerceIn(0f, 255f) / 255f,
                restored.d[i * 3 + 2].coerceIn(0f, 255f) / 255f, restoredLab, i * 3)
            rgbToLab(original.d[i * 3].coerceIn(0f, 255f) / 255f, original.d[i * 3 + 1].coerceIn(0f, 255f) / 255f,
                original.d[i * 3 + 2].coerceIn(0f, 255f) / 255f, originalLab, i * 3)
        }
        val guide = FloatArray(n) { restoredLab[it * 3] / 100f }
        val meanGuide = boxMeanReflect(guide, w, h, radius)
        val guideSquared = boxMeanReflect(FloatArray(n) { guide[it] * guide[it] }, w, h, radius)
        val variance = FloatArray(n) { guideSquared[it] - meanGuide[it] * meanGuide[it] }
        val channels = Array(2) { index ->
            val source = FloatArray(n) { originalLab[it * 3 + 1 + index] }
            val meanSource = boxMeanReflect(source, w, h, radius)
            val product = boxMeanReflect(FloatArray(n) { guide[it] * source[it] }, w, h, radius)
            val slope = FloatArray(n) { (product[it] - meanGuide[it] * meanSource[it]) / (variance[it] + epsilon) }
            val offset = FloatArray(n) { meanSource[it] - slope[it] * meanGuide[it] }
            val meanSlope = boxMeanReflect(slope, w, h, radius)
            val meanOffset = boxMeanReflect(offset, w, h, radius)
            FloatArray(n) { meanSlope[it] * guide[it] + meanOffset[it] }
        }
        val out = Image(w, h, 3)
        parallelFor(n) { i ->
            labToRgb(restoredLab[i * 3], channels[0][i], channels[1][i], out.d, i * 3)
            for (ch in 0 until 3) out.d[i * 3 + ch] = out.d[i * 3 + ch].coerceIn(0f, 1f) * 255f
        }
        return out
    }

    /** CodeFormer's is_gray(threshold 10) on the 8-bit photo. */
    fun isGrey(rgb: Image): Boolean {
        val n = rgb.w * rgb.h
        fun variance(a: Int, b: Int): Double {
            var sum = 0.0; var sumSquares = 0.0
            for (i in 0 until n) { val d = (rgb.d[i * 3 + a] - rgb.d[i * 3 + b]).toDouble(); sum += d; sumSquares += d * d }
            val mean = sum / n
            return sumSquares / n - mean * mean
        }
        return (variance(0, 1) + variance(1, 2) + variance(2, 0)) / 3 <= 10
    }

    /** CodeFormer's bgr2gray + adain_npy for grey photos. */
    fun greyLike(restored: Image, crop: Image): Image {
        val n = restored.w * restored.h
        val grey = DoubleArray(n) { 0.2989 * restored.d[it * 3] + 0.5870 * restored.d[it * 3 + 1] + 0.1140 * restored.d[it * 3 + 2] }
        val greyMean = grey.average()
        val greyStd = sqrt(grey.sumOf { (it - greyMean) * (it - greyMean) } / n + 1e-5)
        val out = Image(restored.w, restored.h, 3)
        for (ch in 0 until 3) {
            var sum = 0.0
            for (i in 0 until n) sum += crop.d[i * 3 + ch]
            val mean = sum / n
            var squares = 0.0
            for (i in 0 until n) { val d = crop.d[i * 3 + ch] - mean; squares += d * d }
            val std = sqrt(squares / n + 1e-5)
            for (i in 0 until n) out.d[i * 3 + ch] = ((grey[i] - greyMean) / greyStd * std + mean).toFloat()
        }
        return out
    }

    /** Pixels not reachable from outside through non-face pixels (4-connected) become face. */
    fun fillHoles(face: BooleanArray, w: Int, h: Int): BooleanArray {
        val outside = BooleanArray(w * h)
        val stack = ArrayDeque<Int>()
        fun visit(i: Int) { if (!face[i] && !outside[i]) { outside[i] = true; stack.addLast(i) } }
        for (x in 0 until w) { visit(x); visit((h - 1) * w + x) }
        for (y in 0 until h) { visit(y * w); visit(y * w + w - 1) }
        while (stack.isNotEmpty()) {
            val i = stack.removeLast()
            val x = i % w
            val y = i / w
            if (y > 0) visit(i - w)
            if (y < h - 1) visit(i + w)
            if (x > 0) visit(i - 1)
            if (x < w - 1) visit(i + 1)
        }
        return BooleanArray(w * h) { !outside[it] }
    }

    /** Least-squares similarity x' = a x - b y + tx, y' = b x + a y + ty (photo -> face), row-major 2 x 3. */
    fun similarity(points: Array<DoubleArray>, template: Array<DoubleArray>): DoubleArray {
        // Normal equations of the 10 x 4 system; columns (a, b, tx, ty).
        val ata = Array(4) { DoubleArray(4) }
        val atb = DoubleArray(4)
        for (k in points.indices) {
            val x = points[k][0]; val y = points[k][1]
            val rows = arrayOf(doubleArrayOf(x, -y, 1.0, 0.0), doubleArrayOf(y, x, 0.0, 1.0))
            val values = doubleArrayOf(template[k][0], template[k][1])
            for (r in 0 until 2) for (i in 0 until 4) {
                atb[i] += rows[r][i] * values[r]
                for (j in 0 until 4) ata[i][j] += rows[r][i] * rows[r][j]
            }
        }
        val solution = solve4(ata, atb)
        val (a, b, tx, ty) = solution
        return doubleArrayOf(a, -b, tx, b, a, ty)
    }

    fun solve4(m: Array<DoubleArray>, v: DoubleArray): DoubleArray {
        val a = Array(4) { r -> DoubleArray(5) { c -> if (c < 4) m[r][c] else v[r] } }
        for (col in 0 until 4) {
            val pivot = (col until 4).maxBy { abs(a[it][col]) }
            val tmp = a[col]; a[col] = a[pivot]; a[pivot] = tmp
            for (r in 0 until 4) if (r != col) {
                val f = a[r][col] / a[col][col]
                for (c in col until 5) a[r][c] -= f * a[col][c]
            }
        }
        return DoubleArray(4) { a[it][4] / a[it][it] }
    }

    fun invertAffine(m: DoubleArray): DoubleArray {
        val det = m[0] * m[4] - m[1] * m[3]
        val a = m[4] / det; val b = -m[1] / det; val d = -m[3] / det; val e = m[0] / det
        return doubleArrayOf(a, b, -(a * m[2] + b * m[5]), d, e, -(d * m[2] + e * m[5]))
    }

    fun iou(a: DoubleArray, b: DoubleArray): Double {
        val ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
        val iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
        val inter = ix * iy
        val union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
        return if (union > 0) inter / union else 0.0
    }

    /** RetinaFace PriorBox for a square canvas, canvas pixels: centre x, centre y, w, h per prior. */
    fun priors(canvas: Int): FloatArray {
        val out = ArrayList<Float>()
        for ((step, sizes) in listOf(8 to intArrayOf(16, 32), 16 to intArrayOf(64, 128), 32 to intArrayOf(256, 512))) {
            val cells = ceil(canvas.toDouble() / step).toInt()
            for (i in 0 until cells) for (j in 0 until cells) for (size in sizes) {
                out += (j + 0.5f) * step; out += (i + 0.5f) * step; out += size.toFloat(); out += size.toFloat()
            }
        }
        return out.toFloatArray()
    }

    fun decodeDetections(loc: FloatArray, score: FloatArray, landmarks: FloatArray, prior: FloatArray, scale: Double): List<Detection> {
        val candidates = score.indices.filter { score[it] > 0.8f }
        val boxes = candidates.map { i ->
            val px = prior[i * 4].toDouble(); val py = prior[i * 4 + 1].toDouble(); val pw = prior[i * 4 + 2].toDouble(); val ph = prior[i * 4 + 3].toDouble()
            val cx = px + loc[i * 4] * 0.1 * pw
            val cy = py + loc[i * 4 + 1] * 0.1 * ph
            val w = pw * exp(loc[i * 4 + 2] * 0.2)
            val h = ph * exp(loc[i * 4 + 3] * 0.2)
            doubleArrayOf((cx - w / 2) / scale, (cy - h / 2) / scale, (cx + w / 2) / scale, (cy + h / 2) / scale)
        }
        // Stable sort by score, highest first, then greedy NMS (torchvision.ops.nms).
        val order = candidates.indices.sortedByDescending { score[candidates[it]] }.toMutableList()
        val found = mutableListOf<Detection>()
        while (order.isNotEmpty()) {
            val best = order.removeAt(0)
            order.removeAll { iou(boxes[best], boxes[it]) > 0.4 }
            val i = candidates[best]
            val five = Array(5) { k ->
                doubleArrayOf((prior[i * 4] + landmarks[i * 10 + k * 2] * 0.1 * prior[i * 4 + 2]) / scale,
                    (prior[i * 4 + 1] + landmarks[i * 10 + k * 2 + 1] * 0.1 * prior[i * 4 + 3]) / scale)
            }
            val gap = Math.hypot(five[0][0] - five[1][0], five[0][1] - five[1][1])
            if (gap >= 5.0) found += Detection(boxes[best], score[i].toDouble(), five)
        }
        return found
    }

    /**
     * phone_pipeline.tile_windows: per axis (kept start, kept length, window start). The fewest `tile` px windows that
     * overlap by at least 2 x pad, spread evenly; each overlap is split at its middle. A side no longer than a
     * tile is one window whose reads past the photo are mirrored in (mirrorIndex).
     */
    fun tileWindows(size: Int, tile: Int, pad: Int): List<Triple<Int, Int, Int>> {
        // A side no longer than a tile is one window from 0; its reads past the photo are mirrored in (mirrorIndex).
        if (size <= tile) return listOf(Triple(0, size, 0))
        val n = Math.floorDiv(size - tile + (tile - 2 * pad) - 1, tile - 2 * pad) + 1
        val starts = IntArray(n) { Math.rint(it.toDouble() * (size - tile) / (n - 1)).toInt() }   // Python round: halves to even
        val cuts = IntArray(n + 1) { if (it == 0) 0 else if (it == n) size else (starts[it - 1] + tile + starts[it]) / 2 }
        return List(n) { Triple(cuts[it], cuts[it + 1] - cuts[it], starts[it]) }
    }

    /** phone_pipeline.detection_scale: short side to `short`, unless the long side would pass the canvas (over 1.6 : 1). */
    /** phone_pipeline.input_size: unchanged up to [cap] on the long side, else shrunk to it (half-up rounding). */
    fun inputSize(w: Int, h: Int, cap: Int): Pair<Int, Int> {
        val long = max(w, h)
        if (long <= cap) return w to h
        fun shrink(side: Int) = max(1, (side.toDouble() * cap / long + 0.5).toInt())
        return shrink(w) to shrink(h)
    }

    fun detectionScale(w: Int, h: Int, short: Int, canvas: Int): Double {
        val scale = short.toDouble() / min(w, h)
        return if ((max(w, h) * scale).toInt() <= canvas) scale else canvas.toDouble() / max(w, h)
    }

    /** phone_pipeline.mirror_index: reflect without repeating the edge pixel, as often as needed; identity inside. */
    fun mirrorIndex(i: Int, size: Int): Int {
        if (size == 1) return 0
        val period = 2 * (size - 1)
        val j = i % period
        return if (j >= size) period - j else j
    }

    /** export_art_classifier.five_views_uint8 geometry with this file's resize, rounded to uint8. */
    fun fiveViews(rgb: Image): List<Image> {
        val whole = resize(rgb, 224, 224)
        val (lw, lh) = if (rgb.w <= rgb.h) 448 to (448.0 * rgb.h / rgb.w).toInt() else (448.0 * rgb.w / rgb.h).toInt() to 448
        val large = resize(rgb, lw, lh)
        fun pyRound(v: Double) = Math.rint(v).toInt()   // Python's round(): halves to even
        val corners = listOf(
            (lw - 224) / 2 to (lh - 224) / 2, (lw - 224) / 2 to pyRound(lh * 0.15),
            max(0, pyRound(lw * 0.2)) to (lh - 224) / 2, max(0, pyRound(lw * 0.8) - 224) to (lh - 224) / 2,
        )
        val views = listOf(whole) + corners.map { (x0, y0) ->
            Image(224, 224, 3).also { view ->
                for (y in 0 until 224) for (x in 0 until 224) for (c in 0 until 3) view.d[(y * 224 + x) * 3 + c] = large.d[((y0 + y) * lw + x0 + x) * 3 + c]
            }
        }
        views.forEach { view -> for (i in view.d.indices) view.d[i] = Math.rint(view.d[i].toDouble()).toFloat().coerceIn(0f, 255f) }
        return views
    }

    /** Blend one restored face into the 2x image in place; toFace is the photo -> face similarity. */
    fun pasteFace(image: Image, restored: Image, faceMask: FloatArray, toFace: DoubleArray) {
        val scale = 2.0
        val inverse = invertAffine(toFace).map { it * scale }.toDoubleArray()
        inverse[2] += 0.5 * scale; inverse[5] += 0.5 * scale             // CodeFormer's back-alignment offset
        val outputToFace = invertAffine(inverse)
        val xs = listOf(0.0, 512.0, 0.0, 512.0).zip(listOf(0.0, 0.0, 512.0, 512.0)).map { (u, v) -> inverse[0] * u + inverse[1] * v + inverse[2] }
        val ys = listOf(0.0, 512.0, 0.0, 512.0).zip(listOf(0.0, 0.0, 512.0, 512.0)).map { (u, v) -> inverse[3] * u + inverse[4] * v + inverse[5] }
        val x0 = max(floor(xs.min()).toInt() - 2, 0)
        val y0 = max(floor(ys.min()).toInt() - 2, 0)
        val x1 = min(ceil(xs.max()).toInt() + 3, image.w)
        val y1 = min(ceil(ys.max()).toInt() + 3, image.h)
        if (x1 <= x0 || y1 <= y0) return
        val shift = outputToFace.copyOf()
        shift[2] += shift[0] * x0 + shift[1] * y0
        shift[5] += shift[3] * x0 + shift[4] * y0
        val rw = x1 - x0
        val rh = y1 - y0
        val ones = Image(512, 512, 1).also { it.d.fill(1f) }
        var square = warpBilinear(ones, shift, rw, rh, floatArrayOf(0f)).d
        square = erode(square, rw, rh, 4)
        val edge = sqrt(square.fold(0.0) { acc, v -> acc + v }).toInt() / 20
        val softSquare = gaussianBlur(erode(square, rw, rh, edge * 2), rw, rh, edge * 2 + 1, 0.0)
        val parse = warpBilinear(Image(512, 512, 1, faceMask), shift, rw, rh, floatArrayOf(0f)).d
        val pasted = warpBilinear(restored, shift, rw, rh, floatArrayOf(0f, 0f, 0f))
        parallelFor(rh) { v -> for (u in 0 until rw) {
            val i = v * rw + u
            val soft = min(parse[i], softSquare[i])
            for (c in 0 until 3) {
                val at = ((y0 + v) * image.w + x0 + u) * 3 + c
                image.d[at] = soft * (pasted.d[i * 3 + c] * square[i]) + (1 - soft) * image.d[at]
            }
        } }
    }
}
