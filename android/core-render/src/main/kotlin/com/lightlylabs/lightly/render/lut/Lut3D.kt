package com.lightlylabs.lightly.render.lut

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.floor

/**
 * A 3D LUT in the rendering-contract layout (spec §4.2): float32 RGBA, red fastest,
 * `index = r + N·g + N²·b`, domain and codomain sRGB-encoded. Entries may lie outside [0,1]
 * (real Auto LUTs span roughly −0.14…1.48); only stage *inputs* are clamped.
 *
 * Instances are treated as immutable; [rgba] is exposed for zero-copy texture upload and must not
 * be written to by callers.
 */
class Lut3D(val dimension: Int, val rgba: FloatArray) {
    init {
        require(dimension >= 2) { "LUT dimension must be >= 2, was $dimension" }
        require(rgba.size == floatCount(dimension)) {
            "A ${dimension}³ RGBA LUT needs ${floatCount(dimension)} floats, got ${rgba.size}"
        }
    }

    private val scale: Float = (dimension - 1).toFloat()

    /**
     * Exact-grid trilinear sample at (r,g,b) written to `out[outOffset..outOffset+2]`.
     *
     * Boundary rule (§4.2): the input is clamped to [0,1] first (clamp-to-edge, as GPU texture
     * addressing does); there is no extrapolation. `pos = v·(N−1)`, not upstream's `1.0001/(N−1)`.
     *
     * Arithmetic mirrors `ia3dlut.apply_lut_reference` so the CPU path reproduces the golden
     * references bit for bit: positions in float32, fractional parts and corner weights in float64
     * (NumPy promotes `float32 − int64` to float64), weights rounded to float32, then float32
     * multiply-accumulate in the same dr → dg → db corner order.
     */
    fun sample(red: Float, green: Float, blue: Float, out: FloatArray, outOffset: Int = 0) {
        val rPos = clampUnit(red) * scale
        val gPos = clampUnit(green) * scale
        val bPos = clampUnit(blue) * scale
        // A clamped input of exactly 1.0 would index cell N−1; keep the cell valid (fraction becomes 1).
        val rCell = floor(rPos).toInt().coerceIn(0, dimension - 2)
        val gCell = floor(gPos).toInt().coerceIn(0, dimension - 2)
        val bCell = floor(bPos).toInt().coerceIn(0, dimension - 2)
        val rFraction = rPos.toDouble() - rCell
        val gFraction = gPos.toDouble() - gCell
        val bFraction = bPos.toDouble() - bCell

        var outRed = 0f
        var outGreen = 0f
        var outBlue = 0f
        for (dr in 0..1) {
            val wr = if (dr == 1) rFraction else 1.0 - rFraction
            for (dg in 0..1) {
                val wg = if (dg == 1) gFraction else 1.0 - gFraction
                for (db in 0..1) {
                    val wb = if (db == 1) bFraction else 1.0 - bFraction
                    val weight = (wr * wg * wb).toFloat()
                    val base = entryIndex(rCell + dr, gCell + dg, bCell + db)
                    outRed += weight * rgba[base]
                    outGreen += weight * rgba[base + 1]
                    outBlue += weight * rgba[base + 2]
                }
            }
        }
        out[outOffset] = outRed
        out[outOffset + 1] = outGreen
        out[outOffset + 2] = outBlue
    }

    /** Float offset of grid entry (r,g,b) in [rgba]. */
    fun entryIndex(r: Int, g: Int, b: Int): Int = (r + dimension * (g + dimension * b)) * 4

    /**
     * Strength blend toward the exact identity (§4.2): `L_s = I + s·(L − I)`. Alpha stays 1.
     * Strength 1 returns this LUT unchanged (not a recomputed copy), so "full strength" is exact.
     */
    fun blendTowardIdentity(strength: Float): Lut3D {
        require(strength.isFinite() && strength in 0f..1f) { "strength must be in [0,1], was $strength" }
        if (strength == 1f) return this
        val identity = identity(dimension).rgba
        val blended = FloatArray(rgba.size)
        for (i in blended.indices) {
            blended[i] = if (i % 4 == 3) 1f else identity[i] + strength * (rgba[i] - identity[i])
        }
        return Lut3D(dimension, blended)
    }

    fun minValue(): Float = rgbValues().min()

    fun maxValue(): Float = rgbValues().max()

    private fun rgbValues(): Sequence<Float> = rgba.indices.asSequence().filter { it % 4 != 3 }.map { rgba[it] }

    companion object {
        /** Contract dimension (§4.2). */
        const val CONTRACT_DIMENSION = 33

        fun floatCount(dimension: Int): Int = dimension * dimension * dimension * 4

        /** Grid value of index i: exactly i/(N−1) in float32, as `np.linspace(0, 1, N, dtype=float32)`. */
        fun gridValue(index: Int, dimension: Int): Float = (index.toDouble() / (dimension - 1)).toFloat()

        fun identity(dimension: Int = CONTRACT_DIMENSION): Lut3D {
            val rgba = FloatArray(floatCount(dimension))
            for (b in 0 until dimension) for (g in 0 until dimension) for (r in 0 until dimension) {
                val base = (r + dimension * (g + dimension * b)) * 4
                rgba[base] = gridValue(r, dimension)
                rgba[base + 1] = gridValue(g, dimension)
                rgba[base + 2] = gridValue(b, dimension)
                rgba[base + 3] = 1f
            }
            return Lut3D(dimension, rgba)
        }

        /** Reads the contract's `.f32` LUT file format: raw little-endian float32 RGBA, red fastest. */
        fun fromLittleEndianBytes(bytes: ByteArray, dimension: Int = CONTRACT_DIMENSION): Lut3D {
            require(bytes.size == floatCount(dimension) * 4) {
                "A ${dimension}³ RGBA float32 LUT is ${floatCount(dimension) * 4} bytes, got ${bytes.size}"
            }
            val floats = FloatArray(floatCount(dimension))
            ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(floats)
            return Lut3D(dimension, floats)
        }

        /** NaN maps to 0 so a corrupt value cannot poison the trilinear weights. */
        internal fun clampUnit(value: Float): Float = if (value > 0f) (if (value < 1f) value else 1f) else 0f
    }
}
