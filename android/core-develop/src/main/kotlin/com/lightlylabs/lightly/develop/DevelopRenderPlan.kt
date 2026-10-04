package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.lut.Lut3D

/**
 * One render of the Develop tool (stages auto, develop.global, develop.spatial, and the preset's
 * finishing operators in the effects stage), built from ONE committed or previewed recipe.
 *
 * Amount (`look.strength`, rendering-v2.md §4.2) is folded in here: the Look LUT is blended toward
 * identity, and every amount-like spatial and finishing parameter is multiplied by the strength.
 * Preview and Save copy build their plan with the same [of], so both evaluate the same recipe.
 */
class DevelopRenderPlan private constructor(
    val model: DevelopModel,
    /** Auto pass, strength-blended; null when Auto is off or unavailable. */
    val autoLut: Lut3D?,
    /** Develop global pass, strength-blended; null when no Look renders. */
    val lookLut: Lut3D?,
    val spatial: SpatialRecipe,
    val finishing: FinishingRecipe,
) {
    val hasSpatial: Boolean get() = !spatial.isNeutral
    val hasFinishing: Boolean get() = (finishing.vignette?.amount ?: 0.0) != 0.0 || (finishing.grain?.amount ?: 0.0) != 0.0
    val isIdentity: Boolean get() = autoLut == null && lookLut == null && !hasSpatial && !hasFinishing

    /**
     * The same plan without develop.spatial and finishing: used ONLY for the transient preview while
     * a finger drags the ruler, so a new stop shows within a frame. The committed preview and the
     * export always use the full plan (see docs/v1/slice2-android.md › Rendering).
     */
    fun globalOnly(): DevelopRenderPlan = DevelopRenderPlan(model, autoLut, lookLut, SpatialRecipe.NEUTRAL, FinishingRecipe.NEUTRAL)

    /**
     * The same plan with its finishing operators left out: with Edit or Effects in the recipe they run
     * in the effects stage on the frame, after geometry ([EffectsStage]), not on the source.
     */
    fun withoutFinishing(): DevelopRenderPlan = DevelopRenderPlan(model, autoLut, lookLut, spatial, FinishingRecipe.NEUTRAL)

    companion object {
        fun original(model: DevelopModel) = DevelopRenderPlan(model, null, null, SpatialRecipe.NEUTRAL, FinishingRecipe.NEUTRAL)

        /**
         * Stage 5, `edit.adjust`, as a second Develop pass over the developed pixels: [colourLut] is the
         * Adjust colour bake ([AdjustStage.colourRecipe]), [detail] the Adjust Detail operators
         * ([AdjustStage.detailSpatial]); neither is scaled by the Look's Amount.
         */
        fun adjust(model: DevelopModel, colourLut: Lut3D?, detail: SpatialRecipe) = DevelopRenderPlan(model, null, colourLut, detail, FinishingRecipe.NEUTRAL)

        /**
         * @param lookLut the preset's unblended develop.global bake (null = no Look).
         * @param recipe the preset's recipe, whose spatial and finishing operators are scaled by [strength].
         */
        fun of(model: DevelopModel, autoLut: Lut3D?, autoStrength: Float, lookLut: Lut3D?, recipe: PresetRecipe?, strength: Float): DevelopRenderPlan {
            val auto = autoLut?.takeIf { autoStrength > 0f }?.blendTowardIdentity(autoStrength)
            if (lookLut == null || recipe == null || strength <= 0f) return DevelopRenderPlan(model, auto, null, SpatialRecipe.NEUTRAL, FinishingRecipe.NEUTRAL)
            val s = strength.toDouble()
            return DevelopRenderPlan(model, auto, lookLut.blendTowardIdentity(strength), scaled(recipe.spatial, s), scaled(recipe.finishing, s))
        }

        /** rendering-v2.md §4.2: noise reduction luminance and colour, clarity, texture and sharpening amount × strength. */
        fun scaled(spatial: SpatialRecipe, s: Double) = SpatialRecipe(
            noiseReduction = spatial.noiseReduction?.let { NoiseReduction(it.luminance * s, it.luminanceDetail, it.luminanceContrast, it.color * s, it.colorDetail, it.colorSmoothness) },
            clarity = spatial.clarity * s,
            texture = spatial.texture * s,
            sharpening = spatial.sharpening?.let { Sharpening(it.amount * s, it.radius, it.detail, it.edgeMasking) },
        )

        /** Vignette amount and grain amount × strength. */
        fun scaled(finishing: FinishingRecipe, s: Double) = FinishingRecipe(
            vignette = finishing.vignette?.let { Vignette(it.amount * s, it.midpoint, it.feather, it.roundness, it.style, it.highlightContrast) },
            grain = finishing.grain?.let { Grain(it.amount * s, it.size, it.roughness, it.seed) },
        )
    }
}
