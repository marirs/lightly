package com.lightlylabs.lightly.develop

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.sqrt

/**
 * The contract's portable random source (rendering-v2.md §6 F2): integer hashes, so the grain field
 * is identical on every platform and in preview and export. All arithmetic is uint32 (kept in the
 * low 32 bits of an Int, which wraps exactly like uint32 multiplication).
 */
object PortableRandom {
    /** C. Wellons' lowbias32. */
    fun lowbias32(input: Int): Int {
        var x = input
        x = x xor (x ushr 16)
        x *= 0x7FEB352D
        x = x xor (x ushr 15)
        x *= 0x846CA68B.toInt()
        x = x xor (x ushr 16)
        return x
    }

    /** Standard normal value at integer cell (i, j) of [layer] (Box-Muller on two hashes). */
    fun gaussian(seed: Int, layer: Int, i: Int, j: Int): Double {
        val base = lowbias32(seed xor lowbias32(layer))
        val h1 = lowbias32(base xor lowbias32((i * 0x9E3779B1.toInt()) xor lowbias32(j)))
        val h2 = lowbias32(h1 xor 0x85EBCA6B.toInt())
        val u1 = ((h1 ushr 8).toDouble() + 0.5) / 16777216.0
        val u2 = ((h2 ushr 8).toDouble() + 0.5) / 16777216.0
        return sqrt(-2 * ln(u1)) * cos(2 * PI * u2)
    }

    /** gaussian_field: rows × cols values, row-major. */
    fun field(seed: Long, layer: Int, rows: Int, cols: Int): DoubleArray {
        val seed32 = seed.toInt()
        return DoubleArray(rows * cols) { index -> gaussian(seed32, layer, index / cols, index % cols) }
    }

    fun toUnsigned(value: Int): Long = value.toLong() and 0xFFFFFFFFL
}
