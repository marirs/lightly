package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.background.FloatPlane
import com.lightlylabs.lightly.render.image.Rgba8Image
import java.io.File
import kotlin.math.cbrt
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * Debug builds only (2026-10-06): colour difference between two frames of the same edit at the same displayed size,
 * split by the subject matte, for checking the ruler-drag frame against the frame the photo changes to on release.
 * Measurement code, not part of any render path.
 */
internal object DragOrderComparison {
    /** ΔE (CIE76, D65) statistics of one region. */
    data class RegionStats(val pixels: Int, val mean: Double, val p95: Double, val p99: Double, val max: Double, val over3: Double) {
        override fun toString() = "n=$pixels mean=${f(mean)} p95=${f(p95)} p99=${f(p99)} max=${f(max)} >3=${f(over3 * 100)}%"
    }

    /**
     * ΔE between [a] and [b] (same size) in three regions of [matte] (sampled nearest at the frame's size): subject
     * (matte ≥ 0.98), soft edge (between), background (≤ 0.02).
     */
    /**
     * ΔE between two raw RGBA8 frames of [width] × [height] on disk ([writeRaw]), streamed one row at a time (no frame
     * held in the heap), in three regions of [matte] (sampled nearest at the frame's size): subject (matte ≥ 0.98), soft
     * edge (between), background (≤ 0.02).
     */
    fun compare(first: File, second: File, width: Int, height: Int, matte: FloatPlane?): Map<String, RegionStats> {
        val regions = listOf("subject", "edge", "background", "all").associateWith { Histogram() }
        val rowA = ByteArray(width * 4)
        val rowB = ByteArray(width * 4)
        java.io.DataInputStream(first.inputStream().buffered()).use { a ->
            java.io.DataInputStream(second.inputStream().buffered()).use { b ->
                for (y in 0 until height) {
                    a.readFully(rowA); b.readFully(rowB)
                    for (x in 0 until width) {
                        val difference = deltaE(rowA, rowB, x * 4)
                        regions.getValue("all").add(difference)
                        val m = matte?.let { it[x * it.width / width, y * it.height / height] } ?: continue
                        val region = when { m >= 0.98f -> "subject"; m <= 0.02f -> "background"; else -> "edge" }
                        regions.getValue(region).add(difference)
                    }
                }
            }
        }
        return regions.mapValues { (_, histogram) -> histogram.stats() }
    }

    fun writeRaw(image: Rgba8Image, file: File) = file.writeBytes(image.pixels)

    private class Histogram {
        private val bins = IntArray(BINS)
        private var count = 0
        private var sum = 0.0
        private var max = 0.0
        private var over3 = 0

        fun add(value: Double) {
            bins[minOf(BINS - 1, (value / BIN_WIDTH).toInt())]++
            count++; sum += value; if (value > max) max = value; if (value > 3.0) over3++
        }

        fun stats(): RegionStats {
            if (count == 0) return RegionStats(0, 0.0, 0.0, 0.0, 0.0, 0.0)
            fun quantile(q: Double): Double {
                val target = (count - 1) * q
                var seen = 0
                for (bin in bins.indices) { seen += bins[bin]; if (seen > target) return (bin + 1) * BIN_WIDTH }
                return max
            }
            return RegionStats(count, sum / count, quantile(0.95), quantile(0.99), max, over3.toDouble() / count)
        }

        companion object { const val BIN_WIDTH = 0.02; const val BINS = 10_000 }
    }

    fun writePng(image: Rgba8Image, file: File) {
        val bitmap = android.graphics.Bitmap.createBitmap(image.width, image.height, android.graphics.Bitmap.Config.ARGB_8888)
        // ARGB_8888 is stored as R, G, B, A bytes: the RGBA8 buffer copies straight in.
        bitmap.copyPixelsFromBuffer(java.nio.ByteBuffer.wrap(image.pixels))
        file.outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    private fun deltaE(a: ByteArray, b: ByteArray, i: Int): Double {
        val (l1, a1, b1) = lab(a, i)
        val (l2, a2, b2) = lab(b, i)
        return sqrt((l1 - l2).pow(2) + (a1 - a2).pow(2) + (b1 - b2).pow(2))
    }

    private fun lab(p: ByteArray, i: Int): Triple<Double, Double, Double> {
        fun linear(byte: Byte): Double {
            val c = (byte.toInt() and 0xff) / 255.0
            return if (c <= 0.04045) c / 12.92 else ((c + 0.055) / 1.055).pow(2.4)
        }
        val r = linear(p[i]); val g = linear(p[i + 1]); val b = linear(p[i + 2])
        val x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        val y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        val z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        fun f(t: Double) = if (t > 216.0 / 24389) cbrt(t) else (24389.0 / 27 * t + 16) / 116
        return Triple(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    private fun f(v: Double) = "%.2f".format(v)
}
