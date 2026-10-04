package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.image.Rgba8Image
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Slice 4 stages: edit.geometry, edit.adjust (as a second Develop pass) and effects (rendering-v2 §6, §7). */
class EditStagesTest {
    private val model = LookPackFixtures.model

    private fun image(width: Int, height: Int) = Rgba8Image(width, height, ByteArray(width * height * 4) { i ->
        val p = i / 4
        when (i % 4) { 3 -> -1; 0 -> ((p % width) * 255 / width).toByte(); 1 -> ((p / width) * 255 / height).toByte(); else -> ((p * 7) % 251).toByte() }
    })

    private fun pixel(image: Rgba8Image, x: Int, y: Int) = IntArray(3) { image.pixels[(y * image.width + x) * 4 + it].toInt() and 0xff }

    // --- geometry ----------------------------------------------------------------------------------

    @Test
    fun `identity geometry returns the source unchanged`() {
        val source = image(30, 20)
        assertTrue(GeometryTransform(GeometryParams.IDENTITY, 30, 20).render(source) === source)
    }

    @Test
    fun `a quarter turn clockwise swaps the frame and moves the top-left pixel to the top-right`() {
        val source = image(30, 20)
        val t = GeometryTransform(GeometryParams(quarterTurns = 1), 30, 20)
        assertEquals(20 to 30, t.frameWidth to t.frameHeight)
        val frame = t.render(source)
        assertContentEquals(pixel(source, 0, 0), pixel(frame, 19, 0))
        assertContentEquals(pixel(source, 29, 19), pixel(frame, 0, 29))
        val (fx, fy) = t.frameFromSource(0.25, 0.75)
        assertEquals(0.25, fx, 1e-9); assertEquals(0.25, fy, 1e-9)
    }

    @Test
    fun `flips mirror the turned frame`() {
        val source = image(30, 20)
        val h = GeometryTransform(GeometryParams(flipHorizontal = true), 30, 20).render(source)
        val v = GeometryTransform(GeometryParams(flipVertical = true), 30, 20).render(source)
        assertContentEquals(pixel(source, 0, 5), pixel(h, 29, 5))
        assertContentEquals(pixel(source, 4, 0), pixel(v, 4, 19))
    }

    @Test
    fun `straighten zooms by the contract's smallest factor with no empty corner`() {
        val zoom = GeometryTransform.straightenZoom(-3.0, 1600.0, 1067.0)
        val t = Math.toRadians(3.0)
        assertEquals(maxOf(cos(t) + 1067.0 / 1600 * sin(t), cos(t) + 1600.0 / 1067 * sin(t)), zoom, 1e-12)
        val g = GeometryTransform(GeometryParams(straighten = -3.0), 1600, 1067)
        // Every frame corner maps inside the source.
        for ((x, y) in listOf(0.0 to 0.0, 1.0 to 0.0, 0.0 to 1.0, 1.0 to 1.0)) {
            val (sx, sy) = g.sourceFromFrame(x, y)
            assertTrue(sx in -1e-9..1.0 + 1e-9 && sy in -1e-9..1.0 + 1e-9, "corner ($x, $y) → ($sx, $sy)")
        }
    }

    @Test
    fun `perspective keystone narrows the top for positive vertical and leaves no empty area`() {
        val g = GeometryTransform(GeometryParams(perspectiveVertical = 18.0), 1200, 1600)
        for ((x, y) in listOf(0.0 to 0.0, 1.0 to 0.0, 0.0 to 1.0, 1.0 to 1.0, 0.5 to 0.0)) {
            val (sx, sy) = g.sourceFromFrame(x, y)
            assertTrue(sx in -1e-6..1.0 + 1e-6 && sy in -1e-6..1.0 + 1e-6, "($x, $y) → ($sx, $sy)")
        }
        // The top edge is narrower: frame top corners reach further out into the source than bottom ones.
        val topSpan = g.sourceFromFrame(1.0, 0.0).first - g.sourceFromFrame(0.0, 0.0).first
        val bottomSpan = g.sourceFromFrame(1.0, 1.0).first - g.sourceFromFrame(0.0, 1.0).first
        assertTrue(topSpan > bottomSpan)
    }

    @Test
    fun `a fixed crop aspect takes the largest centred rect and the frame has that shape`() {
        val r = GeometryTransform.centredRect(4.0 / 5, 1600, 1067)
        val g = GeometryTransform(GeometryParams(cropX = r[0], cropY = r[1], cropWidth = r[2], cropHeight = r[3]), 1600, 1067)
        assertEquals(4.0 / 5, g.frameWidth.toDouble() / g.frameHeight, 0.002)
        assertEquals(1067, g.frameHeight)
        // Round trip of a content point.
        val (fx, fy) = g.frameFromSource(0.5, 0.4)
        val (sx, sy) = g.sourceFromFrame(fx, fy)
        assertEquals(0.5, sx, 1e-9); assertEquals(0.4, sy, 1e-9)
    }

    @Test
    fun `a frame rendered tile by tile from source regions equals the whole render`() {
        val source = image(64, 48)
        val g = GeometryTransform(GeometryParams(quarterTurns = 1, flipHorizontal = true, straighten = 7.0, perspectiveHorizontal = -30.0, cropX = 0.1, cropY = 0.05, cropWidth = 0.8, cropHeight = 0.9), 64, 48)
        val whole = g.render(source)
        for (tile in listOf(PixelRect(0, 0, 10, 12), PixelRect(10, 20, g.frameWidth - 10, 7))) {
            val region = g.sourceBounds(tile)
            val cut = Rgba8Image(region.width, region.height, ByteArray(region.width * region.height * 4).also { out ->
                for (row in 0 until region.height) System.arraycopy(source.pixels, ((region.y + row) * 64 + region.x) * 4, out, row * region.width * 4, region.width * 4)
            })
            val rendered = g.renderTile(cut, region.x, region.y, tile)
            for (row in 0 until tile.height) for (column in 0 until tile.width) {
                assertContentEquals(pixel(whole, tile.x + column, tile.y + row), pixel(rendered, column, row))
            }
        }
    }

    // --- adjust ------------------------------------------------------------------------------------

    @Test
    fun `Adjust maps onto the Develop model as the contract says`() {
        val a = AdjustParams(exposure = 12.0, contrast = 10.0, highlights = -20.0, shadows = 25.0, temp = 15.0, tint = -4.0, vibrance = 12.0, sharpness = 30.0, clarity = 15.0, noise = 20.0)
        val g = AdjustStage.colourRecipe(a)
        assertEquals(0.24, g.exposureEv, 1e-12)
        assertEquals(-20.0, g.toneSliders!!.highlights)
        assertEquals(15.0, g.whiteBalance!!.temperature)
        assertEquals(12.0, g.vibranceSaturation!!.vibrance)
        val d = AdjustStage.detailSpatial(a)
        assertEquals(20.0, d.noiseReduction!!.luminance); assertEquals(20.0, d.noiseReduction!!.color)
        assertEquals(15.0, d.clarity)
        assertEquals(30.0, d.sharpening!!.amount); assertEquals(1.0, d.sharpening!!.radius); assertEquals(25.0, d.sharpening!!.detail); assertEquals(0.0, d.sharpening!!.edgeMasking)
        assertEquals(null, AdjustStage.plan(AdjustParams(), model))
    }

    @Test
    fun `positive exposure brightens`() {
        val source = image(16, 16)
        val plan = AdjustStage.plan(AdjustParams(exposure = 50.0), model)!!
        val out = DevelopRenderer().render(source, plan)
        assertTrue(out.pixels.indices.filter { it % 4 != 3 }.sumOf { out.pixels[it].toInt() and 0xff } > source.pixels.indices.filter { it % 4 != 3 }.sumOf { source.pixels[it].toInt() and 0xff })
    }

    @Test
    fun `the Adjust pass over a region view equals the whole-frame pass`() {
        val source = image(80, 60)
        val renderer = DevelopRenderer()
        val plan = AdjustStage.plan(AdjustParams(sharpness = 60.0, noise = 40.0, contrast = 20.0), model)!!
        val whole = renderer.render(source, plan)
        val tile = PixelRect(20, 15, 30, 25)
        val apron = renderer.apron(plan, 80, 60)
        val grown = PixelRect(maxOf(0, tile.x - apron), maxOf(0, tile.y - apron), minOf(80, tile.x + tile.width + apron) - maxOf(0, tile.x - apron), minOf(60, tile.y + tile.height + apron) - maxOf(0, tile.y - apron))
        val cut = Rgba8Image(grown.width, grown.height, ByteArray(grown.width * grown.height * 4).also { out ->
            for (row in 0 until grown.height) System.arraycopy(source.pixels, ((grown.y + row) * 80 + grown.x) * 4, out, row * grown.width * 4, grown.width * 4)
        })
        val rendered = renderer.renderView(FrameView(cut, grown.x, grown.y, 80, 60), tile, plan, null)
        for (row in 0 until tile.height) for (column in 0 until tile.width) {
            assertContentEquals(pixel(whole, tile.x + column, tile.y + row), pixel(rendered, column, row))
        }
    }

    // --- effects -----------------------------------------------------------------------------------

    private fun grey(width: Int, height: Int, level: Int = 128) = Rgba8Image(width, height, ByteArray(width * height * 4) { if (it % 4 == 3) -1 else level.toByte() })

    @Test
    fun `no effect is a no-op`() {
        val source = grey(20, 10)
        assertTrue(EffectsStage(EffectsParams(), FinishingRecipe.NEUTRAL, model, 20, 10).apply(source) === source)
    }

    @Test
    fun `the user vignette darkens the corners and not the centre`() {
        val out = EffectsStage(EffectsParams(vignetteEnabled = true), FinishingRecipe.NEUTRAL, model, 60, 40).apply(grey(60, 40))
        assertEquals(128, pixel(out, 30, 20)[0])
        assertTrue(pixel(out, 0, 0)[0] < 128)
    }

    @Test
    fun `user effects map onto the contract operators`() {
        val v = EffectsStage.userVignette(EffectsParams(vignetteAmount = 35.0, vignetteSize = 60.0, vignetteSoftness = 60.0))
        assertEquals(-35.0, v.amount); assertEquals(60.0, v.midpoint); assertEquals(60.0, v.feather); assertEquals(0.0, v.roundness); assertEquals(1, v.style)
        assertEquals(100.0, EffectsStage.userGrain(EffectsParams(grainStyle = "coarse", grainSize = 80.0)).size)
        assertEquals(28.0, EffectsStage.userGrain(EffectsParams(grainStyle = "fine", grainSize = 40.0)).size, 1e-12)
    }

    @Test
    fun `the user grain is repeatable and the same tile by tile`() {
        val params = EffectsParams(grainEnabled = true, grainAmount = 45.0, grainSeed = 77)
        val stage = EffectsStage(params, FinishingRecipe.NEUTRAL, model, 40, 30)
        val whole = stage.apply(grey(40, 30))
        assertContentEquals(whole.pixels, EffectsStage(params, FinishingRecipe.NEUTRAL, model, 40, 30).apply(grey(40, 30)).pixels)
        val tile = stage.apply(grey(10, 8), originX = 13, originY = 9)
        for (row in 0 until 8) for (column in 0 until 10) assertContentEquals(pixel(whole, 13 + column, 9 + row), pixel(tile, column, row))
        assertFalse(whole.pixels.contentEquals(grey(40, 30).pixels))
    }

    @Test
    fun `the light leak brightens near its centre and fades to nothing at 55 percent of the farthest-corner distance`() {
        val params = EffectsParams(leakEnabled = true, leakX = 18.0, leakY = 14.0)
        val out = EffectsStage(params, FinishingRecipe.NEUTRAL, model, 100, 80).apply(grey(100, 80))
        val near = pixel(out, 18, 11)
        assertTrue(near[0] > 128 && near[0] > near[2], "warm screen: ${near.toList()}")
        // Farthest corner from (18, 11.2) is (100, 80): 107 px; 55 % is 59 px. (95, 75) is beyond it.
        assertContentEquals(intArrayOf(128, 128, 128), pixel(out, 95, 75))
    }

    @Test
    fun `the person's vignette is added on top of the preset's, not replacing it`() {
        val preset = FinishingRecipe(vignette = Vignette(-40.0, 50.0, 50.0, 0.0, 1, 0.0))
        val presetOnly = EffectsStage(EffectsParams(), preset, model, 60, 40).apply(grey(60, 40))
        val both = EffectsStage(EffectsParams(vignetteEnabled = true), preset, model, 60, 40).apply(grey(60, 40))
        assertTrue(pixel(both, 0, 0)[0] < pixel(presetOnly, 0, 0)[0])
        assertTrue(abs(pixel(presetOnly, 0, 0)[0] - 128) > 0)
    }
}

/** The light leak (rendering-v2 revision 2, C4) against the shared goldens (`lightLeak`): R, the premultiplied overlay, the output. */
class LightLeakGoldensTest {
    private val dir = java.io.File(checkNotNull(System.getProperty("lightly.renderingGoldensDir")))
    private val index = kotlinx.serialization.json.Json.parseToJsonElement(java.io.File(dir, "index.json").readText()).let { it as kotlinx.serialization.json.JsonObject }

    private fun array(name: String): FloatArray {
        val buffer = java.nio.ByteBuffer.wrap(java.io.File(dir, name).readBytes()).order(java.nio.ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        return FloatArray(buffer.remaining()).also { buffer.get(it) }
    }

    @Test
    fun `light leak equals the goldens`() {
        val cases = (index.getValue("lightLeak") as kotlinx.serialization.json.JsonArray).map { it as kotlinx.serialization.json.JsonObject }
        assertEquals(4, cases.size)
        for (case in cases) {
            fun num(o: kotlinx.serialization.json.JsonObject, k: String) = (o.getValue(k) as kotlinx.serialization.json.JsonPrimitive).content.toDouble()
            val name = (case.getValue("name") as kotlinx.serialization.json.JsonPrimitive).content
            val width = num(case, "width").toInt()
            val height = num(case, "height").toInt()
            val p = case.getValue("params") as kotlinx.serialization.json.JsonObject
            val params = EffectsParams(leakEnabled = true, leakStyle = (p.getValue("style") as kotlinx.serialization.json.JsonPrimitive).content,
                leakIntensity = num(p, "intensity"), leakX = num(p, "x"), leakY = num(p, "y"), leakRotation = num(p, "rotation"))
            val leak = LightLeak.of(params, width, height)!!
            assertEquals(num(case, "farthestCornerPx"), leak.farthestCorner, 1e-4, name)
            val premultiplied = array(((case.getValue("premultiplied") as kotlinx.serialization.json.JsonObject).getValue("file") as kotlinx.serialization.json.JsonPrimitive).content)
            val expected = array(((case.getValue("expected") as kotlinx.serialization.json.JsonObject).getValue("file") as kotlinx.serialization.json.JsonPrimitive).content)
            var worstOverlay = 0.0
            var worstOut = 0.0
            val overlay = DoubleArray(3)
            for (y in 0 until height) for (x in 0 until width) {
                if (!leak.overlay(x, y, overlay)) overlay.fill(0.0)
                val rgb = if (y < height / 3 && x < width / 3) floatArrayOf(0.75f, 0.2f, 0.15f)
                    else floatArrayOf((0.35 + 0.5 * x / width).toFloat(), (0.25 + 0.4 * x / width).toFloat(), (0.2 + 0.3 * y / height).toFloat())
                leak.apply(rgb, x, y)
                for (c in 0 until 3) {
                    val i = (y * width + x) * 3 + c
                    worstOverlay = maxOf(worstOverlay, abs(overlay[c] - premultiplied[i]))
                    worstOut = maxOf(worstOut, abs(rgb[c] - expected[i]).toDouble())
                }
            }
            assertTrue(worstOverlay <= 2e-4, "$name overlay differs by $worstOverlay")
            assertTrue(worstOut <= 2e-4, "$name output differs by $worstOut")
        }
    }
}
