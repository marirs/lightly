package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.image.Rgba8Image
import org.junit.Assume.assumeTrue
import java.io.File
import java.security.MessageDigest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** rendering-v2 revision 8 §Light leak (owner 2026-10-11): a leak-pack image screened over the frame. */
class LeakImageOverlayTest {
    private val model = LookPackFixtures.model
    private val leakId = "leak-edf0a0ecd85d"

    private fun solid(width: Int, height: Int, r: Int, g: Int, b: Int) =
        Rgba8Image(width, height, ByteArray(width * height * 4) { when (it % 4) { 0 -> r.toByte(); 1 -> g.toByte(); 2 -> b.toByte(); else -> -1 } })

    private fun grey(width: Int, height: Int, level: Int = 128) = solid(width, height, level, level, level)

    /** A 2:1 leak: red left half, green right half. */
    private fun halves(width: Int = 100, height: Int = 50) = Rgba8Image(width, height, ByteArray(width * height * 4) {
        val x = (it / 4) % width
        when (it % 4) { 0 -> if (x < width / 2) -1 else 0; 1 -> if (x < width / 2) 0 else -1; 2 -> 0; else -> -1 }.toByte()
    })

    private fun params(image: Rgba8Image, intensity: Double = 100.0, x: Double = 50.0, y: Double = 50.0, rotation: Double = 0.0) =
        EffectsParams(leakEnabled = true, leakStyle = leakId, leakIntensity = intensity, leakX = x, leakY = y, leakRotation = rotation, leakImage = image)

    private fun pixel(image: Rgba8Image, x: Int, y: Int) = IntArray(3) { image.pixels[(y * image.width + x) * 4 + it].toInt() and 0xff }

    @Test
    fun `leak ids are image styles, the four drawn styles are not`() {
        assertTrue(LeakImageOverlay.isLeakImageStyle(leakId))
        listOf("warm", "amber", "rose", "prism", "leak-EDF0A0ECD85D", "leak-edf0").forEach { assertFalse(LeakImageOverlay.isLeakImageStyle(it), it) }
    }

    @Test
    fun `intensity 0 leaves the frame untouched`() {
        val source = grey(40, 30)
        val stage = EffectsStage(params(solid(16, 9, 255, 200, 100), intensity = 0.0), FinishingRecipe.NEUTRAL, model, 40, 30)
        assertTrue(stage.isEmpty)
        assertTrue(stage.apply(source) === source)
    }

    @Test
    fun `black leak pixels add no light`() {
        val source = Rgba8Image(40, 30, ByteArray(40 * 30 * 4) { if (it % 4 == 3) -1 else (it * 7 % 251).toByte() })
        val out = EffectsStage(params(solid(16, 9, 0, 0, 0)), FinishingRecipe.NEUTRAL, model, 40, 30).apply(source)
        assertContentEquals(source.pixels, out.pixels)
    }

    @Test
    fun `the leak is screened at intensity on sRGB-encoded values`() {
        val overlay = assertNotNull(LeakImageOverlay.of(solid(16, 9, 200, 100, 50), params(solid(16, 9, 200, 100, 50), intensity = 50.0), 32, 18))
        val rgb = floatArrayOf(0.5f, 0.25f, 0.8f)
        overlay.apply(rgb, 10, 7)
        val light = doubleArrayOf(200 / 255.0 * 0.5, 100 / 255.0 * 0.5, 50 / 255.0 * 0.5)
        val input = doubleArrayOf(0.5, 0.25, 0.8)
        for (c in 0 until 3) assertEquals(1 - (1 - input[c]) * (1 - light[c]), rgb[c].toDouble(), 1e-6, "channel $c")
    }

    @Test
    fun `the image covers the frame centred at x, y and turns clockwise about that centre`() {
        val leak = halves()                    // 100 × 50
        val black = floatArrayOf(0f, 0f, 0f)
        fun at(px: Int, py: Int, x: Double = 50.0, y: Double = 50.0, rotation: Double = 0.0): FloatArray {
            val rgb = black.copyOf()
            LeakImageOverlay.of(leak, params(leak, x = x, y = y, rotation = rotation), 200, 100)!!.apply(rgb, px, py)
            return rgb
        }
        // Aspect fill on 200 × 100: s = 2, the whole image exactly covers the frame. (Samples stay inside the 8 % edge fade.)
        assertContentEquals(floatArrayOf(1f, 0f, 0f), at(30, 50))
        assertContentEquals(floatArrayOf(0f, 1f, 0f), at(170, 50))
        // Half a turn swaps the halves.
        assertContentEquals(floatArrayOf(0f, 1f, 0f), at(30, 50, rotation = 180.0))
        assertContentEquals(floatArrayOf(1f, 0f, 0f), at(170, 50, rotation = 180.0))
        // A quarter turn clockwise brings the left (red) half to the top; the turned image is 100 px wide, so x = 10 is outside it.
        assertContentEquals(floatArrayOf(1f, 0f, 0f), at(100, 10, rotation = 90.0))
        assertContentEquals(floatArrayOf(0f, 1f, 0f), at(100, 90, rotation = 90.0))
        assertContentEquals(black, at(10, 50, rotation = 90.0))
        // Centred at x = 25 % (50 px): frame x = 60 is right of the centre, in the green half; off the right edge there is no light.
        assertContentEquals(floatArrayOf(1f, 0f, 0f), at(10, 50, x = 25.0))
        assertContentEquals(floatArrayOf(0f, 1f, 0f), at(60, 50, x = 25.0))
        assertContentEquals(black, at(190, 50, x = 25.0))
    }

    @Test
    fun `the light fades over the last 8 percent of each image side - almost none in the outer 1 percent, full at the middle`() {
        val white = solid(100, 50, 255, 255, 255)
        // 100 × 50 on a 100 × 50 frame, centred: frame pixel = image pixel (s = 1).
        val overlay = LeakImageOverlay.of(white, params(white), 100, 50)!!
        val light = DoubleArray(3)
        // x = 0 → u = 0.5 / 100 = 0.5 % of the width (outer 1 %); y = 25 → v at 51 %: f = smoothstep(0, 0.08, 0.005) ≈ 0.011.
        assertTrue(overlay.light(0, 25, light)); assertTrue(light[0] < 0.02, "edge light ${light[0]}")
        // The middle (50 %, 51 %) gets the image at full strength.
        assertTrue(overlay.light(49, 25, light)); assertEquals(1.0, light[0], 1e-9)
        // At 4 % in (half the fade) the smoothstep gives one half.
        assertEquals(0.5, LeakImageOverlay.edgeFade(0.04), 1e-9)
        assertEquals(1.0, LeakImageOverlay.edgeFade(0.08), 1e-9)
        assertEquals(0.0, LeakImageOverlay.edgeFade(0.0), 1e-9)
    }

    @Test
    fun `a tile of the frame (Save copy) equals the same pixels of the whole frame (preview)`() {
        val gradient = Rgba8Image(64, 36, ByteArray(64 * 36 * 4) { i -> val p = i / 4; when (i % 4) { 0 -> (p % 64 * 4).toByte(); 1 -> (p / 64 * 7).toByte(); 2 -> 90; else -> -1 } })
        val p = params(gradient, intensity = 70.0, x = 40.0, y = 60.0, rotation = 33.0)
        val whole = EffectsStage(p, FinishingRecipe.NEUTRAL, model, 40, 30).apply(grey(40, 30))
        val tile = EffectsStage(p, FinishingRecipe.NEUTRAL, model, 40, 30).apply(grey(10, 8), originX = 13, originY = 9)
        for (row in 0 until 8) for (column in 0 until 10) assertContentEquals(pixel(whole, 13 + column, 9 + row), pixel(tile, column, row))
        assertFalse(whole.pixels.contentEquals(grey(40, 30).pixels))
    }

    @Test
    fun `a leak id without its image adds no light, and the drawn styles still render as before`() {
        val source = grey(40, 30)
        val missing = EffectsStage(EffectsParams(leakEnabled = true, leakStyle = leakId, leakIntensity = 80.0), FinishingRecipe.NEUTRAL, model, 40, 30)
        assertTrue(missing.isEmpty)
        val drawn = EffectsParams(leakEnabled = true, leakStyle = "amber", leakIntensity = 80.0, leakX = 20.0, leakY = 20.0)
        assertNotNull(LightLeak.of(drawn, 40, 30))
        assertFalse(EffectsStage(drawn, FinishingRecipe.NEUTRAL, model, 40, 30).apply(source).pixels.contentEquals(source.pixels))
        assertNull(LeakImageOverlay.of(solid(4, 4, 255, 255, 255), drawn.copy(leakIntensity = 0.0), 40, 30))
    }
}

/** The built leak pack (shared/leaks/out, git-ignored) read in place: manifest, every image and thumbnail, digests and sizes. */
class LeakPackTest {
    private val directory = File(checkNotNull(System.getProperty("lightly.leakPackDir")) { "run through Gradle" })

    private fun sha256(file: File) = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }

    @Test
    fun `every leak in the built pack is present with the manifest's SHA-256 and size`() {
        val manifest = directory.resolve("leaks.json")
        assumeTrue("no leak pack at $directory (build it with shared/leaks/build_leaks.py)", manifest.isFile)
        val pack = LeakPack.parse(manifest.readText())
        assertTrue(pack.leaks.isNotEmpty())
        for (leak in pack.leaks) {
            val image = directory.resolve(leak.image)
            assertTrue(image.isFile, "${leak.image} is missing")
            assertEquals(leak.imageSha256, sha256(image), leak.id)
            val decoded = assertNotNull(javax.imageio.ImageIO.read(image), leak.id)
            assertEquals(leak.width to leak.height, decoded.width to decoded.height, leak.id)
            assertTrue(directory.resolve(leak.thumbnail).isFile, "${leak.thumbnail} is missing")
        }
        assertEquals(pack.leaks.size, pack.leaks.map { it.name }.toSet().size, "names are unique")
    }

    @Test
    fun `the manifest may only name its own img and thumb files`() {
        val ok = """{"format":"lightly-leak-pack","formatVersion":1,"leaks":[{"id":"leak-0123456789ab","name":"Gold Edge","image":"img/leak-0123456789ab.jpg","thumbnail":"thumb/leak-0123456789ab.jpg","imageSha256":"${"a".repeat(64)}","width":16,"height":9}]}"""
        assertEquals(listOf("leak-0123456789ab"), LeakPack.parse(ok).leaks.map { it.id })
        val failures = listOf(
            ok.replace("img/leak-0123456789ab.jpg", "../img/leak-0123456789ab.jpg"),
            ok.replace(""""formatVersion":1""", """"formatVersion":2"""),
            ok.replace(""""id":"leak-0123456789ab"""", """"id":"leak-XYZ""""),
        )
        failures.forEach { text -> kotlin.test.assertFailsWith<IllegalArgumentException> { LeakPack.parse(text) } }
    }
}
