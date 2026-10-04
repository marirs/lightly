package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.lut.Lut3D
import java.util.concurrent.ExecutorService

/** `tools.edit.adjust` as plain values (edit-recipe-v1 `adjust`). */
data class AdjustParams(
    val exposure: Double = 0.0, val contrast: Double = 0.0, val highlights: Double = 0.0, val shadows: Double = 0.0,
    val temp: Double = 0.0, val tint: Double = 0.0, val saturation: Double = 0.0, val vibrance: Double = 0.0,
    val sharpness: Double = 0.0, val clarity: Double = 0.0, val noise: Double = 0.0,
) {
    val hasColour: Boolean get() = listOf(exposure, contrast, highlights, shadows, temp, tint, saturation, vibrance).any { it != 0.0 }
    val hasDetail: Boolean get() = sharpness != 0.0 || clarity != 0.0 || noise != 0.0
    val isNeutral: Boolean get() = !hasColour && !hasDetail
}

/**
 * Stage 5, `edit.adjust` (rendering-v2 §7 and rendering-v2.json `edit.adjust`, provisional mapping):
 * the Adjust sliders mapped onto the calibrated Develop model, rendered as a second Develop pass
 * ([DevelopRenderPlan.adjust]) after the Look, as iOS does.
 *
 * - Colour (`adjustColour`): develop.global with exposure.ev = exposure/50; contrast, highlights,
 *   shadows; white balance temperature = temp, tint = tint; saturation and vibrance; every other
 *   operator neutral. Baked to an N³ LUT like a preset.
 * - Detail (`adjustDetail`): develop.spatial with noise reduction luminance = colour = noise (other
 *   parameters at their defaults), clarity = clarity, sharpening amount = sharpness with radius 1.0,
 *   detail 25, edge masking 0.
 */
object AdjustStage {
    fun colourRecipe(a: AdjustParams): GlobalRecipe = GlobalRecipe(
        whiteBalance = if (a.temp != 0.0 || a.tint != 0.0) WhiteBalance(a.temp, a.tint) else null,
        exposureEv = a.exposure / 50,
        toneSliders = if (a.contrast != 0.0 || a.highlights != 0.0 || a.shadows != 0.0) ToneSliders(a.contrast, a.highlights, a.shadows, 0.0, 0.0) else null,
        vibranceSaturation = if (a.saturation != 0.0 || a.vibrance != 0.0) VibranceSaturation(a.vibrance, a.saturation) else null,
    )

    // Defaults of the parameters the contract leaves at their defaults: the noise-reduction detail,
    // contrast and smoothness of Lightroom's own defaults (50 / 0 / 50), as iOS uses.
    fun detailSpatial(a: AdjustParams): SpatialRecipe = SpatialRecipe(
        noiseReduction = if (a.noise != 0.0) NoiseReduction(a.noise, 50.0, 0.0, a.noise, 50.0, 50.0) else null,
        clarity = a.clarity,
        sharpening = if (a.sharpness != 0.0) Sharpening(a.sharpness, 1.0, 25.0, 0.0) else null,
    )

    private val cache = object : LinkedHashMap<String, Lut3D>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Lut3D>?) = size > 16
    }

    /** The colour bake for these sliders (null when neutral), cached by value: a drag asks for the same few values often. */
    fun colourLut(a: AdjustParams, model: DevelopModel, dimension: Int = Lut3D.CONTRACT_DIMENSION, executor: ExecutorService? = null, parallelism: Int = 1): Lut3D? {
        if (!a.hasColour) return null
        val key = "$dimension:${a.exposure}:${a.contrast}:${a.highlights}:${a.shadows}:${a.temp}:${a.tint}:${a.saturation}:${a.vibrance}"
        synchronized(cache) { cache[key] }?.let { return it }
        val lut = LutBaker.bake(DevelopGlobal(colourRecipe(a), model), dimension, executor, parallelism)
        synchronized(cache) { cache[key] = lut }
        return lut
    }

    /** The Adjust pass plan, or null when the sliders are all at zero. */
    fun plan(a: AdjustParams, model: DevelopModel, dimension: Int = Lut3D.CONTRACT_DIMENSION, executor: ExecutorService? = null, parallelism: Int = 1): DevelopRenderPlan? {
        if (a.isNeutral) return null
        return DevelopRenderPlan.adjust(model, colourLut(a, model, dimension, executor, parallelism), detailSpatial(a))
    }
}
