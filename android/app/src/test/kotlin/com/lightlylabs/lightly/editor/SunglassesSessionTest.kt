package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.develop.PixelRect
import com.lightlylabs.lightly.render.image.ImageFrameSource
import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.session.ModelRef
import com.lightlylabs.lightly.session.NormalisedRect
import com.lightlylabs.lightly.session.PortraitTool
import com.lightlylabs.lightly.session.SavedEdits
import com.lightlylabs.lightly.session.Sunglasses
import com.lightlylabs.lightly.session.SunglassesLens
import com.lightlylabs.lightly.vision.sunglasses.FaceSunglassesAnalysis
import com.lightlylabs.lightly.vision.sunglasses.ProbabilityMap
import com.lightlylabs.lightly.vision.sunglasses.SunglassesPack
import com.lightlylabs.lightly.vision.sunglasses.SunglassesRaster
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
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Portrait › Sunglasses in the Android session (rendering-v2 §7.5), on the trial photos with the analysis iOS exports into
 * shared/fixtures/sunglasses: the paint-out of a face's own glasses (with a stand-in model), and Save copy's
 * full-resolution region patches against the whole-frame render.
 */
class SunglassesSessionTest {
    private val root = generateSequence(File("").absoluteFile) { it.parentFile }.first { File(it, "shared/fixtures/sunglasses").isDirectory }
    private val packDir = File(root, "shared/sunglasses/out").takeIf { File(it, "sunglasses.json").isFile }

    private fun photo(path: String): Rgba8Image {
        val image = ImageIO.read(File(root, path))
        val px = ByteArray(image.width * image.height * 4)
        for (y in 0 until image.height) for (x in 0 until image.width) {
            val argb = image.getRGB(x, y); val o = (y * image.width + x) * 4
            px[o] = (argb shr 16).toByte(); px[o + 1] = (argb shr 8).toByte(); px[o + 2] = argb.toByte(); px[o + 3] = 0xff.toByte()
        }
        return Rgba8Image(image.width, image.height, px)
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
                return ProbabilityMap(FloatArray(256 * 256) { (image.getRGB(it % 256, it / 256) and 0xff) / 255f }, crop[0], crop[1], crop[2])
            }
            val box = f.getValue("box").jsonArray.map { it.jsonPrimitive.double }
            FaceSunglassesAnalysis(NormalisedRect(box[0], box[1], box[2], box[3]), w, h,
                                   f.getValue("landmarks").jsonArray.map { it.jsonPrimitive.double.toFloat() }.toFloatArray(),
                                   f.getValue("logit").jsonPrimitive.double.toFloat(),
                                   map("hair", "hairCrop"), map("background", "backgroundCrop"), map("accessory", "accessoryCrop"))
        }
    }

    /** Stands in for LaMa: fills the hole with mid grey and records how it was called. */
    private class GreyInpainter : Inpainter {
        override val model = ModelRef("test-grey", "1")
        var calls = 0; var holePixels = 0
        override fun inpaint(image: FloatArray, mask: FloatArray): FloatArray {
            calls++; holePixels = mask.count { it > 0.5f }
            return FloatArray(image.size) { i -> if (mask[i % mask.size] > 0.5f) 0.5f else image[i] }
        }
    }

    @Test
    fun `his own glasses are painted out over the eye band only, and a face without glasses gets no patch`() {
        val side = photo("experiments/test-photos/glasses_side_angle_01.jpg")
        val inpainter = GreyInpainter()
        val result = assertNotNull(SunglassesRemoval.patch(analysis("glasses_side_angle_01").first(), ImageFrameSource(side), inpainter))
        assertEquals(1, inpainter.calls, "LaMa runs once")
        assertTrue(inpainter.holePixels > 2000, "the hole covers the frames (${inpainter.holePixels} px of 512²)")
        // The patch sits on the eyes: inside the face box horizontally, between the brows and the nose tip.
        val box = analysis("glasses_side_angle_01").first().faceBox
        val r = result.rect
        assertTrue(r.x >= box.x - box.width * 0.3 && r.x + r.width <= box.x + box.width * 1.3, "patch $r, face $box")
        assertTrue(r.y >= box.y - box.height * 0.1 && r.y + r.height <= box.y + box.height * 0.8, "patch $r, face $box")
        // Feathered: some pixels partly transparent, and grey where fully filled.
        val alphas = (0 until result.patch.width * result.patch.height).map { result.patch.rgba[it * 4 + 3].toInt() and 0xff }
        assertTrue(alphas.any { it in 1..254 } && alphas.any { it == 255 })

        val noGlasses = photo("experiments/lut3d/photos/portrait_deep_02.jpg")
        assertNull(SunglassesRemoval.patch(analysis("portrait_deep_02").first(), ImageFrameSource(noGlasses), GreyInpainter()))
    }

    @Test
    fun `Save copy's region patches reproduce the whole-frame render`() {
        assumeTrue("sunglasses pack not built", packDir != null)
        val pack = SunglassesPack.load(File(packDir!!, "sunglasses.json").readText()) { File(packDir, it).takeIf(File::isFile)?.readBytes() }
        val library = SunglassesLibrary(pack) { bytes ->
            ImageIO.read(bytes.inputStream())?.let { im ->
                val px = ByteArray(im.width * im.height * 4)
                for (y in 0 until im.height) for (x in 0 until im.width) {
                    val argb = im.getRGB(x, y); val o = (y * im.width + x) * 4
                    px[o] = (argb shr 16).toByte(); px[o + 1] = (argb shr 8).toByte(); px[o + 2] = argb.toByte(); px[o + 3] = (argb ushr 24).toByte()
                }
                SunglassesRaster.Texture(im.width, im.height, px)
            }
        }
        val frame = photo("experiments/lut3d/photos/portrait_medium_02.jpg")
        val analyses = analysis("portrait_medium_02")
        val session = PortraitSession(library)
        val face = SavedEdits.decodeEditState(File(root, "shared/fixtures/edit-recipe/portrait-sunglasses.json").readText()).tools.portrait.faces.first()
        val edit = face.copy(face = face.face.copy(box = analyses[0].faceBox),
                             sunglasses = Sunglasses(pack.pairs.first { it.name == "Pilot" }.id, SunglassesLens.MIRROR, 70.0, 5.0, null))
        val tool = PortraitTool(listOf(edit))
        assertFalse(session.isActive(tool), "inactive until the analysis ran")
        session.setSunglassesAnalyses(analyses)
        assertTrue(session.isActive(tool))
        val whole = session.render(frame, tool)
        val patches = session.exportPatches(tool, frame.width, frame.height) { region ->
            Rgba8Image(region.width, region.height, ByteArray(region.width * region.height * 4) { i ->
                val x = (i / 4) % region.width; val y = (i / 4) / region.width
                frame.pixels[((region.y + y) * frame.width + region.x + x) * 4 + i % 4]
            })
        }
        assertEquals(1, patches.size)
        val tiled = frame.pixels.copyOf()
        PortraitSession.applyPatches(tiled, PixelRect(0, 0, frame.width, frame.height), patches)
        var different = 0
        for (i in tiled.indices) if (i % 4 != 3 && tiled[i] != whole.pixels[i]) different++
        assertEquals(0, different, "channel values that differ between Save copy and the preview render")
    }
}
