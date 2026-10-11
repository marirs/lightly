package com.lightlylabs.lightly.vision

import com.lightlylabs.lightly.session.Eyes
import com.lightlylabs.lightly.session.FaceEdit
import com.lightlylabs.lightly.session.FaceIdentity
import com.lightlylabs.lightly.session.Hair
import com.lightlylabs.lightly.session.NormalisedRect
import com.lightlylabs.lightly.session.Skin
import com.lightlylabs.lightly.session.Smile
import com.lightlylabs.lightly.session.Teeth
import com.lightlylabs.lightly.session.UnderEye
import org.junit.Test
import kotlin.math.abs
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** rendering-v2 revision 7 §7.3 `portrait.smile`: the inverse warp around the mouth corners. */
class SmileWarpTest {
    private val size = 200
    private val box = NormalisedRect(0.3, 0.3, 0.4, 0.4)

    /** Horizontal stripes every 4 px, so any vertical displacement changes pixels; a dark mouth line at y = 124. */
    private fun photo(): RgbaImage {
        val pixels = ByteArray(size * size * 4)
        for (y in 0 until size) for (x in 0 until size) {
            val o = (y * size + x) * 4
            val v = if (y == 124) 30 else if ((y / 4) % 2 == 0) 220 else 120
            pixels[o] = v.toByte(); pixels[o + 1] = (v - 10).toByte(); pixels[o + 2] = (v - 20).toByte(); pixels[o + 3] = 0xff.toByte()
        }
        return RgbaImage(size, size, pixels)
    }

    /** Face Mesh landmarks with the mouth corners (61 image-left, 291 image-right) at y = 0.62, 0.1 of the frame apart. */
    private fun face(withLandmarks: Boolean = true): DetectedFace {
        if (!withLandmarks) return DetectedFace(box, 0.9f, 1f, emptyList())
        val points = MutableList(FaceMeshRegions.LANDMARK_COUNT) { Point(0.5, 0.5) }
        points[FaceMeshRegions.MOUTH_LEFT_CORNER] = Point(0.45, 0.62)
        points[FaceMeshRegions.MOUTH_RIGHT_CORNER] = Point(0.55, 0.62)
        return DetectedFace(box, 0.9f, 1f, points)
    }

    private fun edit(smile: Double) = FaceEdit(
        FaceIdentity(box, DetectedFace.DETECTOR), Skin(0.0, 0.0, 0.0, 85.0), UnderEye(0.0, 0.0), Eyes(0.0, 0.0), Teeth(0.0),
        smile = Smile(smile), hair = Hair(0.0, 0.0, 0.0),
    )

    private fun render(smile: Double, face: DetectedFace = face()) = PortraitRenderer.render(photo(), listOf(PortraitRenderer.Face(face, edit(smile))), null)

    private fun red(image: RgbaImage, x: Int, y: Int) = image.pixels[(y * size + x) * 4].toInt() and 0xff

    @Test
    fun `amount 0 leaves every pixel unchanged`() {
        assertContentEquals(photo().pixels, render(0.0).pixels)
    }

    @Test
    fun `a positive amount lifts the mouth corners, and pixels far from them are unchanged`() {
        val out = render(100.0)
        val input = photo()
        // m = 20 px; the left corner moves by d_L = m·(0.10·n̂ − 0.04·û) = (−0.8, −2.0) px: the mouth line rises there.
        // Just above the corner the output samples 2 px lower, closer to the dark line.
        val cornerX = 90
        assertTrue(red(out, cornerX, 122) < red(input, cornerX, 122), "the corner region shows the mouth line raised")
        // Outside both discs (r = 0.45·m = 9 px) nothing changes.
        for ((x, y) in listOf(10 to 10, 60 to 124, 140 to 124, 100 to 150, 100 to 100)) {
            assertEquals(red(input, x, y), red(out, x, y), "pixel ($x, $y) is outside the warp")
        }
    }

    @Test
    fun `the corner displacements follow the contract's lift and outward constants`() {
        val (left, right) = SmileWarp.displacements(Point(90.0, 124.0), Point(110.0, 124.0), 100.0)
        // û = (1, 0); n̂ = û turned 90° anticlockwise with y down = (0, −1): up the face.
        assertEquals(-0.8, left.x, 1e-9); assertEquals(-2.0, left.y, 1e-9)
        assertEquals(0.8, right.x, 1e-9); assertEquals(-2.0, right.y, 1e-9)
        val (down, _) = SmileWarp.displacements(Point(90.0, 124.0), Point(110.0, 124.0), -50.0)
        assertEquals(0.4, down.x, 1e-9); assertEquals(1.0, down.y, 1e-9)
    }

    @Test
    fun `the falloff is one at the corner and zero from the radius out`() {
        assertEquals(1.0, SmileWarp.falloff(0.0, 0.0, 81.0))
        assertEquals(0.0, SmileWarp.falloff(9.0, 0.0, 81.0))
        assertEquals(0.0, SmileWarp.falloff(12.0, 3.0, 81.0))
        assertTrue(abs(SmileWarp.falloff(4.5, 0.0, 81.0) - 0.5625) < 1e-12)
    }

    @Test
    fun `a face without mouth corners is left unchanged`() {
        assertNull(face(withLandmarks = false).mouthCorners)
        assertContentEquals(photo().pixels, render(80.0, face(withLandmarks = false)).pixels)
    }
}
