package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.background.FloatPlane
import com.lightlylabs.lightly.background.PlaneOps
import com.lightlylabs.lightly.render.image.FrameSource
import com.lightlylabs.lightly.session.NormalisedRect
import com.lightlylabs.lightly.vision.sunglasses.FaceSunglassesAnalysis
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * rendering-v2 §7.5 composite step 1 on Android: a face found wearing glasses has them painted out before the chosen pair
 * goes on, with Remove's LaMa model, and the fill is kept as a [RemovePatch] by digest exactly as a Remove stroke's is
 * (`faceEdit.sunglasses.removed`), so preview and export composite the same pixels and the model never runs again for it.
 * A port of iOS `SunglassesRemoval.swift`: the same dilation, window and feather.
 */
object SunglassesRemoval {
    /** The trial's MaxFilters 15, 15, 15 and 9 px on a 2000 px photo: a radius of 25 px per 2000 px of the long edge. */
    const val DILATION_OF_LONG_EDGE = 0.0125
    const val CONTEXT_FACTOR = 1.5
    const val MINIMUM_WINDOW = 256
    const val FEATHER_SIGMA = 3.0

    class Result(val patch: RemovePatch, val rect: NormalisedRect)

    /** The patch for [analysis]'s face, or null when it wears no glasses. [frame] is the photo at full resolution. */
    fun patch(analysis: FaceSunglassesAnalysis, frame: FrameSource, inpainter: Inpainter, cancelled: () -> Boolean = { false }): Result? {
        val glasses = analysis.glassesMask() ?: return null
        val w = frame.width; val h = frame.height
        val f = w.toDouble() / analysis.analysisWidth   // source pixels per analysis pixel
        val radius = (DILATION_OF_LONG_EDGE * max(analysis.analysisWidth, analysis.analysisHeight)).roundToInt()
        val gx0 = glasses.x0 - radius; val gy0 = glasses.y0 - radius
        val gw = glasses.width + 2 * radius; val gh = glasses.height + 2 * radius
        val plane = FloatPlane(gw, gh)
        for (y in 0 until glasses.height) for (x in 0 until glasses.width) if (glasses.mask[y * glasses.width + x]) plane[x + radius, y + radius] = 1f
        // Square dilation, as iOS FloatImage.dilated: a box mean above zero marks every pixel within the radius.
        val spread = PlaneOps.boxFilter(plane, radius)
        val dilated = BooleanArray(gw * gh) { spread.values[it] > 1e-6f }
        fun masked(sx: Double, sy: Double): Boolean {
            val ax = floor(sx / f).toInt() - gx0; val ay = floor(sy / f).toInt() - gy0
            return ax in 0 until gw && ay in 0 until gh && dilated[ay * gw + ax]
        }
        var lx = Int.MAX_VALUE; var ly = Int.MAX_VALUE; var hx = Int.MIN_VALUE; var hy = Int.MIN_VALUE
        for (y in 0 until gh) for (x in 0 until gw) if (dilated[y * gw + x]) { lx = min(lx, x); ly = min(ly, y); hx = max(hx, x); hy = max(hy, y) }
        if (lx > hx) return null
        val bx0 = max(0, ((lx + gx0) * f).toInt()); val by0 = max(0, ((ly + gy0) * f).toInt())
        val bx1 = min(w, ceil((hx + gx0 + 1) * f).toInt()); val by1 = min(h, ceil((hy + gy0 + 1) * f).toInt())
        if (bx1 <= bx0 || by1 <= by0) return null
        // The context window: 1.5 × the mask's extent, at least 256 px, inside the photo.
        val extent = max(bx1 - bx0, by1 - by0)
        val side = minOf(max((extent * CONTEXT_FACTOR).toInt(), MINIMUM_WINDOW), w, h)
        val wx = ((bx0 + bx1) / 2.0 - side / 2.0).toInt().coerceIn(0, w - side)
        val wy = ((by0 + by1) / 2.0 - side / 2.0).toInt().coerceIn(0, h - side)
        val window = frame.region(wx, wy, side, side)
        val n = RemoveEngine.MODEL_SIDE; val nn = n * n
        val scale = side.toDouble() / n
        val image = FloatArray(3 * nn); val mask = FloatArray(nn)
        for (my in 0 until n) for (mx in 0 until n) {
            val sx = (mx + 0.5) * scale - 0.5; val sy = (my + 0.5) * scale - 0.5
            val i = my * n + mx
            bilinear(window.pixels, side, sx, sy) { c, v -> image[c * nn + i] = v }
            if (masked(wx + sx + 0.5, wy + sy + 0.5)) mask[i] = 1f
        }
        if (cancelled()) throw kotlinx.coroutines.CancellationException("Sunglasses removal cancelled")
        val filled = inpainter.inpaint(image, mask)
        require(filled.size == 3 * nn) { "inpainter returned ${filled.size} values" }
        if (cancelled()) throw kotlinx.coroutines.CancellationException("Sunglasses removal cancelled")
        // Paste back over the mask's box, alpha = the mask feathered by a Gaussian.
        val pw = bx1 - bx0; val ph = by1 - by0
        val alphaPlane = FloatPlane(pw, ph)
        for (y in 0 until ph) for (x in 0 until pw) if (masked(bx0 + x + 0.5, by0 + y + 0.5)) alphaPlane[x, y] = 1f
        val alpha = PlaneOps.gaussianBlur(alphaPlane, FEATHER_SIGMA * max(1.0, f))
        val rgba = ByteArray(pw * ph * 4)
        for (y in 0 until ph) for (x in 0 until pw) {
            val a = alpha[x, y]
            if (a <= 0.002f) continue
            val mx = ((bx0 + x - wx + 0.5) / scale - 0.5).coerceIn(0.0, n - 1.0)
            val my = ((by0 + y - wy + 0.5) / scale - 0.5).coerceIn(0.0, n - 1.0)
            val o = (y * pw + x) * 4
            for (c in 0 until 3) rgba[o + c] = (bilinearPlane(filled, c * nn, n, mx, my) * 255 + 0.5).toInt().coerceIn(0, 255).toByte()
            rgba[o + 3] = (a * 255 + 0.5f).toInt().coerceIn(0, 255).toByte()
        }
        val patch = RemovePatch(bx0, by0, pw, ph, rgba, w, h)
        return Result(patch, NormalisedRect(bx0.toDouble() / w, by0.toDouble() / h, pw.toDouble() / w, ph.toDouble() / h))
    }

    /** Bilinear RGB (0…1) of a square RGBA8 window at pixel coordinates (centres at integers), edge-clamped. */
    private inline fun bilinear(px: ByteArray, side: Int, x: Double, y: Double, out: (Int, Float) -> Unit) {
        val cx = x.coerceIn(0.0, side - 1.0); val cy = y.coerceIn(0.0, side - 1.0)
        val x0 = cx.toInt(); val y0 = cy.toInt(); val x1 = min(x0 + 1, side - 1); val y1 = min(y0 + 1, side - 1)
        val fx = cx - x0; val fy = cy - y0
        for (c in 0 until 3) {
            val a = (px[(y0 * side + x0) * 4 + c].toInt() and 0xff) / 255.0; val b = (px[(y0 * side + x1) * 4 + c].toInt() and 0xff) / 255.0
            val d = (px[(y1 * side + x0) * 4 + c].toInt() and 0xff) / 255.0; val e = (px[(y1 * side + x1) * 4 + c].toInt() and 0xff) / 255.0
            out(c, ((a * (1 - fx) + b * fx) * (1 - fy) + (d * (1 - fx) + e * fx) * fy).toFloat())
        }
    }

    private fun bilinearPlane(plane: FloatArray, offset: Int, n: Int, x: Double, y: Double): Double {
        val x0 = x.toInt(); val y0 = y.toInt(); val x1 = min(x0 + 1, n - 1); val y1 = min(y0 + 1, n - 1)
        val fx = x - x0; val fy = y - y0
        fun at(xx: Int, yy: Int) = plane[offset + yy * n + xx].toDouble()
        return (at(x0, y0) * (1 - fx) + at(x1, y0) * fx) * (1 - fy) + (at(x0, y1) * (1 - fx) + at(x1, y1) * fx) * fy
    }
}
