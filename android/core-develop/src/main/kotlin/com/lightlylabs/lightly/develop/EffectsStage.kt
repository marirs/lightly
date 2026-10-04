package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.image.Rgba8Image
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/** `tools.effects` as plain values (edit-recipe-v1 `effects`); the app maps the recipe onto it. */
data class EffectsParams(
    val leakEnabled: Boolean = false,
    /** warm, amber, rose, prism. */
    val leakStyle: String = "warm",
    val leakIntensity: Double = 55.0,
    val leakX: Double = 18.0,
    val leakY: Double = 14.0,
    val leakRotation: Double = 0.0,
    val grainEnabled: Boolean = false,
    /** fine, film, coarse. */
    val grainStyle: String = "film",
    val grainAmount: Double = 30.0,
    val grainSize: Double = 40.0,
    val grainRoughness: Double = 50.0,
    val grainSeed: Long = 0,
    val vignetteEnabled: Boolean = false,
    val vignetteAmount: Double = 35.0,
    val vignetteSize: Double = 60.0,
    val vignetteSoftness: Double = 60.0,
) {
    val anyEnabled: Boolean get() = leakEnabled || grainEnabled || vignetteEnabled
}

/**
 * Stage 10, `effects` (rendering-v2 §1, §6), on the frame after geometry, in the contract order
 * light leak → preset vignette → user vignette → preset grain → user grain.
 *
 * The person's effects are added on top of the preset's own vignette and grain, never replace them
 * (the approved "added to it, not replaced" notice). [presetFinishing] is already scaled by the
 * Develop Amount (DevelopRenderPlan); the person's effects are not scaled. Vignette and grain are the
 * revision-1 operators of [FinishingPass] (the same code the preset's finishing has always used).
 */
class EffectsStage(effects: EffectsParams, presetFinishing: FinishingRecipe, model: DevelopModel, private val frameWidth: Int, private val frameHeight: Int) {
    private val leak = if (effects.leakEnabled) LightLeak.of(effects, frameWidth, frameHeight) else null
    private val presetVignette = presetFinishing.vignette?.takeIf { it.amount != 0.0 }?.let { FinishingPass(it, null, model.experimental, frameWidth, frameHeight) }
    private val userVignette = if (effects.vignetteEnabled) FinishingPass(userVignette(effects), null, model.experimental, frameWidth, frameHeight) else null
    private val presetGrain = presetFinishing.grain?.takeIf { it.amount != 0.0 }?.let { FinishingPass(null, it, model.experimental, frameWidth, frameHeight) }
    private val userGrain = if (effects.grainEnabled) FinishingPass(null, userGrain(effects), model.experimental, frameWidth, frameHeight) else null

    val isEmpty: Boolean get() = leak == null && presetVignette == null && userVignette == null && presetGrain == null && userGrain == null

    /** Applies the stage to rgb (sRGB-encoded, [0, 1]) at frame pixel (x, y). [work] holds ≥ 6 doubles. */
    fun apply(rgb: FloatArray, x: Int, y: Int, work: DoubleArray) {
        leak?.apply(rgb, x, y)
        presetVignette?.apply(rgb, x, y, work)
        userVignette?.apply(rgb, x, y, work)
        presetGrain?.apply(rgb, x, y, work)
        userGrain?.apply(rgb, x, y, work)
    }

    /** The whole frame, or a tile of it at ([originX], [originY]) of a frameWidth × frameHeight frame. */
    fun apply(image: Rgba8Image, originX: Int = 0, originY: Int = 0): Rgba8Image {
        if (isEmpty) return image
        val out = image.pixels.copyOf()
        val rgb = FloatArray(3)
        val work = DoubleArray(6)
        for (row in 0 until image.height) for (column in 0 until image.width) {
            val o = (row * image.width + column) * 4
            for (c in 0 until 3) rgb[c] = (out[o + c].toInt() and 0xff) / 255f
            apply(rgb, originX + column, originY + row, work)
            for (c in 0 until 3) out[o + c] = DevelopRenderer.encode(rgb[c])
        }
        return Rgba8Image(image.width, image.height, out)
    }

    companion object {
        /** [contract] `userVignette`: amount = −amount, midpoint = size, feather = softness, roundness 0, style 1, highlight contrast 0. */
        fun userVignette(e: EffectsParams) = Vignette(-e.vignetteAmount, e.vignetteSize, e.vignetteSoftness, 0.0, 1, 0.0)

        /** [contract] `userGrain`: size × 0.7 (fine), 1.0 (film), 1.5 (coarse), capped at 100; the seed fixed at creation. */
        fun userGrain(e: EffectsParams): Grain {
            val factor = when (e.grainStyle) { "fine" -> 0.7; "coarse" -> 1.5; else -> 1.0 }
            return Grain(e.grainAmount, min(e.grainSize * factor, 100.0), e.grainRoughness, e.grainSeed)
        }
    }
}

/**
 * The light leak (rendering-v2 §6, *provisional*, the prototype's design values): a radial glow at
 * (x, y) % of the frame, rotated by `rotation` about the frame centre (the prototype rotates the whole
 * overlay), screen-blended in encoded sRGB as CSS `mix-blend-mode: screen` does. Core opacity
 * intensity/130, the 30 % ring intensity/400, fading to 0 at 55 % of the farthest-corner distance; colours between
 * the stops are interpolated premultiplied, as CSS gradients are.
 */
// Contract C4 (coordinator decision for rendering-v2 revision 2, 2026-10-04): the stops are fractions
// of the distance from the leak centre to the FARTHEST frame corner, as the prototype's CSS
// `radial-gradient(circle at …)` (farthest-corner) draws them. iOS (bc71828) still measures along the long
// edge; the two differ until iOS follows revision 2.
internal class LightLeak private constructor(
    private val centreX: Double, private val centreY: Double,
    private val frameCentreX: Double, private val frameCentreY: Double,
    private val extent: Double, private val cosine: Double, private val sine: Double,
    private val coreAlpha: Double, private val ringAlpha: Double, private val style: String,
) {
    fun apply(rgb: FloatArray, x: Int, y: Int) {
        val px = x + 0.5 - frameCentreX
        val py = y + 0.5 - frameCentreY
        // The overlay is rotated about the frame centre: sample the unrotated gradient.
        val qx = cosine * px + sine * py + frameCentreX
        val qy = -sine * px + cosine * py + frameCentreY
        val dx = qx - centreX
        val dy = qy - centreY
        val t = sqrt(dx * dx + dy * dy) / extent
        if (t >= END_STOP) return
        var core = colours(style).first
        var ring = colours(style).second
        if (style == "prism") {
            val hue = atan2(dy, dx) * 180 / PI
            core = prismColour(hue)
            ring = prismColour(hue + 40)
        }
        for (c in 0 until 3) {
            val premultiplied = if (t <= RING_STOP) {
                val f = t / RING_STOP
                core[c] / 255 * coreAlpha * (1 - f) + ring[c] / 255 * ringAlpha * f
            } else {
                val f = (t - RING_STOP) / (END_STOP - RING_STOP)
                ring[c] / 255 * ringAlpha * (1 - f)
            }
            // Screen with source alpha: Cb + α·Cs·(1 − Cb).
            val base = rgb[c].toDouble()
            rgb[c] = (base + premultiplied * (1 - base)).coerceIn(0.0, 1.0).toFloat()
        }
    }

    companion object {
        const val RING_STOP = 0.30
        const val END_STOP = 0.55

        fun of(e: EffectsParams, frameWidth: Int, frameHeight: Int): LightLeak? {
            if (e.leakIntensity <= 0) return null
            val theta = e.leakRotation * PI / 180
            val cx = e.leakX / 100 * frameWidth
            val cy = e.leakY / 100 * frameHeight
            // The gradient ray: from the centre to the farthest corner of the (unrotated) overlay box.
            val farthest = max(max(cx, frameWidth - cx), 0.0).let { fx -> sqrt(fx * fx + max(cy, frameHeight - cy).let { it * it }) }
            return LightLeak(
                cx, cy, frameWidth / 2.0, frameHeight / 2.0,
                max(farthest, 1.0), cos(theta), sin(theta),
                min(e.leakIntensity / 130, 1.0), min(e.leakIntensity / 400, 1.0), e.leakStyle,
            )
        }

        /** Core and ring colours (0…255) per style (rendering-v2 §6). */
        fun colours(style: String): Pair<DoubleArray, DoubleArray> = when (style) {
            "amber" -> doubleArrayOf(255.0, 176.0, 64.0) to doubleArrayOf(230.0, 120.0, 40.0)
            "rose" -> doubleArrayOf(255.0, 140.0, 160.0) to doubleArrayOf(220.0, 90.0, 120.0)
            else -> doubleArrayOf(255.0, 150.0, 70.0) to doubleArrayOf(255.0, 90.0, 60.0)
        }

        /** Prism (provisional, as iOS): HSL(h, 100 %, 64 %) ≈ the warm core's saturation and lightness. */
        fun prismColour(degrees: Double): DoubleArray {
            val h = (((degrees % 360) + 360) % 360) / 60
            val l = 0.64
            val chroma = (1 - abs(2 * l - 1))
            val x = chroma * (1 - abs(h % 2 - 1))
            val m = l - chroma / 2
            val rgb = when (h.toInt()) {
                0 -> doubleArrayOf(chroma, x, 0.0)
                1 -> doubleArrayOf(x, chroma, 0.0)
                2 -> doubleArrayOf(0.0, chroma, x)
                3 -> doubleArrayOf(0.0, x, chroma)
                4 -> doubleArrayOf(x, 0.0, chroma)
                else -> doubleArrayOf(chroma, 0.0, x)
            }
            return DoubleArray(3) { (rgb[it] + m) * 255 }
        }
    }
}
