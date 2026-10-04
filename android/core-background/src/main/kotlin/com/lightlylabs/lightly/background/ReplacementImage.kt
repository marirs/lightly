package com.lightlylabs.lightly.background

import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * The replacement background as an sRGB image the size of the frame (rendering-v2 stage
 * background.replace): a solid colour, a CSS-style linear gradient, or a photo aspect-filled then
 * scaled by `scale` % around the (x %, y %) position, as the prototype's
 * `background-size:scale%; background-position:x% y%` places it.
 */
object ReplacementImage {
    fun colour(width: Int, height: Int, hex: String): FloatImage {
        val (r, g, b) = parse(hex)
        return FloatImage(width, height, 3, FloatArray(width * height * 3) { when (it % 3) { 0 -> r; 1 -> g; else -> b } })
    }

    /** CSS `linear-gradient(angle, stops…)`: 0° points up, angles turn clockwise; the line spans the box's corners. */
    fun gradient(width: Int, height: Int, angleDegrees: Double, stops: List<Pair<String, Double>>): FloatImage {
        require(stops.size >= 2)
        val colours = stops.map { parse(it.first) }
        val positions = stops.map { it.second }
        val a = Math.toRadians(angleDegrees)
        val dx = sin(a)
        val dy = -cos(a)
        val length = abs(width * sin(a)) + abs(height * cos(a))
        val out = FloatImage(width, height, 3)
        for (y in 0 until height) for (x in 0 until width) {
            val px = x + 0.5 - width / 2.0
            val py = y + 0.5 - height / 2.0
            val t = ((px * dx + py * dy) / length + 0.5).coerceIn(0.0, 1.0)
            var i = 0
            while (i < positions.size - 2 && t > positions[i + 1]) i++
            val span = max(positions[i + 1] - positions[i], 1e-9)
            val f = ((t - positions[i]) / span).coerceIn(0.0, 1.0).toFloat()
            for (c in 0 until 3) out.data[(y * width + x) * 3 + c] = colours[i][c] * (1 - f) + colours[i + 1][c] * f
        }
        return out
    }

    /**
     * [photo] (sRGB floats) aspect-filled into width × height, enlarged by [scalePercent] (100…200), and
     * positioned by [xPercent]/[yPercent] like CSS background-position (0 = left/top edge aligned).
     */
    fun photo(photo: FloatImage, width: Int, height: Int, scalePercent: Double, xPercent: Double, yPercent: Double): FloatImage =
        photo(planesOf(photo), width, height, scalePercent, xPercent, yPercent)

    /** The photo split into R, G, B planes. Callers that draw one photo repeatedly cache this (11 MB per call). */
    fun planesOf(photo: FloatImage): List<FloatPlane> =
        (0 until 3).map { c -> FloatPlane(photo.width, photo.height, FloatArray(photo.width * photo.height) { photo.data[it * 3 + c] }) }

    fun photo(planes: List<FloatPlane>, width: Int, height: Int, scalePercent: Double, xPercent: Double, yPercent: Double): FloatImage {
        val source = planes[0]
        val factor = max(width.toDouble() / source.width, height.toDouble() / source.height) * scalePercent / 100.0
        val scaledW = source.width * factor
        val scaledH = source.height * factor
        val left = (width - scaledW) * xPercent / 100.0
        val top = (height - scaledH) * yPercent / 100.0
        val out = FloatImage(width, height, 3)
        // Area-average when shrinking, bilinear when enlarging.
        val shrink = factor < 1
        val pre = if (shrink) planes.map { DepthModelInput.resizeArea(it, scaledW.roundToInt().coerceAtLeast(1), scaledH.roundToInt().coerceAtLeast(1)) } else planes
        val preFactor = if (shrink) pre[0].width / scaledW else 1.0 / factor
        for (y in 0 until height) for (x in 0 until width) {
            val sx = if (shrink) (x + 0.5 - left) * preFactor - 0.5 else (x + 0.5 - left) / factor - 0.5
            val sy = if (shrink) (y + 0.5 - top) * preFactor - 0.5 else (y + 0.5 - top) / factor - 0.5
            for (c in 0 until 3) out.data[(y * width + x) * 3 + c] = pre[c].sample(sx, sy)
        }
        return out
    }

    fun parse(hex: String): FloatArray {
        require(Regex("^#[0-9A-Fa-f]{6}$").matches(hex)) { "colour must be #RRGGBB, was $hex" }
        return FloatArray(3) { Integer.parseInt(hex.substring(1 + it * 2, 3 + it * 2), 16) / 255f }
    }
}
