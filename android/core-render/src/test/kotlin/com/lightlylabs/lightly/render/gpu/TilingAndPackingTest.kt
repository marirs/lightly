package com.lightlylabs.lightly.render.gpu

import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.lut.CpuLutPassRenderer
import com.lightlylabs.lightly.render.lut.CpuLutRenderer
import com.lightlylabs.lightly.render.lut.Lut3D
import com.lightlylabs.lightly.render.lut.LutPassPlan
import com.lightlylabs.lightly.render.lut.LutStages
import com.lightlylabs.lightly.render.testing.SyntheticLuts
import java.nio.ByteOrder
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class TilingAndPackingTest {

    // --- Tile plan -------------------------------------------------------------------------------

    private fun assertCoversExactly(plan: TilePlan) {
        val covered = IntArray(plan.frameWidth * plan.frameHeight)
        for (tile in plan.tiles) {
            assertTrue(tile.width in 1..plan.maxTileEdge && tile.height in 1..plan.maxTileEdge, "$tile exceeds ${plan.maxTileEdge}")
            for (y in tile.y until tile.y + tile.height) for (x in tile.x until tile.x + tile.width) covered[y * plan.frameWidth + x]++
        }
        assertTrue(covered.all { it == 1 }, "every pixel exactly once")
    }

    @Test
    fun `48 MP frame splits into 4096 tiles that cover it exactly once`() {
        val plan = TilePlan.plan(8064, 6048)
        assertEquals(
            listOf(Tile(0, 0, 4096, 4096), Tile(4096, 0, 3968, 4096), Tile(0, 4096, 4096, 1952), Tile(4096, 4096, 3968, 1952)),
            plan.tiles,
        )
        assertCoversExactly(plan)
    }

    @Test
    fun `device limit below 4096 shrinks tiles, above 4096 is capped by the spec`() {
        assertEquals(2048, TilePlan.plan(5000, 3000, deviceMaxTileEdge = 2048).maxTileEdge)
        assertEquals(4096, TilePlan.plan(5000, 3000, deviceMaxTileEdge = 16384).maxTileEdge)
        assertCoversExactly(TilePlan.plan(5001, 2999, deviceMaxTileEdge = 1000))
    }

    @Test
    fun `small frame is one tile and invalid sizes are rejected`() {
        assertEquals(listOf(Tile(0, 0, 1, 1)), TilePlan.plan(1, 1).tiles)
        assertFailsWith<IllegalArgumentException> { TilePlan.plan(0, 10) }
        assertFailsWith<IllegalArgumentException> { TilePlan.plan(10, 10, deviceMaxTileEdge = 0) }
    }

    @Test
    fun `tiled render equals whole-frame render`() {
        val frame = Rgba8Image(301, 177, ByteArray(301 * 177 * 4).also { Random(11).nextBytes(it) })
        val plan = LutPassPlan.of(SyntheticLuts.outOfRangeAuto(), 0.9f, SyntheticLuts.strongLook(), 0.7f)
        val tiles = TilePlan.plan(frame.width, frame.height, deviceMaxTileEdge = 64)

        val stitched = ByteArray(frame.pixels.size)
        for (tile in tiles.tiles) {
            TileCopy.insert(stitched, frame.width, tile, CpuLutPassRenderer.render(TileCopy.extract(frame, tile), plan))
        }

        assertContentEquals(CpuLutPassRenderer.render(frame, plan).pixels, stitched)
    }

    // --- LUT texture packing ---------------------------------------------------------------------

    @Test
    fun `packed texel x y z is LUT entry r g b`() {
        val lut = SyntheticLuts.outOfRangeAuto()
        val packed = LutTexturePacking.pack(lut)

        assertTrue(packed.isDirect, "glTexImage3D needs a direct buffer")
        assertEquals(ByteOrder.nativeOrder(), packed.order())
        assertEquals(0, packed.position())
        assertEquals(33 * 33 * 33 * 4, packed.remaining())
        for ((x, y, z) in listOf(Triple(0, 0, 0), Triple(32, 0, 0), Triple(0, 32, 0), Triple(0, 0, 32), Triple(5, 17, 29), Triple(32, 32, 32))) {
            val offset = LutTexturePacking.texelFloatOffset(33, x, y, z)
            val entry = lut.entryIndex(x, y, z)
            for (channel in 0 until 4) assertEquals(lut.rgba[entry + channel], packed.get(offset + channel), "texel ($x,$y,$z)[$channel]")
        }
        // Out-of-range entries survive packing (RGBA32F, no clamping or half-float rounding).
        assertTrue((0 until packed.limit()).any { packed.get(it) > 1f } && (0 until packed.limit()).any { packed.get(it) < 0f })
    }

    @Test
    fun `LUT larger than the device 3D texture limit is rejected before GL`() {
        LutTexturePacking.requireFits(Lut3D.identity(33), maxTexture3dSize = 256)
        assertFailsWith<IllegalArgumentException> { LutTexturePacking.requireFits(Lut3D.identity(33), maxTexture3dSize = 32) }
    }

    // --- Pass plan -------------------------------------------------------------------------------

    @Test
    fun `pass plan omits identity passes and keeps Auto before Look`() {
        val auto = SyntheticLuts.outOfRangeAuto()
        val look = SyntheticLuts.strongLook()

        assertEquals(listOf(auto, look), LutPassPlan.of(auto, 1f, look, 1f).passes)
        assertEquals(listOf(look), LutPassPlan.of(null, 1f, look, 1f).passes, "Auto unavailable: Look still applies")
        assertEquals(listOf(look), LutPassPlan.of(auto, 0f, look, 1f).passes, "Use original: Auto strength 0")
        assertEquals(listOf(auto), LutPassPlan.of(auto, 1f, null, 1f).passes)
        assertTrue(LutPassPlan.of(null, 1f, null, 1f).passes.isEmpty())
    }

    @Test
    fun `two-pass render is the unbaked two-stage oracle, and an empty plan copies`() {
        val frame = Rgba8Image(64, 64, ByteArray(64 * 64 * 4).also { Random(5).nextBytes(it) })
        val auto = SyntheticLuts.outOfRangeAuto()
        val look = SyntheticLuts.strongLook()

        assertContentEquals(
            CpuLutRenderer.applyTwoStage(frame, LutStages(auto, look)).pixels,
            CpuLutPassRenderer.render(frame, LutPassPlan.of(auto, 1f, look, 1f)).pixels,
        )
        assertContentEquals(frame.pixels, CpuLutPassRenderer.render(frame, LutPassPlan.of(null, 1f, null, 1f)).pixels)
    }
}
