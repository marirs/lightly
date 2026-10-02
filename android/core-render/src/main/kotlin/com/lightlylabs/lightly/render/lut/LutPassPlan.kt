package com.lightlylabs.lightly.render.lut

import com.lightlylabs.lightly.render.image.Rgba8Image

/**
 * The colour passes of one render (spec §4.1, revised): O1 Auto, then O2 Look, applied as
 * **separate** LUT passes. Baking them into one LUT is not allowed by default, because the §4.2
 * clamp between the stages cannot be represented inside a 33³ grid cell (up to 6/255 on golden
 * LUTs; see docs/m2/android-foundation.md §4).
 *
 * Each pass is already strength-blended. A pass is omitted when it is the identity:
 * - Auto is omitted when it is unavailable (Codex M2 finding 4: "Auto off") or at strength 0.
 * - Look is omitted when there is no Look (Invariant R: at most one).
 */
class LutPassPlan private constructor(val passes: List<Lut3D>) {
    init {
        require(passes.size <= MAX_PASSES) { "At most $MAX_PASSES LUT passes (Auto, Look), got ${passes.size}" }
        require(passes.map { it.dimension }.distinct().size <= 1) { "All passes must share a LUT dimension" }
    }

    companion object {
        const val MAX_PASSES = 2

        fun of(autoLut: Lut3D?, autoStrength: Float, lookLut: Lut3D?, lookStrength: Float): LutPassPlan {
            val auto = autoLut?.takeIf { autoStrength > 0f }?.blendTowardIdentity(autoStrength)
            val look = lookLut?.takeIf { lookStrength > 0f }?.blendTowardIdentity(lookStrength)
            return LutPassPlan(listOfNotNull(auto, look))
        }

        /** For callers that already hold strength-blended LUTs (tests, thumbnails). */
        fun ofBlended(vararg passes: Lut3D): LutPassPlan = LutPassPlan(passes.toList())
    }
}

/**
 * Applies a [LutPassPlan] to RGBA8 pixels. Implementations: [CpuLutPassRenderer] (the oracle) and
 * the GLES renderer in :core-render-gl (GPU execution PENDING on physical devices).
 *
 * Contract every implementation must meet: each pass clamps its input to [0,1]; values between
 * passes are NOT quantised to 8 bits; the single final clamp happens at encode; alpha passes
 * through unchanged.
 */
interface LutPassRenderer {
    fun render(source: Rgba8Image, plan: LutPassPlan): Rgba8Image
}

/** CPU reference implementation; the oracle the GPU path is validated against. */
object CpuLutPassRenderer : LutPassRenderer {
    override fun render(source: Rgba8Image, plan: LutPassPlan): Rgba8Image =
        if (plan.passes.isEmpty()) Rgba8Image(source.width, source.height, source.pixels.copyOf())
        else CpuLutRenderer.apply(source, plan.passes)
}
