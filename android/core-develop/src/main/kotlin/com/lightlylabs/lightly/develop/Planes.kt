package com.lightlylabs.lightly.develop

import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/**
 * Float planes and the separable Gaussian of rendering-v2.md §5 (`G_σ`, reflect padding,
 * radius `min(max(3, ceil(3σ)), floor(longEdge/2) − 1)`, σ floored at 0.3 px).
 *
 * The planes are float32 to keep a full-resolution tile within the export budget; every sum is
 * accumulated in float64 so blurring does not lose the precision the reference keeps.
 */
object Planes {
    /** numpy `mode="reflect"` index: mirrors about the edge pixels without repeating them (d c b | a b c d | c b a). */
    fun reflect(index: Int, size: Int): Int {
        if (size == 1) return 0
        val period = 2 * (size - 1)
        var i = index % period
        if (i < 0) i += period
        return if (i < size) i else period - i
    }

    /** The truncated kernel radius the contract specifies; [capLongEdge] is the long edge of the WHOLE image. */
    fun radius(sigma: Double, capLongEdge: Int): Int = min(max(3, ceil(3 * sigma).toInt()), capLongEdge / 2 - 1).coerceAtLeast(1)

    fun kernel(sigmaPx: Double, capLongEdge: Int): DoubleArray {
        val sigma = max(sigmaPx, 0.3)
        val radius = radius(sigma, capLongEdge)
        val taps = DoubleArray(2 * radius + 1) { val t = (it - radius) / sigma; exp(-0.5 * t * t) }
        val sum = taps.sum()
        for (i in taps.indices) taps[i] /= sum
        return taps
    }

    /**
     * Separable Gaussian of [src] (width × height, row-major) into [dst]. Reflect padding happens at
     * the plane's bounds: in a tile, the caller's apron makes those bounds lie outside the tile
     * proper, and at the real image edges the plane bounds ARE the image bounds, as in the reference.
     */
    fun gaussianBlur(src: FloatArray, width: Int, height: Int, sigmaPx: Double, capLongEdge: Int, dst: FloatArray = FloatArray(src.size)): FloatArray {
        val kernel = kernel(sigmaPx, capLongEdge)
        val radius = kernel.size / 2
        val rows = FloatArray(src.size)
        for (y in 0 until height) {
            val row = y * width
            for (x in 0 until width) {
                var sum = 0.0
                for (k in kernel.indices) sum += kernel[k] * src[row + reflect(x + k - radius, width)]
                rows[row + x] = sum.toFloat()
            }
        }
        for (y in 0 until height) for (x in 0 until width) {
            var sum = 0.0
            for (k in kernel.indices) sum += kernel[k] * rows[reflect(y + k - radius, height) * width + x]
            dst[y * width + x] = sum.toFloat()
        }
        return dst
    }

    /**
     * A large Gaussian approximated at low resolution (rendering-v2.md §5 allows approximating large
     * Gaussians): box-average by [factor], blur with the remaining σ, then bilinear upsampling with
     * half-pixel centres on demand ([LowResPlane.sample]). The box and the bilinear reconstruction
     * each add about factor²/12 of variance per axis, which the low-resolution σ subtracts.
     */
    fun lowResGaussian(src: FloatArray, width: Int, height: Int, sigmaPx: Double, capLongEdge: Int, factor: Int): LowResPlane {
        val lowW = max(1, ceilDiv(width, factor))
        val lowH = max(1, ceilDiv(height, factor))
        val low = FloatArray(lowW * lowH)
        for (ly in 0 until lowH) for (lx in 0 until lowW) {
            var sum = 0.0
            var count = 0
            for (y in ly * factor until min(height, (ly + 1) * factor)) for (x in lx * factor until min(width, (lx + 1) * factor)) {
                sum += src[y * width + x]; count++
            }
            low[ly * lowW + lx] = (sum / count).toFloat()
        }
        val sigmaLow = lowResSigma(sigmaPx, factor)
        val blurred = gaussianBlur(low, lowW, lowH, sigmaLow, max(lowW, lowH))
        return LowResPlane(blurred, lowW, lowH, factor.toDouble())
    }

    fun lowResSigma(sigmaPx: Double, factor: Int): Double {
        val variance = sigmaPx * sigmaPx - 2.0 * factor * factor / 12.0
        return kotlin.math.sqrt(max(variance, 0.09 * factor * factor)) / factor
    }

    /** Down-sampling factor that leaves at least ~4 px of σ at low resolution (1 = blur exactly). */
    fun lowResFactor(sigmaPx: Double): Int = max(1, floor(sigmaPx / 4.0).toInt())

    private fun ceilDiv(a: Int, b: Int) = (a + b - 1) / b
}

/** A blurred plane stored at 1/[factor] resolution of a full image, sampled at full-resolution pixels. */
class LowResPlane(private val values: FloatArray, val width: Int, val height: Int, private val factor: Double) {
    /**
     * The same plane for an image [scale] times larger than the one it was computed from (a base computed
     * on a downscaled copy, used for a full-resolution frame).
     */
    fun rescaled(scale: Double): LowResPlane = LowResPlane(values, width, height, factor * scale)

    /** Bilinear sample at full-resolution pixel (x, y), pixel centres at half-integers. */
    fun sample(x: Int, y: Int): Double {
        val sx = ((x + 0.5) / factor - 0.5).coerceIn(0.0, (width - 1).toDouble())
        val sy = ((y + 0.5) / factor - 0.5).coerceIn(0.0, (height - 1).toDouble())
        val x0 = sx.toInt()
        val y0 = sy.toInt()
        val x1 = min(x0 + 1, width - 1)
        val y1 = min(y0 + 1, height - 1)
        val fx = sx - x0
        val fy = sy - y0
        val top = values[y0 * width + x0] * (1 - fx) + values[y0 * width + x1] * fx
        val bottom = values[y1 * width + x0] * (1 - fx) + values[y1 * width + x1] * fx
        return top * (1 - fy) + bottom * fy
    }
}
