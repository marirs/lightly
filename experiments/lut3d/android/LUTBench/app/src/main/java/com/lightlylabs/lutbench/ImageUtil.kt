package com.lightlylabs.lutbench

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ColorSpace
import android.graphics.ImageDecoder
import android.os.Build
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

const val LUT_DIM = 33
const val LUT_FLOATS = LUT_DIM * LUT_DIM * LUT_DIM * 4

/** Wall-clock helpers. All timing uses System.nanoTime (monotonic). */
inline fun <T> timedMs(block: () -> T): Pair<T, Double> {
    val start = System.nanoTime()
    val value = block()
    return value to (System.nanoTime() - start) / 1e6
}

fun median(values: List<Double>): Double {
    if (values.isEmpty()) return Double.NaN
    val sorted = values.sorted()
    val mid = sorted.size / 2
    return if (sorted.size % 2 == 1) sorted[mid] else (sorted[mid - 1] + sorted[mid]) / 2.0
}

fun readFloatFile(file: File): FloatArray {
    val bytes = file.readBytes()
    val floats = FloatArray(bytes.size / 4)
    ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(floats)
    return floats
}

/**
 * Decodes to a software ARGB_8888 bitmap in sRGB. The golden PNGs are already 8-bit sRGB, so
 * requesting SRGB is a no-op conversion for them; it matters for camera JPEGs with Display P3.
 */
fun decodeSrgb(file: File): Bitmap {
    val srgb = ColorSpace.get(ColorSpace.Named.SRGB)
    val decoded = if (Build.VERSION.SDK_INT >= 28) {
        ImageDecoder.decodeBitmap(ImageDecoder.createSource(file)) { decoder, _, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            decoder.setTargetColorSpace(srgb)
        }
    } else {
        val options = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inPreferredColorSpace = srgb
        }
        BitmapFactory.decodeFile(file.absolutePath, options)
            ?: throw IllegalStateException("BitmapFactory returned null for $file")
    }
    if (decoded.config == Bitmap.Config.ARGB_8888) return decoded
    val converted = decoded.copy(Bitmap.Config.ARGB_8888, false)
    decoded.recycle()
    return converted
}

/** ARGB_8888 copyPixelsToBuffer writes bytes in R,G,B,A order. */
fun bitmapToRgba(bitmap: Bitmap): ByteArray {
    val rgba = ByteArray(bitmap.width * bitmap.height * 4)
    bitmap.copyPixelsToBuffer(ByteBuffer.wrap(rgba))
    return rgba
}

fun rgbaToBitmap(rgba: ByteArray, width: Int, height: Int): Bitmap {
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
    return bitmap
}

fun savePng(bitmap: Bitmap, file: File) {
    FileOutputStream(file).use { stream -> bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream) }
}

/** Plain bilinear-free conversion of a 256x256 RGBA buffer into NCHW float [0,1]. */
fun rgbaToChw(rgba: ByteArray, width: Int, height: Int): FloatArray {
    val planeSize = width * height
    val chw = FloatArray(3 * planeSize)
    for (pixel in 0 until planeSize) {
        chw[pixel] = (rgba[pixel * 4].toInt() and 0xff) / 255f
        chw[planeSize + pixel] = (rgba[pixel * 4 + 1].toInt() and 0xff) / 255f
        chw[2 * planeSize + pixel] = (rgba[pixel * 4 + 2].toInt() and 0xff) / 255f
    }
    return chw
}

/**
 * Antialiased bilinear (triangle filter whose support widens with the downscale factor) resize
 * of the whole frame to outSize x outSize, ignoring aspect ratio. This is a port of the
 * coefficient computation used by torch `F.interpolate(mode="bilinear", antialias=True,
 * align_corners=False)` (itself derived from Pillow's ImagingResample), which is what
 * make_golden.py uses to produce input256.f32. Separable: horizontal pass, then vertical.
 */
object AntialiasedResize {
    private class AxisCoefficients(val firstTap: IntArray, val tapCount: IntArray, val weights: Array<FloatArray>)

    private fun triangleFilter(x: Double): Double {
        val ax = abs(x)
        return if (ax < 1.0) 1.0 - ax else 0.0
    }

    private fun computeCoefficients(inputSize: Int, outputSize: Int): AxisCoefficients {
        val scale = inputSize.toDouble() / outputSize
        val support = if (scale >= 1.0) scale else 1.0
        val inverseScale = if (scale >= 1.0) 1.0 / scale else 1.0
        val firstTap = IntArray(outputSize)
        val tapCount = IntArray(outputSize)
        val weights = Array(outputSize) { FloatArray(0) }
        for (outIndex in 0 until outputSize) {
            val center = scale * (outIndex + 0.5)
            val xmin = max((center - support + 0.5).toLong().toInt(), 0)
            val xsize = min((center + support + 0.5).toLong().toInt(), inputSize) - xmin
            val raw = DoubleArray(xsize) { j -> triangleFilter((j + xmin - center + 0.5) * inverseScale) }
            val total = raw.sum()
            firstTap[outIndex] = xmin
            tapCount[outIndex] = xsize
            weights[outIndex] = FloatArray(xsize) { j -> if (total != 0.0) (raw[j] / total).toFloat() else 0f }
        }
        return AxisCoefficients(firstTap, tapCount, weights)
    }

    /** Returns NCHW float32 [3, outSize, outSize] in [0,1]. */
    fun resizeToChw(rgba: ByteArray, width: Int, height: Int, outSize: Int = 256): FloatArray {
        val horizontal = computeCoefficients(width, outSize)
        val vertical = computeCoefficients(height, outSize)
        // Horizontal pass: [height][outSize][3]
        val intermediate = FloatArray(height * outSize * 3)
        for (y in 0 until height) {
            val rowBase = y * width * 4
            for (outX in 0 until outSize) {
                val start = horizontal.firstTap[outX]
                val taps = horizontal.weights[outX]
                var red = 0f; var green = 0f; var blue = 0f
                for (tap in taps.indices) {
                    val offset = rowBase + (start + tap) * 4
                    val weight = taps[tap]
                    red += weight * ((rgba[offset].toInt() and 0xff) / 255f)
                    green += weight * ((rgba[offset + 1].toInt() and 0xff) / 255f)
                    blue += weight * ((rgba[offset + 2].toInt() and 0xff) / 255f)
                }
                val dst = (y * outSize + outX) * 3
                intermediate[dst] = red; intermediate[dst + 1] = green; intermediate[dst + 2] = blue
            }
        }
        // Vertical pass into planar output.
        val plane = outSize * outSize
        val chw = FloatArray(3 * plane)
        for (outY in 0 until outSize) {
            val start = vertical.firstTap[outY]
            val taps = vertical.weights[outY]
            for (outX in 0 until outSize) {
                var red = 0f; var green = 0f; var blue = 0f
                for (tap in taps.indices) {
                    val src = ((start + tap) * outSize + outX) * 3
                    val weight = taps[tap]
                    red += weight * intermediate[src]
                    green += weight * intermediate[src + 1]
                    blue += weight * intermediate[src + 2]
                }
                val pixel = outY * outSize + outX
                chw[pixel] = red; chw[plane + pixel] = green; chw[2 * plane + pixel] = blue
            }
        }
        return chw
    }
}

/** Fused = sum_i w_i * basis_i over RGB; alpha forced to 1 (matches export_lut_rgba_float32). */
fun fuseLuts(basis: FloatArray, weights: FloatArray): FloatArray {
    val fused = FloatArray(LUT_FLOATS)
    val w0 = weights[0]; val w1 = weights[1]; val w2 = weights[2]
    var index = 0
    while (index < LUT_FLOATS) {
        for (channel in 0 until 3) {
            val i = index + channel
            fused[i] = w0 * basis[i] + w1 * basis[LUT_FLOATS + i] + w2 * basis[2 * LUT_FLOATS + i]
        }
        fused[index + 3] = 1f
        index += 4
    }
    return fused
}

/**
 * Exact-grid trilinear LUT application (binsize = 1/32, i.e. make_golden's
 * binsize_numerator=1.0), same corner accumulation order and the same 8-bit rounding as
 * ia3dlut.to_uint8 (x*255+0.5, clamp, truncate). Correctness reference only, not a fast path.
 */
fun applyLutCpu(src: ByteArray, pixelCount: Int, lut: FloatArray): ByteArray {
    val out = ByteArray(pixelCount * 4)
    val dim = LUT_DIM
    val scale = (dim - 1).toFloat()
    for (pixel in 0 until pixelCount) {
        val base = pixel * 4
        val rx = (src[base].toInt() and 0xff) / 255f * scale
        val gx = (src[base + 1].toInt() and 0xff) / 255f * scale
        val bx = (src[base + 2].toInt() and 0xff) / 255f * scale
        val ri = floor(rx).toInt().coerceIn(0, dim - 2)
        val gi = floor(gx).toInt().coerceIn(0, dim - 2)
        val bi = floor(bx).toInt().coerceIn(0, dim - 2)
        val rd = rx - ri; val gd = gx - gi; val bd = bx - bi
        var outR = 0f; var outG = 0f; var outB = 0f
        for (dr in 0..1) {
            val wr = if (dr == 1) rd else 1f - rd
            for (dg in 0..1) {
                val wg = if (dg == 1) gd else 1f - gd
                for (db in 0..1) {
                    val wb = if (db == 1) bd else 1f - bd
                    val weight = wr * wg * wb
                    val lutIndex = ((ri + dr) + (gi + dg) * dim + (bi + db) * dim * dim) * 4
                    outR += weight * lut[lutIndex]
                    outG += weight * lut[lutIndex + 1]
                    outB += weight * lut[lutIndex + 2]
                }
            }
        }
        out[base] = toUint8(outR)
        out[base + 1] = toUint8(outG)
        out[base + 2] = toUint8(outB)
        out[base + 3] = 0xff.toByte()
    }
    return out
}

private fun toUint8(value: Float): Byte = (value * 255f + 0.5f).coerceIn(0f, 255f).toInt().toByte()

/** 8-bit RGB diff stats (alpha ignored). */
fun diffStats(a: ByteArray, b: ByteArray, pixelCount: Int): JSONObject {
    var maxAbs = 0
    var sumAbs = 0L
    var countGt1 = 0L
    var countGt2 = 0L
    for (pixel in 0 until pixelCount) {
        var pixelMax = 0
        for (channel in 0 until 3) {
            val i = pixel * 4 + channel
            val d = abs((a[i].toInt() and 0xff) - (b[i].toInt() and 0xff))
            sumAbs += d
            if (d > pixelMax) pixelMax = d
        }
        if (pixelMax > maxAbs) maxAbs = pixelMax
        if (pixelMax > 1) countGt1++
        if (pixelMax > 2) countGt2++
    }
    return JSONObject()
        .put("max_abs_diff", maxAbs)
        .put("mean_abs_diff", sumAbs.toDouble() / (pixelCount * 3.0))
        .put("frac_gt1", countGt1.toDouble() / pixelCount)
        .put("frac_gt2", countGt2.toDouble() / pixelCount)
}

fun maxAbsDiff(a: FloatArray, b: FloatArray, count: Int = min(a.size, b.size)): Double {
    var maxDiff = 0.0
    for (i in 0 until count) maxDiff = max(maxDiff, abs(a[i] - b[i]).toDouble())
    return maxDiff
}

/** Max abs diff over RGB of an RGBA float array (alpha excluded). */
fun maxAbsDiffRgb(a: FloatArray, b: FloatArray): Double {
    var maxDiff = 0.0
    var i = 0
    while (i < min(a.size, b.size)) {
        if (i % 4 != 3) maxDiff = max(maxDiff, abs(a[i] - b[i]).toDouble())
        i++
    }
    return maxDiff
}
