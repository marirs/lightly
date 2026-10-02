package com.lightlylabs.lightly.render.lut

import com.lightlylabs.lightly.render.image.Rgba8Image

/**
 * CPU reference for the LUT stages of the operator chain. It is the correctness oracle the GLES
 * renderer (M3) is tested against, not a production path: it is single-threaded and far too slow
 * for 12–48 MP exports (spec §8 rejects CPU rendering for that reason).
 */
object CpuLutRenderer {

    /**
     * Applies [luts] in order to every pixel. Each stage clamps its own input (§4.2), so values
     * between stages are kept in float and may leave [0,1]. The only other clamp is the final
     * encode (O4). Alpha is passed through unchanged.
     */
    fun apply(source: Rgba8Image, luts: List<Lut3D>): Rgba8Image {
        require(luts.isNotEmpty()) { "At least one LUT stage is required" }
        val src = source.pixels
        val dst = ByteArray(src.size)
        val color = FloatArray(3)
        for (pixel in 0 until source.pixelCount) {
            val base = pixel * Rgba8Image.CHANNELS
            color[0] = decodeUint8(src[base])
            color[1] = decodeUint8(src[base + 1])
            color[2] = decodeUint8(src[base + 2])
            for (lut in luts) lut.sample(color[0], color[1], color[2], color)
            dst[base] = encodeUint8(color[0])
            dst[base + 1] = encodeUint8(color[1])
            dst[base + 2] = encodeUint8(color[2])
            dst[base + 3] = src[base + 3]
        }
        return Rgba8Image(source.width, source.height, dst)
    }

    fun apply(source: Rgba8Image, lut: Lut3D): Rgba8Image = apply(source, listOf(lut))

    /** Two-stage (unbaked) render of [stages]. */
    fun applyTwoStage(source: Rgba8Image, stages: LutStages): Rgba8Image = apply(source, stages.inOrder())

    /** Baked render of [stages]: one LUT, one sample per pixel. */
    fun applyBaked(source: Rgba8Image, stages: LutStages): Rgba8Image = apply(source, LutComposition.bake(stages))

    /** `byte / 255` in float32, as `rgb.astype(float32) / 255.0` in the reference. */
    fun decodeUint8(value: Byte): Float = (value.toInt() and 0xff) / 255f

    /**
     * O4: the single final clamp, with the reference rounding (`x·255 + 0.5`, clamp, truncate;
     * `ia3dlut.to_uint8`). NaN encodes as 0.
     */
    fun encodeUint8(value: Float): Byte {
        val scaled = value * 255f + 0.5f
        val clamped = if (scaled > 0f) (if (scaled < 255f) scaled else 255f) else 0f
        return clamped.toInt().toByte()
    }
}
