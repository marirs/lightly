package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.lut.Lut3D
import kotlinx.serialization.json.JsonObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertTrue

/**
 * develop.spatial and finishing against reference_model.py (vectors made by
 * src/test/resources/spatial/generate.py), and the tile invariant: a frame rendered tile by tile
 * equals the frame rendered whole, byte for byte.
 */
class DevelopRendererTest {
    private val model = LookPackFixtures.model
    private val directory = File(checkNotNull(System.getProperty("lightly.spatialFixturesDir")))

    private val nr = NoiseReduction(60.0, 40.0, 20.0, 50.0, 50.0, 60.0)
    private val sharp = Sharpening(80.0, 1.2, 30.0, 40.0)
    private fun vignette(style: Int, amount: Double = -35.0, roundness: Double = 20.0) = Vignette(amount, 40.0, 60.0, roundness, style, 30.0)
    private val grain = Grain(40.0, 30.0, 45.0, 1571121214L)

    private fun recipe(spatial: SpatialRecipe = SpatialRecipe.NEUTRAL, finishing: FinishingRecipe = FinishingRecipe.NEUTRAL) =
        PresetRecipe(GlobalRecipe.NEUTRAL, spatial, finishing, JsonObject(emptyMap()))

    private val cases: Map<String, Pair<PresetRecipe, Float>> = mapOf(
        "noise-reduction" to (recipe(SpatialRecipe(noiseReduction = nr)) to 1f),
        "clarity-texture" to (recipe(SpatialRecipe(clarity = 45.0, texture = 30.0)) to 1f),
        "clarity-negative" to (recipe(SpatialRecipe(clarity = -60.0)) to 1f),
        "sharpening" to (recipe(SpatialRecipe(sharpening = sharp)) to 1f),
        "vignette-style1" to (recipe(finishing = FinishingRecipe(vignette = vignette(1))) to 1f),
        "vignette-style2" to (recipe(finishing = FinishingRecipe(vignette = vignette(2))) to 1f),
        "vignette-style3" to (recipe(finishing = FinishingRecipe(vignette = vignette(3))) to 1f),
        "vignette-lighten" to (recipe(finishing = FinishingRecipe(vignette = vignette(1, amount = 40.0, roundness = -50.0))) to 1f),
        "grain" to (recipe(finishing = FinishingRecipe(grain = grain)) to 1f),
        "combined-strength-0.7" to (recipe(SpatialRecipe(nr, 45.0, 30.0, sharp), FinishingRecipe(vignette(1), grain)) to 0.7f),
    )

    private fun input(width: Int, height: Int): Rgba8Image {
        val rgb = File(directory, "input-${width}x$height.u8").readBytes()
        val rgba = ByteArray(width * height * 4)
        for (i in 0 until width * height) {
            rgba[i * 4] = rgb[i * 3]; rgba[i * 4 + 1] = rgb[i * 3 + 1]; rgba[i * 4 + 2] = rgb[i * 3 + 2]; rgba[i * 4 + 3] = -1
        }
        return Rgba8Image(width, height, rgba)
    }

    private fun expected(name: String, width: Int, height: Int): DoubleArray {
        val buffer = ByteBuffer.wrap(File(directory, "$name-${width}x$height.u16").readBytes()).order(ByteOrder.LITTLE_ENDIAN)
        return DoubleArray(width * height * 3) { (buffer.getShort(it * 2).toInt() and 0xFFFF) / 65535.0 }
    }

    private fun plan(recipe: PresetRecipe, strength: Float) =
        DevelopRenderPlan.of(model, null, 0f, Lut3D.identity(), recipe, strength)

    @Test
    fun `small frame matches the reference within 8-bit rounding`() {
        // At 96 px clarity's sigma (5 px) is blurred exactly, so every operator is checked without approximation.
        compareAll(96, 64, defaultTolerance = 2.5e-3, clarityTolerance = 2.5e-3)
    }

    @Test
    fun `larger frame matches the reference with clarity's low-resolution blur`() {
        compareAll(192, 128, defaultTolerance = 2.5e-3, clarityTolerance = 6e-3)
    }

    private fun compareAll(width: Int, height: Int, defaultTolerance: Double, clarityTolerance: Double) {
        val source = input(width, height)
        val renderer = DevelopRenderer()
        val failures = mutableListOf<String>()
        for ((name, case) in cases) {
            val rendered = renderer.render(source, plan(case.first, case.second))
            val reference = expected(name, width, height)
            var worst = 0.0
            var sum = 0.0
            for (i in 0 until width * height) for (c in 0 until 3) {
                val diff = abs((rendered.pixels[i * 4 + c].toInt() and 0xff) / 255.0 - reference[i * 3 + c])
                worst = maxOf(worst, diff)
                sum += diff
            }
            val tolerance = if (name.startsWith("clarity") || name.startsWith("combined")) clarityTolerance else defaultTolerance
            println("$name ${width}x$height: worst ${"%.2e".format(worst)}, mean ${"%.2e".format(sum / (width * height * 3))}")
            if (worst > tolerance) failures += "$name: worst $worst > $tolerance"
        }
        assertTrue(failures.isEmpty(), failures.joinToString("\n"))
    }

    @Test
    fun `a frame read by region gives the same clarity base and tiles as the whole image`() {
        // Save copy reads its frame by region (FrameSource, 2026-10-07); every float and byte must match.
        val source = input(192, 128)
        val (recipe, strength) = cases.getValue("combined-strength-0.7")
        val plan = plan(recipe, strength)
        val frame = com.lightlylabs.lightly.render.image.ImageFrameSource(source)
        val pool = Executors.newFixedThreadPool(3)
        try {
            val renderer = DevelopRenderer(pool, parallelism = 3)
            val base = renderer.clarityBase(source, plan)!!
            // The streamed base is checked through the tiles: clarity reads it at every pixel.
            val streamed = renderer.clarityBase(frame, plan)!!
            for (ty in 0 until 128 step 45) for (tx in 0 until 192 step 70) {
                val tile = PixelRect(tx, ty, minOf(70, 192 - tx), minOf(45, 128 - ty))
                assertContentEquals(renderer.renderTile(source, tile, plan, base).pixels, renderer.renderTile(frame, tile, plan, streamed).pixels)
            }
        } finally {
            pool.shutdown()
        }
    }

    @Test
    fun `tiles with their apron render exactly like the whole frame`() {
        val source = input(192, 128)
        val (recipe, strength) = cases.getValue("combined-strength-0.7")
        val plan = plan(recipe, strength)
        val pool = Executors.newFixedThreadPool(3)
        try {
            val renderer = DevelopRenderer(pool, parallelism = 3)
            val whole = renderer.render(source, plan)
            val base = renderer.clarityBase(source, plan)
            val tiled = ByteArray(whole.pixels.size)
            for (ty in 0 until 128 step 45) for (tx in 0 until 192 step 70) {
                val tile = PixelRect(tx, ty, minOf(70, 192 - tx), minOf(45, 128 - ty))
                val part = renderer.renderTile(source, tile, plan, base)
                for (row in 0 until tile.height) System.arraycopy(part.pixels, row * tile.width * 4, tiled, ((ty + row) * 192 + tx) * 4, tile.width * 4)
            }
            assertContentEquals(whole.pixels, tiled)
        } finally {
            pool.shutdown()
        }
    }

    @Test
    fun `a neutral plan returns the source unchanged`() {
        val source = input(96, 64)
        val rendered = DevelopRenderer().render(source, DevelopRenderPlan.original(model))
        assertContentEquals(source.pixels, rendered.pixels)
    }
}
