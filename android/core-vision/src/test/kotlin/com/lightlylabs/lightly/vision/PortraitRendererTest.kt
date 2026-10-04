package com.lightlylabs.lightly.vision

import com.lightlylabs.lightly.session.Eyes
import com.lightlylabs.lightly.session.FaceEdit
import com.lightlylabs.lightly.session.FaceIdentity
import com.lightlylabs.lightly.session.Hair
import com.lightlylabs.lightly.session.NormalisedRect
import com.lightlylabs.lightly.session.Skin
import com.lightlylabs.lightly.session.Teeth
import com.lightlylabs.lightly.session.UnderEye
import org.junit.Test
import kotlin.math.cos
import kotlin.math.sin
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PortraitRendererTest {
    private val size = 200
    private val box = NormalisedRect(0.35, 0.3, 0.3, 0.4)

    /** A synthetic face: an ellipse of skin tone with a red blemish, on a grey background. */
    private fun photo(): RgbaImage {
        val pixels = ByteArray(size * size * 4)
        for (y in 0 until size) for (x in 0 until size) {
            val o = (y * size + x) * 4
            val dx = (x - 100.0) / 30
            val dy = (y - 100.0) / 40
            val inFace = dx * dx + dy * dy < 1
            val blemish = (x - 90) * (x - 90) + (y - 110) * (y - 110) < 9
            val (r, g, b) = when {
                blemish -> Triple(200, 90, 90)
                inFace -> Triple(205 + (x + y) % 7, 160, 135)
                else -> Triple(90, 90, 95)
            }
            pixels[o] = r.toByte(); pixels[o + 1] = g.toByte(); pixels[o + 2] = b.toByte(); pixels[o + 3] = 0xff.toByte()
        }
        return RgbaImage(size, size, pixels)
    }

    /** Mesh landmarks: the regions this test needs are placed on the synthetic face, the rest at its centre. */
    private fun face(): DetectedFace {
        val points = MutableList(FaceMeshRegions.LANDMARK_COUNT) { Point(0.5, 0.5) }
        fun ring(indices: IntArray, cx: Double, cy: Double, rx: Double, ry: Double) =
            indices.forEachIndexed { k, i -> val t = 2 * Math.PI * k / indices.size; points[i] = Point(cx + rx * cos(t), cy + ry * sin(t)) }
        ring(FaceMeshRegions.FACE_OVAL, 0.5, 0.5, 0.15, 0.2)
        ring(FaceMeshRegions.IMAGE_LEFT_EYE, 0.44, 0.44, 0.03, 0.01)
        ring(FaceMeshRegions.IMAGE_RIGHT_EYE, 0.56, 0.44, 0.03, 0.01)
        ring(FaceMeshRegions.IMAGE_LEFT_EYEBROW, 0.44, 0.40, 0.035, 0.006)
        ring(FaceMeshRegions.IMAGE_RIGHT_EYEBROW, 0.56, 0.40, 0.035, 0.006)
        ring(FaceMeshRegions.OUTER_LIPS, 0.5, 0.62, 0.05, 0.02)
        ring(FaceMeshRegions.INNER_LIPS, 0.5, 0.62, 0.04, 0.01)
        return DetectedFace(box, 0.9f, 1f, points)
    }

    private fun edit(smoothing: Double = 0.0, blemishes: Double = 0.0, teeth: Double = 0.0) = FaceEdit(
        FaceIdentity(box, DetectedFace.DETECTOR), Skin(smoothing, blemishes, 0.0, 85.0), UnderEye(0.0, 0.0), Eyes(0.0, 0.0), Teeth(teeth), Hair(0.0, 0.0, 0.0),
    )

    @Test
    fun `neutral settings leave the photo byte for byte`() {
        val image = photo()
        val out = PortraitRenderer.render(image, listOf(PortraitRenderer.Face(face(), edit())), null)
        assertContentEquals(image.pixels, out.pixels)
    }

    @Test
    fun `blemishes pull a red mark toward the surrounding skin, and nothing outside the crop changes`() {
        val image = photo()
        val out = PortraitRenderer.render(image, listOf(PortraitRenderer.Face(face(), edit(blemishes = 100.0))), null)
        fun red(img: RgbaImage, x: Int, y: Int) = (img.pixels[(y * size + x) * 4].toInt() and 0xff) - (img.pixels[(y * size + x) * 4 + 1].toInt() and 0xff)
        assertTrue(red(out, 90, 110) < red(image, 90, 110) - 10, "blemish redness ${red(image, 90, 110)} -> ${red(out, 90, 110)}")
        val crop = PortraitRenderer.cropFor(face(), size, size)
        for (y in 0 until size) for (x in 0 until size) {
            if (x in crop[0] until crop[2] && y in crop[1] until crop[3]) continue
            val o = (y * size + x) * 4
            for (c in 0 until 4) assertEquals(image.pixels[o + c], out.pixels[o + c])
        }
    }

    @Test
    fun `smoothing keeps the skin's average colour`() {
        val image = photo()
        val out = PortraitRenderer.render(image, listOf(PortraitRenderer.Face(face(), edit(smoothing = 100.0))), null)
        fun mean(img: RgbaImage, c: Int): Double {
            var sum = 0.0; var n = 0
            for (y in 115..130) for (x in 105..120) { sum += img.pixels[(y * size + x) * 4 + c].toInt() and 0xff; n++ }
            return sum / n
        }
        for (c in 0 until 3) assertEquals(mean(image, c), mean(out, c), 2.0)
    }

    @Test
    fun `faces without landmarks or changes are skipped`() {
        val image = photo()
        val bare = DetectedFace(box, 0.9f, 0f, emptyList())
        assertContentEquals(image.pixels, PortraitRenderer.render(image, listOf(PortraitRenderer.Face(bare, edit(smoothing = 50.0))), null).pixels)
        assertTrue(!PortraitRenderer.hasChanges(edit()))
        assertTrue(PortraitRenderer.hasChanges(edit(teeth = 1.0)))
    }
}
