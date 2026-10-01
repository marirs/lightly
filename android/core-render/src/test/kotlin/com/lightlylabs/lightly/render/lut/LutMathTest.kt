package com.lightlylabs.lightly.render.lut

import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.testing.SyntheticLuts
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** Golden-free unit tests for the §4.2 LUT rules. */
class LutMathTest {

    private val identity = Lut3D.identity()

    private fun sample(lut: Lut3D, r: Float, g: Float, b: Float) = FloatArray(3).also { lut.sample(r, g, b, it) }

    @Test
    fun `identity LUT reproduces every 8-bit value exactly`() {
        val random = Random(7)
        val pixels = ByteArray(256 * 4 * 4)
        for (value in 0 until 256) {
            // A grey ramp plus three random colours per level, so all channels and cells are covered.
            for (variant in 0 until 4) {
                val base = (value * 4 + variant) * 4
                pixels[base] = value.toByte()
                pixels[base + 1] = (if (variant == 0) value else random.nextInt(256)).toByte()
                pixels[base + 2] = (if (variant == 0) value else random.nextInt(256)).toByte()
                pixels[base + 3] = 0x7f
            }
        }
        val source = Rgba8Image(256 * 4, 1, pixels)

        assertContentEquals(source.pixels, CpuLutRenderer.apply(source, identity).pixels)
    }

    @Test
    fun `layout is red fastest`() {
        assertEquals(0, identity.entryIndex(0, 0, 0))
        assertEquals(4, identity.entryIndex(1, 0, 0))
        assertEquals(33 * 4, identity.entryIndex(0, 1, 0))
        assertEquals(33 * 33 * 4, identity.entryIndex(0, 0, 1))
        val corner = identity.entryIndex(32, 0, 0)
        assertEquals(listOf(1f, 0f, 0f, 1f), identity.rgba.slice(corner until corner + 4))
    }

    @Test
    fun `stage input is clamped to the cube, never extrapolated`() {
        val auto = SyntheticLuts.outOfRangeAuto()

        assertContentEquals(sample(auto, 1f, 1f, 1f), sample(auto, 1.3f, 1.0001f, 7f))
        assertContentEquals(sample(auto, 0f, 0f, 0f), sample(auto, -0.2f, -1e-6f, Float.NEGATIVE_INFINITY))
        assertContentEquals(sample(auto, 0f, 0f, 0f), sample(auto, Float.NaN, Float.NaN, Float.NaN))
    }

    @Test
    fun `LUT entries may leave 0 to 1 and only the final encode clamps`() {
        val auto = SyntheticLuts.outOfRangeAuto()
        val white = sample(auto, 1f, 1f, 1f)
        val black = sample(auto, 0f, 0f, 0f)
        assertTrue(white.all { it > 1f }, "stage output above 1 is kept: ${white.toList()}")
        assertTrue(black.all { it < 0f }, "stage output below 0 is kept: ${black.toList()}")

        assertEquals(255.toByte(), CpuLutRenderer.encodeUint8(white[0]))
        assertEquals(0.toByte(), CpuLutRenderer.encodeUint8(black[0]))
    }

    @Test
    fun `encode uses the reference rounding`() {
        assertEquals(128, CpuLutRenderer.encodeUint8(0.5f).toInt() and 0xff) // 127.5 + 0.5 = 128
        assertEquals(127, CpuLutRenderer.encodeUint8(127.4f / 255f).toInt() and 0xff)
        assertEquals(0, CpuLutRenderer.encodeUint8(Float.NaN).toInt() and 0xff)
    }

    @Test
    fun `strength blends linearly toward the exact identity`() {
        val auto = SyntheticLuts.outOfRangeAuto()

        assertSame(auto, auto.blendTowardIdentity(1f), "full strength is the LUT itself, bit for bit")
        assertContentEquals(identity.rgba, auto.blendTowardIdentity(0f).rgba)

        val half = auto.blendTowardIdentity(0.5f)
        for (i in auto.rgba.indices) {
            val expected = if (i % 4 == 3) 1f else identity.rgba[i] + 0.5f * (auto.rgba[i] - identity.rgba[i])
            assertEquals(expected, half.rgba[i])
        }
        assertFailsWith<IllegalArgumentException> { auto.blendTowardIdentity(1.01f) }
    }

    @Test
    fun `bake with no Look is the Auto LUT itself`() {
        val auto = SyntheticLuts.outOfRangeAuto()
        assertSame(auto, LutComposition.bake(auto, null))
    }

    @Test
    fun `baked equals two-stage within 2 over 255 with out-of-range Auto entries`() {
        val stages = LutStages(SyntheticLuts.outOfRangeAuto(), SyntheticLuts.strongLook())
        val baked = LutComposition.bake(stages)
        val worst = BakeError.worstOver(stages, baked, Random(0))
        assertTrue(worst <= 2.0, "baked vs two-stage max ${"%.3f".format(worst)}/255 exceeds 2/255")
    }

    @Test
    fun `baking clamps the Auto output before the Look sees it`() {
        // Auto(white) > 1; the Look must see exactly 1.0 (spec §4.2 consequence: highlights clip).
        val auto = SyntheticLuts.outOfRangeAuto()
        val look = SyntheticLuts.strongLook()
        val baked = LutComposition.bake(auto, look)
        val whiteCorner = baked.entryIndex(32, 32, 32)
        assertContentEquals(sample(look, 1f, 1f, 1f), baked.rgba.copyOfRange(whiteCorner, whiteCorner + 3))
    }

    @Test
    fun `LUT file parsing validates size`() {
        assertFailsWith<IllegalArgumentException> { Lut3D.fromLittleEndianBytes(ByteArray(100)) }
        val bytes = java.nio.ByteBuffer.allocate(Lut3D.floatCount(33) * 4).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        identity.rgba.forEach { bytes.putFloat(it) }
        assertContentEquals(identity.rgba, Lut3D.fromLittleEndianBytes(bytes.array()).rgba)
    }
}

/** Shared measurement for the bake tolerance tests (unit and golden). */
internal object BakeError {
    /**
     * Max |two-stage − baked| in 8-bit units over 20 000 in-range and 5 000 out-of-range inputs, the
     * same mix as test_lut_composition.py. Both sides are clamped once at the end (O4).
     */
    fun worstOver(stages: LutStages, baked: Lut3D, random: Random): Double {
        val twoStage = FloatArray(3)
        val bakedOut = FloatArray(3)
        var worst = 0.0
        repeat(25_000) { index ->
            val (low, high) = if (index < 20_000) 0f to 1f else -0.2f to 1.3f
            val r = low + random.nextFloat() * (high - low)
            val g = low + random.nextFloat() * (high - low)
            val b = low + random.nextFloat() * (high - low)
            stages.auto.sample(r, g, b, twoStage)
            stages.look?.sample(twoStage[0], twoStage[1], twoStage[2], twoStage)
            baked.sample(r, g, b, bakedOut)
            for (channel in 0 until 3) {
                val diff = kotlin.math.abs(Lut3D.clampUnit(twoStage[channel]) - Lut3D.clampUnit(bakedOut[channel])) * 255.0
                if (diff > worst) worst = diff
            }
        }
        return worst
    }

    data class Exhaustive(val floatMax: Double, val encodedMax: Int, val coloursOver2: Long)

    /** Baked vs two-stage over all 256³ 8-bit input colours, before and after the O4 encode. */
    fun overAll8BitInputs(stages: LutStages, baked: Lut3D): Exhaustive {
        val twoStage = FloatArray(3)
        val bakedOut = FloatArray(3)
        var floatMax = 0.0
        var encodedMax = 0
        var coloursOver2 = 0L
        for (b in 0 until 256) for (g in 0 until 256) for (r in 0 until 256) {
            val red = r / 255f
            val green = g / 255f
            val blue = b / 255f
            stages.auto.sample(red, green, blue, twoStage)
            stages.look?.sample(twoStage[0], twoStage[1], twoStage[2], twoStage)
            baked.sample(red, green, blue, bakedOut)
            var colourMax = 0
            for (channel in 0 until 3) {
                val floatDiff = kotlin.math.abs(Lut3D.clampUnit(twoStage[channel]) - Lut3D.clampUnit(bakedOut[channel])) * 255.0
                if (floatDiff > floatMax) floatMax = floatDiff
                val encodedDiff = kotlin.math.abs(
                    (CpuLutRenderer.encodeUint8(twoStage[channel]).toInt() and 0xff) -
                        (CpuLutRenderer.encodeUint8(bakedOut[channel]).toInt() and 0xff),
                )
                if (encodedDiff > colourMax) colourMax = encodedDiff
            }
            if (colourMax > encodedMax) encodedMax = colourMax
            if (colourMax > 2) coloursOver2++
        }
        return Exhaustive(floatMax, encodedMax, coloursOver2)
    }
}
