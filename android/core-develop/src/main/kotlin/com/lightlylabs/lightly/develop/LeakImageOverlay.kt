package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.image.Rgba8Image
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.sin

/** The light leak's per-pixel step of stage 10: screens light onto rgb (sRGB-encoded, [0, 1]) at frame pixel (x, y). */
internal interface LeakOverlay {
    fun apply(rgb: FloatArray, x: Int, y: Int)
}

/**
 * The light leak of rendering-v2 revision 8 (§Light leak, owner 2026-10-11): a leak-pack image laid over the frame.
 * On a W × H frame:
 * ```
 * s = max(W / iw, H / ih)                    aspect fill
 * o = (x·W/100, y·H/100), θ = rad(rotation)  the image's centre and its clockwise turn
 * q = o + R(−θ)·(p − o)                      undo the turn about o
 * u = (q − o) / s + (iw/2, ih/2)             image pixel; outside the image: no light
 * f = smoothstep(0, 0.08, min(u.x/iw, 1 − u.x/iw)) · smoothstep(0, 0.08, min(u.y/ih, 1 − u.y/ih))   soft edges
 * L = bilinear(image, u) · f · intensity/100 sRGB-encoded, per channel
 * out = 1 − (1 − in)·(1 − L)                 screen
 * ```
 * Pixel centres are at +0.5 on both the frame and the image, so a tile of a frame (Save copy) samples exactly what the
 * whole frame (the preview) does at the same resolution.
 */
class LeakImageOverlay private constructor(
    private val image: Rgba8Image,
    private val centreX: Double, private val centreY: Double,
    private val cosine: Double, private val sine: Double,
    /** 1 / s: frame pixels to image pixels. */
    private val imagePixelsPerFramePixel: Double,
    /** intensity / 100. */
    private val strength: Double,
) : LeakOverlay {
    private val halfImageWidth = image.width / 2.0
    private val halfImageHeight = image.height / 2.0

    /** L at frame pixel (x, y) into [out] (sRGB-encoded, [0, 1], already × intensity/100); false outside the image. */
    fun light(x: Int, y: Int, out: DoubleArray): Boolean {
        val dx = x + 0.5 - centreX
        val dy = y + 0.5 - centreY
        // R(−θ)·(p − o): with y pointing down, R(θ) turns clockwise, so this undoes the image's clockwise turn.
        val u = (cosine * dx + sine * dy) * imagePixelsPerFramePixel + halfImageWidth
        val v = (-sine * dx + cosine * dy) * imagePixelsPerFramePixel + halfImageHeight
        if (u < 0 || v < 0 || u > image.width || v > image.height) return false
        // The light fades over the last 8 % of each side (contract 080003a), so a moved or turned leak shows no seam.
        val edgeFade = edgeFade(u / image.width) * edgeFade(v / image.height)
        if (edgeFade <= 0.0) return false
        sampleBilinear(u, v, out)
        for (c in 0 until 3) out[c] *= edgeFade * strength
        return true
    }

    override fun apply(rgb: FloatArray, x: Int, y: Int) {
        val light = DoubleArray(3)
        if (!light(x, y, light)) return
        for (c in 0 until 3) rgb[c] = (1 - (1 - rgb[c].toDouble()) * (1 - light[c])).coerceIn(0.0, 1.0).toFloat()
    }

    /** Bilinear between pixel centres (i + 0.5), clamped to the edge pixels in the outer half pixel. */
    private fun sampleBilinear(u: Double, v: Double, out: DoubleArray) {
        val fx = u - 0.5
        val fy = v - 0.5
        val x0 = floor(fx).toInt()
        val y0 = floor(fy).toInt()
        val tx = fx - x0
        val ty = fy - y0
        val left = x0.coerceIn(0, image.width - 1)
        val right = (x0 + 1).coerceIn(0, image.width - 1)
        val top = y0.coerceIn(0, image.height - 1)
        val bottom = (y0 + 1).coerceIn(0, image.height - 1)
        val pixels = image.pixels
        val rowTop = top * image.width
        val rowBottom = bottom * image.width
        for (c in 0 until 3) {
            fun at(row: Int, column: Int) = (pixels[(row + column) * 4 + c].toInt() and 0xff) / 255.0
            val upper = at(rowTop, left) * (1 - tx) + at(rowTop, right) * tx
            val lower = at(rowBottom, left) * (1 - tx) + at(rowBottom, right) * tx
            out[c] = upper * (1 - ty) + lower * ty
        }
    }

    companion object {
        private val LEAK_ID = Regex("^leak-[0-9a-f]{12}$")

        /** The fade's width as a fraction of each image side (rendering-v2 revision 8 §Light leak, `f`). */
        const val EDGE_FADE_FRACTION = 0.08

        /** smoothstep(0, 0.08, min(t, 1 − t)) for a position [t] across one image side (0…1). */
        internal fun edgeFade(t: Double): Double {
            val x = (minOf(t, 1 - t) / EDGE_FADE_FRACTION).coerceIn(0.0, 1.0)
            return x * x * (3 - 2 * x)
        }

        /** True for a revision-8 style naming a leak-pack image; the four drawn styles are not. */
        fun isLeakImageStyle(style: String): Boolean = LEAK_ID.matches(style)

        /** Null at intensity 0: the image then adds nothing anywhere. */
        fun of(image: Rgba8Image, e: EffectsParams, frameWidth: Int, frameHeight: Int): LeakImageOverlay? {
            if (e.leakIntensity <= 0) return null
            val scale = max(frameWidth.toDouble() / image.width, frameHeight.toDouble() / image.height)
            val theta = e.leakRotation * PI / 180
            return LeakImageOverlay(
                image,
                e.leakX / 100 * frameWidth, e.leakY / 100 * frameHeight,
                cos(theta), sin(theta), 1 / scale, e.leakIntensity / 100,
            )
        }
    }
}
