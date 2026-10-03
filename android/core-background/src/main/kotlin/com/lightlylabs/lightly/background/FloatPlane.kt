package com.lightlylabs.lightly.background

import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** A single-channel float image, row-major. */
class FloatPlane(val width: Int, val height: Int, val values: FloatArray = FloatArray(width * height)) {
    init {
        require(width > 0 && height > 0 && values.size == width * height) { "plane ${width}x$height has ${values.size} values" }
    }

    operator fun get(x: Int, y: Int): Float = values[y * width + x]
    operator fun set(x: Int, y: Int, value: Float) { values[y * width + x] = value }

    fun copy() = FloatPlane(width, height, values.copyOf())

    fun map(transform: (Float) -> Float) = FloatPlane(width, height, FloatArray(values.size) { transform(values[it]) })

    /** Bilinear sample with half-pixel centres and clamped edges (cv2.resize INTER_LINEAR geometry). */
    fun sample(x: Double, y: Double): Float {
        val sx = x.coerceIn(0.0, (width - 1).toDouble())
        val sy = y.coerceIn(0.0, (height - 1).toDouble())
        val x0 = floor(sx).toInt()
        val y0 = floor(sy).toInt()
        val x1 = min(x0 + 1, width - 1)
        val y1 = min(y0 + 1, height - 1)
        val fx = (sx - x0).toFloat()
        val fy = (sy - y0).toFloat()
        val top = this[x0, y0] * (1 - fx) + this[x1, y0] * fx
        val bottom = this[x0, y1] * (1 - fx) + this[x1, y1] * fx
        return top * (1 - fy) + bottom * fy
    }

    companion object {
        fun filled(width: Int, height: Int, value: Float) = FloatPlane(width, height, FloatArray(width * height) { value })
    }
}

/** Resampling, filtering and morphology on [FloatPlane]s (the building blocks of depth-evaluation.md §6). */
object PlaneOps {
    /** Bilinear resize, half-pixel centres (cv2 INTER_LINEAR). */
    fun resizeBilinear(source: FloatPlane, width: Int, height: Int): FloatPlane {
        val out = FloatPlane(width, height)
        val sx = source.width.toDouble() / width
        val sy = source.height.toDouble() / height
        for (y in 0 until height) {
            val srcY = (y + 0.5) * sy - 0.5
            for (x in 0 until width) out[x, y] = source.sample((x + 0.5) * sx - 0.5, srcY)
        }
        return out
    }

    /** Area (box) downsample by an integer [factor]; partial edge blocks average what they cover. */
    fun downsampleArea(source: FloatPlane, factor: Int): FloatPlane {
        if (factor <= 1) return source
        val w = (source.width + factor - 1) / factor
        val h = (source.height + factor - 1) / factor
        val out = FloatPlane(w, h)
        for (y in 0 until h) for (x in 0 until w) {
            var sum = 0.0
            var n = 0
            for (yy in y * factor until min(source.height, (y + 1) * factor)) for (xx in x * factor until min(source.width, (x + 1) * factor)) {
                sum += source[xx, yy]; n++
            }
            out[x, y] = (sum / n).toFloat()
        }
        return out
    }

    /** Mean over a (2r+1)² window with reflected borders (cv2.boxFilter, normalised, BORDER_REFLECT_101). */
    fun boxFilter(source: FloatPlane, radius: Int): FloatPlane {
        if (radius <= 0) return source.copy()
        val w = source.width
        val h = source.height
        val rows = FloatPlane(w, h)
        val size = 2 * radius + 1
        for (y in 0 until h) {
            var sum = 0.0
            for (k in -radius..radius) sum += source[reflect(k, w), y]
            rows[0, y] = (sum / size).toFloat()
            for (x in 1 until w) {
                sum += source[reflect(x + radius, w), y] - source[reflect(x - radius - 1, w), y]
                rows[x, y] = (sum / size).toFloat()
            }
        }
        val out = FloatPlane(w, h)
        for (x in 0 until w) {
            var sum = 0.0
            for (k in -radius..radius) sum += rows[x, reflect(k, h)]
            out[x, 0] = (sum / size).toFloat()
            for (y in 1 until h) {
                sum += rows[x, reflect(y + radius, h)] - rows[x, reflect(y - radius - 1, h)]
                out[x, y] = (sum / size).toFloat()
            }
        }
        return out
    }

    /** Separable Gaussian, truncated at 3σ, reflected borders. */
    fun gaussianBlur(source: FloatPlane, sigma: Double): FloatPlane {
        val radius = max(1, kotlin.math.ceil(3 * sigma).toInt())
        val kernel = DoubleArray(2 * radius + 1) { val t = (it - radius) / sigma; kotlin.math.exp(-0.5 * t * t) }
        val norm = kernel.sum()
        for (i in kernel.indices) kernel[i] /= norm
        val w = source.width
        val h = source.height
        val rows = FloatPlane(w, h)
        for (y in 0 until h) for (x in 0 until w) {
            var sum = 0.0
            for (k in kernel.indices) sum += kernel[k] * source[reflect(x + k - radius, w), y]
            rows[x, y] = sum.toFloat()
        }
        val out = FloatPlane(w, h)
        for (y in 0 until h) for (x in 0 until w) {
            var sum = 0.0
            for (k in kernel.indices) sum += kernel[k] * rows[x, reflect(y + k - radius, h)]
            out[x, y] = sum.toFloat()
        }
        return out
    }

    /** cv2 BORDER_REFLECT_101 (mirror without repeating the edge pixel). */
    fun reflect(index: Int, size: Int): Int {
        if (size == 1) return 0
        val period = 2 * (size - 1)
        var i = index % period
        if (i < 0) i += period
        return if (i < size) i else period - i
    }

    /**
     * Guided filter (He et al.) of [source] guided by [guide] (§R2.1: radius 0.006·longSide, ε = 1e-3),
     * clamped to [0, 1].
     */
    fun guidedFilter(guide: FloatPlane, source: FloatPlane, radius: Int, epsilon: Double): FloatPlane {
        val meanI = boxFilter(guide, radius)
        val meanP = boxFilter(source, radius)
        val ii = FloatPlane(guide.width, guide.height, FloatArray(guide.values.size) { guide.values[it] * guide.values[it] })
        val ip = FloatPlane(guide.width, guide.height, FloatArray(guide.values.size) { guide.values[it] * source.values[it] })
        val corrI = boxFilter(ii, radius)
        val corrIp = boxFilter(ip, radius)
        val a = FloatPlane(guide.width, guide.height)
        val b = FloatPlane(guide.width, guide.height)
        for (i in a.values.indices) {
            val varI = corrI.values[i] - meanI.values[i] * meanI.values[i]
            val covIp = corrIp.values[i] - meanI.values[i] * meanP.values[i]
            val ai = (covIp / (varI + epsilon)).toFloat()
            a.values[i] = ai
            b.values[i] = meanP.values[i] - ai * meanI.values[i]
        }
        val meanA = boxFilter(a, radius)
        val meanB = boxFilter(b, radius)
        return FloatPlane(guide.width, guide.height, FloatArray(a.values.size) { (meanA.values[it] * guide.values[it] + meanB.values[it]).coerceIn(0f, 1f) })
    }

    /** Linear-interpolated percentile (numpy default), q in [0, 100]. */
    fun percentile(values: FloatArray, q: Double): Double {
        val sorted = values.copyOf().also { it.sort() }
        val position = q / 100.0 * (sorted.size - 1)
        val lower = floor(position).toInt()
        val upper = min(lower + 1, sorted.size - 1)
        val fraction = position - lower
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    fun median(values: FloatArray): Double = percentile(values, 50.0)

    /**
     * Binary dilation of `mask > threshold` by a disc of [radius] px (cv2.dilate with an elliptical
     * structuring element), via an exact squared Euclidean distance transform.
     */
    fun dilateDisc(mask: FloatPlane, threshold: Float, radius: Int): BooleanArray {
        val inside = BooleanArray(mask.values.size) { mask.values[it] > threshold }
        if (radius <= 0) return inside
        val distance = squaredDistanceTo(inside, mask.width, mask.height)
        val r2 = radius.toDouble() * radius
        return BooleanArray(inside.size) { distance[it] <= r2 }
    }

    /** Binary erosion of `mask > threshold` by a disc of [radius] px. */
    fun erodeDisc(mask: FloatPlane, threshold: Float, radius: Int): BooleanArray {
        val inside = BooleanArray(mask.values.size) { mask.values[it] > threshold }
        if (radius <= 0) return inside
        val outside = BooleanArray(inside.size) { !inside[it] }
        val distance = squaredDistanceTo(outside, mask.width, mask.height)
        val r2 = radius.toDouble() * radius
        // A pixel survives when no outside pixel lies within the disc (image borders do not erode, as cv2).
        return BooleanArray(inside.size) { inside[it] && distance[it] > r2 }
    }

    /** Squared Euclidean distance from every pixel to the nearest `true` pixel (Felzenszwalb–Huttenlocher). */
    fun squaredDistanceTo(seeds: BooleanArray, width: Int, height: Int): DoubleArray {
        val infinity = 1e20
        val grid = DoubleArray(seeds.size) { if (seeds[it]) 0.0 else infinity }
        val column = DoubleArray(height)
        for (x in 0 until width) {
            for (y in 0 until height) column[y] = grid[y * width + x]
            val transformed = distance1d(column)
            for (y in 0 until height) grid[y * width + x] = transformed[y]
        }
        val row = DoubleArray(width)
        for (y in 0 until height) {
            System.arraycopy(grid, y * width, row, 0, width)
            val transformed = distance1d(row)
            System.arraycopy(transformed, 0, grid, y * width, width)
        }
        return grid
    }

    private fun distance1d(f: DoubleArray): DoubleArray {
        val n = f.size
        val d = DoubleArray(n)
        val v = IntArray(n)
        val z = DoubleArray(n + 1)
        var k = 0
        v[0] = 0
        z[0] = Double.NEGATIVE_INFINITY
        z[1] = Double.POSITIVE_INFINITY
        for (q in 1 until n) {
            var s = ((f[q] + q.toDouble() * q) - (f[v[k]] + v[k].toDouble() * v[k])) / (2.0 * q - 2.0 * v[k])
            while (s <= z[k]) { // z[0] is -inf, so this stops at k = 0
                k--
                s = ((f[q] + q.toDouble() * q) - (f[v[k]] + v[k].toDouble() * v[k])) / (2.0 * q - 2.0 * v[k])
            }
            k++
            v[k] = q
            z[k] = s
            z[k + 1] = Double.POSITIVE_INFINITY
        }
        k = 0
        for (q in 0 until n) {
            while (z[k + 1] < q) k++
            val dq = (q - v[k]).toDouble()
            d[q] = dq * dq + f[v[k]]
        }
        return d
    }

    fun sqrtSafe(value: Double) = sqrt(max(value, 0.0))
}
