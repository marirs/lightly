package com.lightlylabs.lightly.vision.sunglasses

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.imageio.ImageIO
import kotlin.math.abs
import kotlin.test.assertTrue

/**
 * The Kotlin rasteriser against SceneKit (shared/sunglasses/out/reference: render_lsg.swift passes of every pair at three
 * poses). The pack is git-ignored (purchased models), so the test is skipped where it has not been built.
 */
class SunglassesRasterTest {
    private val packDir = generateSequence(File("").absoluteFile) { it.parentFile }
        .map { File(it, "shared/sunglasses/out") }.firstOrNull { File(it, "sunglasses.json").isFile }

    private fun pack(): SunglassesPack {
        val dir = packDir!!
        return SunglassesPack.load(File(dir, "sunglasses.json").readText()) { path -> File(dir, path).takeIf { it.isFile }?.readBytes() }
    }

    private fun texture(dir: File, path: String): SunglassesRaster.Texture? {
        val image = ImageIO.read(File(dir, path)) ?: return null
        val rgba = ByteArray(image.width * image.height * 4)
        for (y in 0 until image.height) for (x in 0 until image.width) {
            val argb = image.getRGB(x, y)
            val o = (y * image.width + x) * 4
            rgba[o] = (argb shr 16).toByte(); rgba[o + 1] = (argb shr 8).toByte(); rgba[o + 2] = argb.toByte(); rgba[o + 3] = (argb ushr 24).toByte()
        }
        return SunglassesRaster.Texture(image.width, image.height, rgba)
    }

    /** Fits the lighting gains to SceneKit (run with SUNGLASSES_FIT=1; prints the best and leaves the constants alone). */
    @Test
    fun `fit lighting gains`() {
        assumeTrue(packDir != null && System.getenv("SUNGLASSES_FIT") != null)
        val dir = packDir!!
        val pack = pack()
        val textures = HashMap<String, SunglassesRaster.Texture?>()
        val index = Json.parseToJsonElement(File(dir, "reference/index.json").readText()).jsonObject.getValue("renders").jsonArray
            .filter { it.jsonObject.getValue("pose").jsonPrimitive.content != "yawm60pitch10" }
        val refs = index.map { ImageIO.read(File(dir, it.jsonObject.getValue("frame").jsonPrimitive.content)) }
        var best = Triple(0f, 0f, 0f) to Double.MAX_VALUE
        for (ambient in listOf(0.35f, 0.4f, 0.45f)) for (key in listOf(1.1f, 1.2f, 1.3f)) for (spec in listOf(2f, 3f, 4f, 6f)) {
            SunglassesRaster.Lighting.AMBIENT = ambient; SunglassesRaster.Lighting.KEY = key; SunglassesRaster.Lighting.SPECULAR = spec
            var err = 0.0; var count = 0
            for ((entry, ref) in index.zip(refs)) {
                val e = entry.jsonObject
                val pair = pack.pair(e.getValue("pair").jsonPrimitive.content)!!
                val W = e.getValue("W").jsonPrimitive.int; val H = e.getValue("H").jsonPrimitive.int
                fun vec(k: String) = e.getValue(k).jsonArray.map { it.jsonPrimitive.double }.toDoubleArray()
                val placement = SunglassesRaster.Placement(doubleArrayOf(0.0, 0.0, 0.0), vec("ex"), vec("ey"), vec("ez"), e.getValue("s").jsonPrimitive.double)
                val frame = SunglassesRaster.render(pack, pair, pack.mesh(pair), { p -> textures.getOrPut(p) { texture(dir, p) } }, placement, W, H, 0, 0, W, H,
                                                    FloatArray(0), SunglassesRaster.Pass.FRAME)
                for (y in 0 until H step 2) for (x in 0 until W step 2) {
                    val o = (y * W + x) * 4; val rf = ref.getRGB(x, y)
                    if (frame.rgba[o + 3] > 0.98 && (rf ushr 24) > 250) {
                        for (c in 0..2) err += abs(frame.rgba[o + c] - ((rf shr (16 - 8 * c)) and 0xff) / 255.0); count += 3
                    }
                }
            }
            val mean = err / count
            if (mean < best.second) best = Triple(ambient, key, spec) to mean
        }
        println("best lighting: ambient ${best.first.first} key ${best.first.second} specular ${best.first.third} mean ${best.second}")
    }

    @Test
    fun `every pair at every reference pose matches SceneKit's coverage and colour`() {
        assumeTrue("sunglasses pack not built (shared/sunglasses/build_sunglasses.py)", packDir != null)
        val dir = packDir!!
        val pack = pack()
        val textures = HashMap<String, SunglassesRaster.Texture?>()
        val index = Json.parseToJsonElement(File(dir, "reference/index.json").readText()).jsonObject.getValue("renders").jsonArray
        val report = StringBuilder()
        var worstFrameIoU = 1.0; var worstLensIoU = 1.0; var worstColour = 0.0
        for (entry in index) {
            val e = entry.jsonObject
            val pair = pack.pair(e.getValue("pair").jsonPrimitive.content)!!
            val W = e.getValue("W").jsonPrimitive.int; val H = e.getValue("H").jsonPrimitive.int
            fun vec(key: String) = e.getValue(key).jsonArray.map { it.jsonPrimitive.double }.toDoubleArray()
            val cx = e.getValue("cx").jsonPrimitive.double; val cy = e.getValue("cy").jsonPrimitive.double
            val placement = SunglassesRaster.Placement(doubleArrayOf(cx - W / 2.0, H / 2.0 - cy, 0.0), vec("ex"), vec("ey"), vec("ez"),
                                                       e.getValue("s").jsonPrimitive.double)
            val mesh = pack.mesh(pair)
            val get = { path: String -> textures.getOrPut(path) { texture(dir, path) } }
            val frame = SunglassesRaster.render(pack, pair, mesh, get, placement, W, H, 0, 0, W, H, FloatArray(0), SunglassesRaster.Pass.FRAME)
            val lens = SunglassesRaster.render(pack, pair, mesh, get, placement, W, H, 0, 0, W, H, FloatArray(0), SunglassesRaster.Pass.LENS)
            val refFrame = ImageIO.read(File(dir, e.getValue("frame").jsonPrimitive.content))
            val refLens = ImageIO.read(File(dir, e.getValue("lens").jsonPrimitive.content))
            var fi = 0; var fu = 0; var li = 0; var lu = 0; var colour = 0.0; var both = 0
            for (y in 0 until H) for (x in 0 until W) {
                val o = (y * W + x) * 4
                val rf = refFrame.getRGB(x, y); val rl = refLens.getRGB(x, y)
                val refFrameA = (rf ushr 24) / 255.0
                val refLensCover = ((rl shr 16) and 0xff) / 255.0 * ((rl ushr 24) / 255.0)
                val f = frame.rgba[o + 3] > 0.5; val rfOn = refFrameA > 0.5
                if (f && rfOn) fi++; if (f || rfOn) fu++
                val l = lens.rgba[o] * lens.rgba[o + 3] > 0.5; val rlOn = refLensCover > 0.5
                if (l && rlOn) li++; if (l || rlOn) lu++
                if (frame.rgba[o + 3] > 0.98 && refFrameA > 0.98) {
                    both++
                    for (c in 0..2) colour += abs(frame.rgba[o + c] - ((rf shr (16 - 8 * c)) and 0xff) / 255.0)
                }
            }
            System.getenv("SUNGLASSES_RASTER_OUT")?.let { out ->
                val image = java.awt.image.BufferedImage(W, H, java.awt.image.BufferedImage.TYPE_INT_ARGB)
                for (y in 0 until H) for (x in 0 until W) {
                    val o = (y * W + x) * 4
                    fun b(v: Float) = (v.coerceIn(0f, 1f) * 255 + 0.5f).toInt()
                    image.setRGB(x, y, (b(frame.rgba[o + 3]) shl 24) or (b(frame.rgba[o]) shl 16) or (b(frame.rgba[o + 1]) shl 8) or b(frame.rgba[o + 2]))
                }
                File(out).mkdirs()
                ImageIO.write(image, "png", File(out, "${pair.id}-${e.getValue("pose").jsonPrimitive.content}.frame.png"))
            }
            val frameIoU = fi.toDouble() / maxOf(fu, 1); val lensIoU = li.toDouble() / maxOf(lu, 1)
            val meanColour = colour / maxOf(both * 3, 1)
            worstFrameIoU = minOf(worstFrameIoU, frameIoU); worstLensIoU = minOf(worstLensIoU, lensIoU); worstColour = maxOf(worstColour, meanColour)
            report.append("${pair.name} ${e.getValue("pose").jsonPrimitive.content}: frame IoU %.3f lens IoU %.3f colour %.4f\n".format(frameIoU, lensIoU, meanColour))
        }
        println(report)
        println("worst: frame IoU %.3f, lens IoU %.3f, mean colour difference %.4f".format(worstFrameIoU, worstLensIoU, worstColour))
        // Thin wire frames (Aviator) lose most of their overlap to anti-aliasing at 0.5 coverage; lenses are solid.
        assertTrue(worstFrameIoU > 0.75, "frame coverage\n$report")
        assertTrue(worstLensIoU > 0.98, "lens coverage\n$report")
        assertTrue(worstColour < 0.08, "frame colour\n$report")   // worst: Round front 0.075 (warm tint of its acetate)
    }
}
