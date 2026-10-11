package com.lightlylabs.lightly.vision

import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * `portrait.smile` (rendering-v2 revision 7 §7.3, owner amendment 2026-10-11): an inverse warp around the two mouth
 * corners. With a = amount / 100, the mouth width m = |R − L|, û from L to R and n̂ = û turned 90° anticlockwise in image
 * coordinates (y down, so it points up the face along the face's own axis):
 * - corner displacements d_L = a·m·(0.10·n̂ − 0.04·û) and d_R = a·m·(0.10·n̂ + 0.04·û) (up and slightly outward for a
 *   positive amount, down and slightly inward for a negative one);
 * - falloff w_C(p) = max(0, 1 − |p − C|² / r²)² with r = 0.45·m;
 * - the output pixel p samples the input at p − (w_L(p)·d_L + w_R(p)·d_R), bilinear, clamped to the image.
 * Pixels outside both discs are copied unchanged; amount 0 changes nothing at all.
 *
 * Coordinates are pixel centres (x + 0.5, y + 0.5), so a zero displacement samples a pixel exactly.
 */
object SmileWarp {
    const val LIFT = 0.10
    const val OUTWARD = 0.04
    const val RADIUS = 0.45

    /** The two corner displacements in pixels, for corners [left] and [right] in pixels. Public for tests. */
    fun displacements(left: Point, right: Point, amount: Double): Pair<Point, Point> {
        val a = amount / 100
        val mx = right.x - left.x
        val my = right.y - left.y
        val m = hypot(mx, my)
        if (m == 0.0) return Point(0.0, 0.0) to Point(0.0, 0.0)
        val ux = mx / m
        val uy = my / m
        // û turned 90° anticlockwise as seen with y pointing down: (x, y) → (y, −x).
        val nx = uy
        val ny = -ux
        val dLeft = Point(a * m * (LIFT * nx - OUTWARD * ux), a * m * (LIFT * ny - OUTWARD * uy))
        val dRight = Point(a * m * (LIFT * nx + OUTWARD * ux), a * m * (LIFT * ny + OUTWARD * uy))
        return dLeft to dRight
    }

    /**
     * Warps [pixels] (RGBA8, [width] × [height]) in place. [corners] are the mouth corners normalised to the image
     * (top-left origin), as [DetectedFace.mouthCorners] gives them.
     */
    fun apply(pixels: ByteArray, width: Int, height: Int, corners: Pair<Point, Point>, amount: Double) {
        if (amount == 0.0) return
        val left = Point(corners.first.x * width, corners.first.y * height)
        val right = Point(corners.second.x * width, corners.second.y * height)
        val m = hypot(right.x - left.x, right.y - left.y)
        if (m < 1e-6) return
        val r = RADIUS * m
        val (dLeft, dRight) = displacements(left, right, amount)
        // Only the discs' bounding box can change; it reads from an untouched copy of the input.
        val x0 = max(0, floor(min(left.x, right.x) - r).toInt())
        val x1 = min(width - 1, ceil(max(left.x, right.x) + r).toInt())
        val y0 = max(0, floor(min(left.y, right.y) - r).toInt())
        val y1 = min(height - 1, ceil(max(left.y, right.y) + r).toInt())
        if (x0 > x1 || y0 > y1) return
        val input = pixels.copyOf()
        val r2 = r * r
        for (y in y0..y1) for (x in x0..x1) {
            val px = x + 0.5
            val py = y + 0.5
            val wL = falloff(px - left.x, py - left.y, r2)
            val wR = falloff(px - right.x, py - right.y, r2)
            if (wL == 0.0 && wR == 0.0) continue
            val sx = px - (wL * dLeft.x + wR * dRight.x)
            val sy = py - (wL * dLeft.y + wR * dRight.y)
            sampleBilinear(input, width, height, sx, sy, pixels, (y * width + x) * 4)
        }
    }

    /** w = max(0, 1 − d²/r²)². */
    fun falloff(dx: Double, dy: Double, r2: Double): Double {
        val t = 1 - (dx * dx + dy * dy) / r2
        return if (t <= 0) 0.0 else t * t
    }

    /** Bilinear RGB at the continuous position ([sx], [sy]) in pixel-centre coordinates, clamped to the image; alpha kept. */
    private fun sampleBilinear(input: ByteArray, width: Int, height: Int, sx: Double, sy: Double, out: ByteArray, offset: Int) {
        val fx = (sx - 0.5).coerceIn(0.0, (width - 1).toDouble())
        val fy = (sy - 0.5).coerceIn(0.0, (height - 1).toDouble())
        val ix = min(fx.toInt(), width - 2).coerceAtLeast(0)
        val iy = min(fy.toInt(), height - 2).coerceAtLeast(0)
        val tx = if (width == 1) 0.0 else fx - ix
        val ty = if (height == 1) 0.0 else fy - iy
        val ix1 = min(ix + 1, width - 1)
        val iy1 = min(iy + 1, height - 1)
        for (c in 0 until 3) {
            val p00 = input[(iy * width + ix) * 4 + c].toInt() and 0xff
            val p10 = input[(iy * width + ix1) * 4 + c].toInt() and 0xff
            val p01 = input[(iy1 * width + ix) * 4 + c].toInt() and 0xff
            val p11 = input[(iy1 * width + ix1) * 4 + c].toInt() and 0xff
            val top = p00 + (p10 - p00) * tx
            val bottom = p01 + (p11 - p01) * tx
            out[offset + c] = (top + (bottom - top) * ty + 0.5).toInt().coerceIn(0, 255).toByte()
        }
    }
}
