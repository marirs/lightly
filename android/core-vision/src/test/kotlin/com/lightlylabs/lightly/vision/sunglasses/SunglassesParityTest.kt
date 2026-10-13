package com.lightlylabs.lightly.vision.sunglasses

import com.lightlylabs.lightly.session.DerivedRef
import com.lightlylabs.lightly.session.EditState
import com.lightlylabs.lightly.session.FaceEdit
import com.lightlylabs.lightly.session.NormalisedRect
import com.lightlylabs.lightly.session.SavedEdits
import com.lightlylabs.lightly.session.Sunglasses
import com.lightlylabs.lightly.session.SunglassesLens
import com.lightlylabs.lightly.vision.RgbaImage
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.boolean
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
 * Android against iOS on whole renders (rendering-v2 §7.5): the same photo, the same analysis (exported by iOS
 * SunglassesEngineTests into shared/fixtures/sunglasses: landmarks, crops, maps as 8-bit PNGs) and the same pair (the
 * Wayfarer, dark lenses at 75). The iOS renders of the face region live with the git-ignored pack
 * (the .ios-region.png files in shared/sunglasses/out/reference), so the test is skipped where the pack has not been built.
 */
class SunglassesParityTest {
    private val root = generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "shared/fixtures/sunglasses").isDirectory }
    private val packDir = File(root, "shared/sunglasses/out").takeIf { File(it, "sunglasses.json").isFile }

    private fun rgba(file: File): RgbaImage {
        val image = ImageIO.read(file)
        val px = ByteArray(image.width * image.height * 4)
        for (y in 0 until image.height) for (x in 0 until image.width) {
            val argb = image.getRGB(x, y); val o = (y * image.width + x) * 4
            px[o] = (argb shr 16).toByte(); px[o + 1] = (argb shr 8).toByte(); px[o + 2] = argb.toByte(); px[o + 3] = 0xff.toByte()
        }
        return RgbaImage(image.width, image.height, px)
    }

    private fun analysis(name: String): List<FaceSunglassesAnalysis> {
        val dir = File(root, "shared/fixtures/sunglasses")
        val json = Json.parseToJsonElement(File(dir, "$name.analysis.json").readText()).jsonObject
        val w = json.getValue("width").jsonPrimitive.int; val h = json.getValue("height").jsonPrimitive.int
        return json.getValue("faces").jsonArray.mapIndexed { index, element ->
            val f = element.jsonObject
            fun map(kind: String, key: String): ProbabilityMap {
                val crop = f.getValue(key).jsonArray.map { it.jsonPrimitive.double.toFloat() }
                val image = ImageIO.read(File(dir, "$name.f$index.$kind.png"))
                val values = FloatArray(256 * 256) { (image.getRGB(it % 256, it / 256) and 0xff) / 255f }
                return ProbabilityMap(values, crop[0], crop[1], crop[2])
            }
            val box = f.getValue("box").jsonArray.map { it.jsonPrimitive.double }
            FaceSunglassesAnalysis(NormalisedRect(box[0], box[1], box[2], box[3]), w, h,
                                   f.getValue("landmarks").jsonArray.map { it.jsonPrimitive.double.toFloat() }.toFloatArray(),
                                   f.getValue("logit").jsonPrimitive.double.toFloat(),
                                   map("hair", "hairCrop"), map("background", "backgroundCrop"), map("accessory", "accessoryCrop"))
        }
    }

    @Test
    fun `renders match iOS on the trial photos`() {
        assumeTrue("sunglasses pack not built", packDir != null && File(packDir, "reference/portrait_deep_02.ios-region.png").isFile)
        val pack = SunglassesPack.load(File(packDir!!, "sunglasses.json").readText()) { File(packDir, it).takeIf(File::isFile)?.readBytes() }
        val wayfarer = pack.pairs.first { it.name == "Wayfarer" }
        val textures = HashMap<String, SunglassesRaster.Texture?>()
        val texture = { path: String -> textures.getOrPut(path) {
            ImageIO.read(File(packDir, path))?.let { im ->
                val px = ByteArray(im.width * im.height * 4)
                for (y in 0 until im.height) for (x in 0 until im.width) {
                    val argb = im.getRGB(x, y); val o = (y * im.width + x) * 4
                    px[o] = (argb shr 16).toByte(); px[o + 1] = (argb shr 8).toByte(); px[o + 2] = argb.toByte(); px[o + 3] = (argb ushr 24).toByte()
                }
                SunglassesRaster.Texture(im.width, im.height, px)
            }
        } }
        val neutral = SavedEdits.decodeEditState(File(root, "shared/fixtures/edit-recipe/portrait-sunglasses.json").readText())
            .tools.portrait.faces.first()
        val report = StringBuilder()
        for ((dir, name) in listOf("experiments/lut3d/photos" to "portrait_deep_02", "experiments/lut3d/photos" to "portrait_medium_02",
                                   "experiments/test-photos" to "profile_bw_woman_01")) {
            val photo = rgba(File(root, "$dir/$name.jpg"))
            val analyses = analysis(name)
            val edit = neutral.copy(sunglasses = Sunglasses(wayfarer.id, SunglassesLens.DARK, 75.0, 0.0, null))
            val started = System.nanoTime()
            val out = SunglassesRenderer.render(photo, analyses.map { SunglassesRenderer.Face(edit, it) }, analyses, pack, texture)
            val ms = (System.nanoTime() - started) / 1_000_000
            val region = Json.parseToJsonElement(File(root, "shared/fixtures/sunglasses/$name.analysis.json").readText()).jsonObject
                .getValue("region").jsonArray.map { it.jsonPrimitive.int }
            val ios = ImageIO.read(File(packDir, "reference/$name.ios-region.png"))
            // Over the pixels either platform changed (the pair, its shadow and the glass), the mean difference.
            var changed = 0; var diff = 0.0; var big = 0
            for (y in 0 until region[3]) for (x in 0 until region[2]) {
                val px = region[0] + x; val py = region[1] + y; val o = (py * photo.width + px) * 4
                val i = ios.getRGB(x, y)
                var dOrig = 0.0; var dIos = 0.0; var dAndroidOrig = 0.0
                for (c in 0..2) {
                    val orig = (photo.pixels[o + c].toInt() and 0xff); val a = (out.pixels[o + c].toInt() and 0xff); val b = (i shr (16 - 8 * c)) and 0xff
                    dOrig += abs(b - orig); dAndroidOrig += abs(a - orig); dIos += abs(a - b)
                }
                if (dOrig > 9 || dAndroidOrig > 9) { changed++; diff += dIos / 3 / 255; if (dIos / 3 > 40) big++ }
            }
            System.getenv("SUNGLASSES_RASTER_OUT")?.let { outDir ->
                val image = java.awt.image.BufferedImage(region[2], region[3], java.awt.image.BufferedImage.TYPE_INT_RGB)
                for (y in 0 until region[3]) for (x in 0 until region[2]) {
                    val o = ((region[1] + y) * photo.width + region[0] + x) * 4
                    image.setRGB(x, y, ((out.pixels[o].toInt() and 0xff) shl 16) or ((out.pixels[o + 1].toInt() and 0xff) shl 8) or (out.pixels[o + 2].toInt() and 0xff))
                }
                File(outDir).mkdirs(); ImageIO.write(image, "png", File(outDir, "$name.android-region.png"))
            }
            val mean = diff / maxOf(changed, 1); val bigFraction = big.toDouble() / maxOf(changed, 1)
            report.append("$name: changed $changed px, mean |Android − iOS| %.4f, > 40 levels on %.3f, %d ms\n".format(mean, bigFraction, ms))
            assertTrue(mean < 0.05 && bigFraction < 0.06, report.toString())
        }
        println(report)
    }
}
