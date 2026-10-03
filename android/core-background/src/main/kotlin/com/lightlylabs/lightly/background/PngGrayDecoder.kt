package com.lightlylabs.lightly.background

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.zip.Inflater
import kotlin.math.abs

/**
 * A minimal PNG decoder for depth maps: 8- or 16-bit greyscale, greyscale+alpha, RGB or RGBA,
 * non-interlaced. Returns the FIRST channel normalised to [0, 1] (the reference reader takes channel 0).
 *
 * Why not the platform decoder: Android's BitmapFactory reduces 16-bit PNGs to 8 bits, which would
 * throw away most of a depth map's precision; this one keeps all 16 bits and runs on the JVM too.
 */
object PngGrayDecoder {
    private val SIGNATURE = byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10)

    fun isPng(bytes: ByteArray) = bytes.size > 8 && bytes.copyOfRange(0, 8).contentEquals(SIGNATURE)

    fun decode(bytes: ByteArray): FloatPlane {
        require(isPng(bytes)) { "not a PNG" }
        val buffer = ByteBuffer.wrap(bytes)
        buffer.position(8)
        var width = 0
        var height = 0
        var bitDepth = 0
        var colourType = 0
        val idat = ByteArrayOutputStream()
        while (buffer.remaining() >= 12) {
            val length = buffer.int
            val type = String(byteArrayOf(buffer.get(), buffer.get(), buffer.get(), buffer.get()), Charsets.US_ASCII)
            val data = ByteArray(length).also { buffer.get(it) }
            buffer.int // CRC (not checked: the container's length fields already bound the item)
            when (type) {
                "IHDR" -> {
                    val header = ByteBuffer.wrap(data)
                    width = header.int; height = header.int
                    bitDepth = data[8].toInt() and 0xff
                    colourType = data[9].toInt() and 0xff
                    require(data[12].toInt() == 0) { "interlaced PNG depth maps are not supported" }
                }
                "IDAT" -> idat.write(data)
                "IEND" -> break
            }
        }
        require(width > 0 && height > 0) { "PNG without IHDR" }
        require(bitDepth == 8 || bitDepth == 16) { "PNG bit depth $bitDepth is not supported" }
        val channels = when (colourType) { 0 -> 1; 4 -> 2; 2 -> 3; 6 -> 4; else -> throw IllegalArgumentException("PNG colour type $colourType is not supported") }
        val bytesPerPixel = channels * bitDepth / 8
        val stride = width * bytesPerPixel
        val raw = inflate(idat.toByteArray(), (stride + 1) * height)
        val current = ByteArray(stride)
        val previous = ByteArray(stride)
        val out = FloatPlane(width, height)
        val maximum = if (bitDepth == 16) 65535f else 255f
        for (y in 0 until height) {
            val base = y * (stride + 1)
            val filter = raw[base].toInt() and 0xff
            for (i in 0 until stride) {
                val x = raw[base + 1 + i].toInt() and 0xff
                val a = if (i >= bytesPerPixel) current[i - bytesPerPixel].toInt() and 0xff else 0
                val b = previous[i].toInt() and 0xff
                val c = if (i >= bytesPerPixel) previous[i - bytesPerPixel].toInt() and 0xff else 0
                val value = when (filter) {
                    0 -> x
                    1 -> x + a
                    2 -> x + b
                    3 -> x + (a + b) / 2
                    4 -> x + paeth(a, b, c)
                    else -> throw IllegalArgumentException("PNG filter $filter")
                }
                current[i] = value.toByte()
            }
            for (xPixel in 0 until width) {
                val offset = xPixel * bytesPerPixel
                val sample = if (bitDepth == 16) ((current[offset].toInt() and 0xff) shl 8) or (current[offset + 1].toInt() and 0xff) else current[offset].toInt() and 0xff
                out[xPixel, y] = sample / maximum
            }
            current.copyInto(previous)
        }
        return out
    }

    private fun paeth(a: Int, b: Int, c: Int): Int {
        val p = a + b - c
        val pa = abs(p - a)
        val pb = abs(p - b)
        val pc = abs(p - c)
        return if (pa <= pb && pa <= pc) a else if (pb <= pc) b else c
    }

    private fun inflate(data: ByteArray, expected: Int): ByteArray {
        val inflater = Inflater()
        inflater.setInput(data)
        val out = ByteArray(expected)
        var total = 0
        while (total < expected && !inflater.finished()) {
            val n = inflater.inflate(out, total, expected - total)
            if (n == 0 && (inflater.needsInput() || inflater.needsDictionary())) break
            total += n
        }
        inflater.end()
        require(total == expected) { "PNG data is truncated ($total of $expected bytes)" }
        return out
    }
}
