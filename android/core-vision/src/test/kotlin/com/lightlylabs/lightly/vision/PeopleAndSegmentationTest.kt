package com.lightlylabs.lightly.vision

import com.lightlylabs.lightly.background.FloatPlane
import com.lightlylabs.lightly.background.SegmentationUnavailableException
import com.lightlylabs.lightly.session.NormalisedRect
import kotlinx.coroutines.runBlocking
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PeopleAndSegmentationTest {
    private val blank = RgbaImage(64, 48, ByteArray(64 * 48 * 4))

    @Test
    fun `the ring uses iOS's ring-to-face proportion`() {
        val face = DetectedFace(NormalisedRect(0.4, 0.2, 0.2, 0.3), 0.9f, 1f, emptyList())
        val ring = face.ring
        assertEquals(0.2 * 0.86, ring.width, 1e-12)
        assertEquals(0.3 * 1.33, ring.height, 1e-12)
        assertEquals(0.5, ring.x + ring.width / 2, 1e-12)
        assertEquals(0.35 - 0.3 * 0.05, ring.y + ring.height / 2, 1e-12)
    }

    @Test
    fun `Vision's box is estimated from the mesh oval`() {
        val oval = listOf(Point(0.4, 0.2), Point(0.6, 0.2), Point(0.6, 0.5), Point(0.4, 0.5))
        val box = DetectedFace.visionBoxFromOval(oval)
        assertEquals(0.2 * 1.108, box.width, 1e-12)
        assertEquals(0.3 * 0.886, box.height, 1e-12)
        assertEquals(0.5, box.x + box.width / 2, 1e-12)
        assertEquals(0.35 + 0.3 * 0.022, box.y + box.height / 2, 1e-12)
    }

    @Test
    fun `a face is usable only when big enough and the mesh accepts it`() {
        val mesh = List(FaceMeshRegions.LANDMARK_COUNT) { Point(0.5, 0.5) }
        assertTrue(DetectedFace(NormalisedRect(0.4, 0.2, 0.2, 0.3), 0.9f, 0.9f, mesh).isUsable)
        assertFalse(DetectedFace(NormalisedRect(0.4, 0.2, 0.04, 0.3), 0.9f, 0.9f, mesh).isUsable, "too small")
        assertFalse(DetectedFace(NormalisedRect(0.4, 0.2, 0.2, 0.3), 0.9f, 0.1f, mesh).isUsable, "the mesh rejects it")
        assertFalse(DetectedFace(NormalisedRect(0.4, 0.2, 0.2, 0.3), 0.9f, 0.9f, emptyList()).isUsable, "no landmarks")
    }

    @Test
    fun `faces are ordered left to right and people under a face are not counted twice`() {
        // Two faces from a fake detector (right one first), a pose detection over the left face and one elsewhere.
        val faceOutputs = fakeSsd(2304, 16, mapOf(48 * 24 + 36 to (0.70 to 0.5), 48 * 24 + 12 to (0.25 to 0.5)), 192)
        val poseOutputs = fakeSsd(2254, 12, mapOf(0 to (0.25 to 0.5), 5 to (0.9 to 0.1)), 224)
        val analyser = PeopleAnalyser(BlazeFaceDetector { faceOutputs }, null, PoseDetector { poseOutputs })
        val analysis = analyser.analyse(RgbaImage(100, 100, ByteArray(100 * 100 * 4)))
        assertEquals(2, analysis.faces.size)
        assertTrue(analysis.faces[0].box.x < analysis.faces[1].box.x)
        // Without the mesh no face is usable, so Portrait shows "No face can be edited" with dim rings.
        assertTrue(analysis.usableFaces.isEmpty())
        assertEquals(1, analysis.people.size, "the pose box over the left face is the same person")
        assertTrue(analysis.hasPerson)
    }

    @Test
    fun `no models means no people`() {
        assertFalse(PeopleAnalyser(null, null, null).analyse(blank).hasPerson)
    }

    @Test
    fun `without a class-agnostic model a photo without people cannot be judged`() {
        val segmenter = VisionSubjectSegmenter({ PeopleAnalysis.NONE }, { PersonSegmenter { listOf(FloatArray(256 * 256) { 1f }) } }, { null })
        assertFailsWith<SegmentationUnavailableException> { runBlocking { segmenter.segment(blank.pixels, blank.width, blank.height) } }
    }

    @Test
    fun `people get the person matte at the photo's size`() {
        val people = PeopleAnalysis(listOf(DetectedFace(NormalisedRect(0.4, 0.2, 0.2, 0.3), 0.9f, 1f, emptyList())), emptyList())
        val segmenter = VisionSubjectSegmenter({ people }, { PersonSegmenter { listOf(FloatArray(256 * 256) { if (it % 256 < 128) 1f else 0f }) } }, { null })
        val matte = assertNotNull(runBlocking { segmenter.segment(blank.pixels, blank.width, blank.height) })
        assertEquals(64, matte.width)
        assertEquals(48, matte.height)
        assertTrue(matte[5, 20] > 0.9f)
        assertTrue(matte[60, 20] < 0.1f)
    }

    @Test
    fun `the subject model decides no clear subject, and people are added to its matte`() {
        val empty = SubjectSaliency { listOf(FloatArray(320 * 320)) }
        assertNull(runBlocking { VisionSubjectSegmenter({ PeopleAnalysis.NONE }, { null }, { empty }).segment(blank.pixels, 64, 48) })
        val boat = SubjectSaliency { listOf(FloatArray(320 * 320) { if (it / 320 > 200) 1f else 0f }) }
        val matte = assertNotNull(runBlocking { VisionSubjectSegmenter({ PeopleAnalysis.NONE }, { null }, { boat }).segment(blank.pixels, 64, 48) })
        assertTrue(matte[32, 45] > 0.9f)
        assertTrue(matte[32, 5] < 0.1f)
    }

    @Test
    fun `U2-Netp input is max-normalised, ImageNet-standardised, NCHW`() {
        // Larger than the tensor, so every sample lies inside the photo (no zero border mixed in).
        val grey = RgbaImage(640, 640, ByteArray(640 * 640 * 4) { if (it % 4 == 3) -1 else 64 })
        val input = SubjectSaliency { error("not run") }.input(grey)
        assertEquals(3 * 320 * 320, input.size)
        // Every pixel equals the maximum, so each channel is (1 − mean) / std.
        assertEquals((1 - 0.485f) / 0.229f, input[0], 1e-4f)
        assertEquals((1 - 0.456f) / 0.224f, input[320 * 320], 1e-4f)
        assertEquals((1 - 0.406f) / 0.225f, input[2 * 320 * 320], 1e-4f)
    }

    @Test
    fun `the refined matte stays within 0 and 1 and follows the low-resolution matte`() {
        val low = FloatPlane(4, 4, FloatArray(16) { if (it % 4 < 2) 1f else 0f })
        val refined = MatteRefiner.refine(low, blank)
        assertTrue(refined.values.all { it in 0f..1f })
        assertTrue(refined[2, 24] > 0.9f && refined[61, 24] < 0.1f)
    }

    /**
     * Raw SSD outputs with one confident detection per entry: anchor index → (centre x, centre y) in
     * the letterboxed tensor, a box 0.1 of the tensor wide, keypoints at the centre.
     */
    private fun fakeSsd(anchors: Int, coords: Int, hits: Map<Int, Pair<Double, Double>>, size: Int): List<FloatArray> {
        val reg = FloatArray(anchors * coords)
        val logits = FloatArray(anchors) { -50f }
        val positions = SsdDecoder.buildAnchors(size, if (anchors == 2304) listOf(4) else listOf(8, 16, 32, 32, 32), if (anchors == 2304) 0.0 else 1.0)
        for ((i, centre) in hits) {
            logits[i] = 10f
            val (ax, ay) = positions[i]
            reg[i * coords] = ((centre.first - ax) * size).toFloat()
            reg[i * coords + 1] = ((centre.second - ay) * size).toFloat()
            reg[i * coords + 2] = (0.1 * size).toFloat()
            reg[i * coords + 3] = (0.1 * size).toFloat()
            for (k in 0 until (coords - 4) / 2) {
                reg[i * coords + 4 + 2 * k] = reg[i * coords]
                reg[i * coords + 5 + 2 * k] = reg[i * coords + 1]
            }
        }
        return listOf(reg, logits)
    }
}
