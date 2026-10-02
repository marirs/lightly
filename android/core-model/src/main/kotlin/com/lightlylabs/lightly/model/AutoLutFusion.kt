package com.lightlylabs.lightly.model

import com.lightlylabs.lightly.render.lut.Lut3D
import com.lightlylabs.lightly.session.AutoGuardrail
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The model's basis LUTs (spec §4.6, `basis_luts_f32.bin`): N basis LUTs in the contract layout,
 * concatenated. The fused Auto LUT is `L = Σ wᵢ·Bᵢ`.
 */
class BasisLuts(val luts: List<Lut3D>) {
    init {
        require(luts.isNotEmpty()) { "At least one basis LUT is required" }
        require(luts.all { it.dimension == luts.first().dimension }) { "Basis LUTs must share a dimension" }
    }

    val dimension: Int get() = luts.first().dimension

    /** Fuses with raw linear [weights]; alpha is forced to 1 (as `export_lut_rgba_float32`). */
    fun fuse(weights: FloatArray): Lut3D {
        require(weights.size == luts.size) { "Expected ${luts.size} weights, got ${weights.size}" }
        val fused = FloatArray(Lut3D.floatCount(dimension))
        for (i in fused.indices) {
            if (i % 4 == 3) {
                fused[i] = 1f
                continue
            }
            var sum = 0f
            for (basis in luts.indices) sum += weights[basis] * luts[basis].rgba[i]
            fused[i] = sum
        }
        return Lut3D(dimension, fused)
    }

    companion object {
        fun fromLittleEndianBytes(bytes: ByteArray, count: Int = 3, dimension: Int = Lut3D.CONTRACT_DIMENSION): BasisLuts {
            val floatsPerLut = Lut3D.floatCount(dimension)
            require(bytes.size == count * floatsPerLut * 4) {
                "Expected ${count * floatsPerLut * 4} bytes for $count basis LUTs, got ${bytes.size}"
            }
            val all = FloatArray(count * floatsPerLut)
            ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(all)
            return BasisLuts(List(count) { index -> Lut3D(dimension, all.copyOfRange(index * floatsPerLut, (index + 1) * floatsPerLut)) })
        }
    }
}

/** Applies the versioned guardrail named in an AutoResult. Unknown versions cannot exist (enum). */
object AutoGuardrails {
    fun apply(guardrail: AutoGuardrail?, lut: Lut3D): Lut3D = when (guardrail) {
        null -> lut
        AutoGuardrail.ENDPOINT_V1 -> endpointV1(lut)
    }

    /**
     * EXPERIMENTAL (M1), port of `ia3dlut.endpoint_guardrail`. The research model often maps black
     * below 0 (crushed shadows after the clamp) and white below 1 (grey skies). Each output channel
     * is rescaled affinely so the black corner maps max(black, 0) → 0 and the white corner
     * min(white, 1) → 1. Only out-of-range endpoints move; a channel with black ≥ 0 and white ≥ 1 is
     * untouched. Frozen as "endpoint-v1": changing this math requires a new enum value so saved
     * edits keep rendering identically (spec §4.6).
     */
    private fun endpointV1(lut: Lut3D): Lut3D {
        val dimension = lut.dimension
        val source = lut.rgba
        val out = source.copyOf()
        val blackBase = lut.entryIndex(0, 0, 0)
        val whiteBase = lut.entryIndex(dimension - 1, dimension - 1, dimension - 1)
        for (channel in 0 until 3) {
            val black = source[blackBase + channel]
            val white = source[whiteBase + channel]
            val low = minOf(black, 0f)
            val high = if (white < 1f) white else 1f
            if (low < 0f || white < 1f) {
                val range = high - low
                var i = channel
                while (i < source.size) {
                    out[i] = (source[i] - low) / range
                    i += 4
                }
            }
        }
        return Lut3D(dimension, out)
    }
}
