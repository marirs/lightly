package com.lightlylabs.lightly.render.lut

/**
 * The colour stages of the operator chain (spec §4.1): O1 Auto LUT, then O2 Look LUT, each already
 * strength-blended toward identity. `look == null` means "Auto only" (Invariant R: at most one Look).
 */
class LutStages(val auto: Lut3D, val look: Lut3D?) {
    init {
        require(look == null || look.dimension == auto.dimension) { "Auto and Look LUTs must share a dimension" }
    }

    /** The stages to apply in order, for the unbaked (two-stage) path. */
    fun inOrder(): List<Lut3D> = listOfNotNull(auto, look)

    companion object {
        fun of(autoLut: Lut3D, autoStrength: Float, lookLut: Lut3D?, lookStrength: Float): LutStages =
            LutStages(autoLut.blendTowardIdentity(autoStrength), lookLut?.blendTowardIdentity(lookStrength))
    }
}

object LutComposition {
    /**
     * Bakes O1+O2 into one LUT (§4.1): `B(g) = L_look(clamp(L_auto(g)))` sampled on the grid, then
     * applied as `B(clamp(x))`. The inner clamp is the §4.2 boundary rule ([Lut3D.sample] clamps
     * its input), so baked and two-stage rendering use one rule. Contract tolerance vs the
     * two-stage path: max ≤ 2/255.
     *
     * With no Look the Auto LUT is returned as-is: baking against identity would only add error.
     */
    fun bake(stages: LutStages): Lut3D {
        val look = stages.look ?: return stages.auto
        val auto = stages.auto
        val dimension = auto.dimension
        val baked = FloatArray(Lut3D.floatCount(dimension))
        val autoOut = FloatArray(3)
        for (b in 0 until dimension) for (g in 0 until dimension) for (r in 0 until dimension) {
            auto.sample(
                Lut3D.gridValue(r, dimension),
                Lut3D.gridValue(g, dimension),
                Lut3D.gridValue(b, dimension),
                autoOut,
            )
            val base = auto.entryIndex(r, g, b)
            look.sample(autoOut[0], autoOut[1], autoOut[2], baked, base)
            baked[base + 3] = 1f
        }
        return Lut3D(dimension, baked)
    }

    fun bake(auto: Lut3D, look: Lut3D?): Lut3D = bake(LutStages(auto, look))
}
