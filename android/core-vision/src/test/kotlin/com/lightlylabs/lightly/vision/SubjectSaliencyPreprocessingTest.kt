package com.lightlylabs.lightly.vision

import com.lightlylabs.lightly.background.FloatPlane
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.imageio.ImageIO
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * U²-Netp's input against the reference pipeline (u2net_test.py: skimage resize + ToTensorLab(flag=0)), from
 * goldens written by experiments/android-vision/scripts/make_u2netp_preprocessing_goldens.py: a downscale with
 * anti-aliasing on both axes, an odd-sized portrait crop, and an upscale (no anti-aliasing).
 */
class SubjectSaliencyPreprocessingTest {
    private val cases = listOf("boat_600x400", "swan_301x457", "lake_200x150")

    private fun image(name: String): RgbaImage {
        val decoded = checkNotNull(ImageIO.read(checkNotNull(javaClass.getResource("/u2netp/$name.png")))) { "cannot decode $name" }
        val pixels = ByteArray(decoded.width * decoded.height * 4)
        for (y in 0 until decoded.height) for (x in 0 until decoded.width) {
            val argb = decoded.getRGB(x, y)
            val o = (y * decoded.width + x) * 4
            pixels[o] = (argb shr 16).toByte(); pixels[o + 1] = (argb shr 8).toByte(); pixels[o + 2] = argb.toByte(); pixels[o + 3] = -1
        }
        return RgbaImage(decoded.width, decoded.height, pixels)
    }

    private fun golden(file: String): FloatArray {
        val bytes = checkNotNull(javaClass.getResource("/u2netp/$file")).readBytes()
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        return FloatArray(buffer.remaining()).also { buffer.get(it) }
    }

    private fun worstDifference(actual: FloatArray, expectedEvery7th: FloatArray): Float {
        assertEquals((actual.size + STRIDE - 1) / STRIDE, expectedEvery7th.size)
        var worst = 0f
        for (i in expectedEvery7th.indices) worst = maxOf(worst, abs(actual[i * STRIDE] - expectedEvery7th[i]))
        return worst
    }

    @Test
    fun `resize equals scikit-image's anti-aliased resize`() {
        for (name in cases) {
            val resized = ReferenceResize.resize(image(name), SubjectSaliency.INPUT, SubjectSaliency.INPUT)
            val worst = worstDifference(resized, golden("$name.resized.f32"))
            assertTrue(worst <= 1e-5f, "$name resized differs by $worst")
        }
    }

    @Test
    fun `model input equals ToTensorLab's NCHW tensor`() {
        for (name in cases) {
            val tensor = SubjectSaliency.normalise(ReferenceResize.resize(image(name), SubjectSaliency.INPUT, SubjectSaliency.INPUT))
            assertEquals(3 * SubjectSaliency.INPUT * SubjectSaliency.INPUT, tensor.size)
            val worst = worstDifference(tensor, golden("$name.tensor.f32"))
            assertTrue(worst <= 1e-4f, "$name tensor differs by $worst")
        }
    }

    @Test
    fun `scipy's gaussian kernel and scikit-image's sigma`() {
        assertEquals(0.0, ReferenceResize.sigmaFor(200, 320))
        assertEquals(2.5, ReferenceResize.sigmaFor(1920, 320), 1e-12)
        val kernel = ReferenceResize.gaussianKernel(2.5)
        assertEquals(21, kernel.size)  // radius int(4 · 2.5 + 0.5) = 10
        assertEquals(1f, kernel.sum(), 1e-6f)
        assertEquals(kernel.first(), kernel.last())
    }

    @Test
    fun `no clear subject below two percent confident area (experimental rule)`() {
        fun plane(confidentShare: Float): FloatPlane {
            val n = SubjectSaliency.INPUT * SubjectSaliency.INPUT
            val confident = (n * confidentShare).toInt()
            // A soft blob that peaks high but is mostly below 0.9 (the lake's shape) is not a subject.
            return FloatPlane(SubjectSaliency.INPUT, SubjectSaliency.INPUT, FloatArray(n) { if (it < confident) 0.95f else if (it < n / 8) 0.7f else 0f })
        }
        assertFalse(SubjectSaliency.hasClearSubject(plane(0.011f)))
        assertTrue(SubjectSaliency.hasClearSubject(plane(0.046f)))
    }

    private companion object {
        const val STRIDE = 7
    }
}
