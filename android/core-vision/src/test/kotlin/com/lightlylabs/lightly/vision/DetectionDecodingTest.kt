package com.lightlylabs.lightly.vision

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.float
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DetectionDecodingTest {
    @Test
    fun `anchor counts match each model's output tensor`() {
        assertEquals(BlazeFaceDetector.ANCHORS, SsdDecoder.buildAnchors(192, listOf(4), 0.0).size)
        assertEquals(PoseDetector.ANCHORS, SsdDecoder.buildAnchors(224, listOf(8, 16, 32, 32, 32), 1.0).size)
        // Short range (not used; checks the grouping of equal strides): 16²·2 + 8²·6 = 896.
        assertEquals(896, SsdDecoder.buildAnchors(128, listOf(8, 16, 16, 16), 1.0).size)
    }

    @Test
    fun `anchors are cell centres in row-major order`() {
        val anchors = SsdDecoder.buildAnchors(192, listOf(4), 0.0)
        assertEquals(0.5 / 48 to 0.5 / 48, anchors[0])
        assertEquals(1.5 / 48 to 0.5 / 48, anchors[1])
        assertEquals(0.5 / 48 to 1.5 / 48, anchors[48])
    }

    /**
     * The raw full-range BlazeFace outputs for experiments/test-photos/group_three_01.jpg (1600 × 900, as
     * LiteRT returned them; only anchors with a logit above −3 are stored, the rest are far below the
     * threshold) decode to the three faces the numpy reference found (experiments/android-vision/scripts/
     * litert_reference.py).
     */
    @Test
    fun `decodes the group photo's three faces like the reference`() {
        val golden = golden()
        val anchors = golden["anchors"]!!.jsonPrimitive.int
        val logits = FloatArray(anchors) { -100f }
        val regressors = FloatArray(anchors * 16)
        for ((index, entry) in golden["sparse"]!!.jsonObject) {
            val i = index.toInt()
            logits[i] = entry.jsonObject["logit"]!!.jsonPrimitive.float
            entry.jsonObject["reg"]!!.jsonArray.forEachIndexed { k, v -> regressors[i * 16 + k] = v.jsonPrimitive.float }
        }
        val pad = golden["letterbox"]!!.jsonArray
        val letterbox = Letterbox(pad[0].jsonPrimitive.double, pad[1].jsonPrimitive.double)
        // The letterbox the sampler computes for this photo is the reference's.
        assertEquals(letterbox, TensorSampler.letterboxed(RgbaImage(1600, 900, ByteArray(1600 * 900 * 4))).second)

        val decoded = SsdDecoder(192, listOf(4), 0.0, numKeypoints = 6, minScore = 0.6f).decode(regressors, logits, letterbox).sortedBy { it.xMin }
        val expected = golden["faces"]!!.jsonArray.map { it.jsonObject }
        assertEquals(3, decoded.size)
        for ((face, want) in decoded.zip(expected)) {
            assertEquals(want["score"]!!.jsonPrimitive.float, face.score, 1e-5f)
            val box = want["box"]!!.jsonArray.map { it.jsonPrimitive.double }
            assertNear(box, listOf(face.xMin, face.yMin, face.xMax, face.yMax), 1e-4)
            val keypoints = want["keypoints"]!!.jsonArray.flatMap { p -> p.jsonArray.map { it.jsonPrimitive.double } }
            assertNear(keypoints, face.keypoints.flatMap { listOf(it.first, it.second) }, 1e-4)
        }
    }

    @Test
    fun `landmark ROI follows the eye line, scaled 1·5 about the box`() {
        val golden = golden()
        val image = RgbaImage(1600, 900, ByteArray(1600 * 900 * 4))
        for (want in golden["faces"]!!.jsonArray.map { it.jsonObject }) {
            val box = want["box"]!!.jsonArray.map { it.jsonPrimitive.double }
            val keypoints = want["keypoints"]!!.jsonArray.map { p -> p.jsonArray[0].jsonPrimitive.double to p.jsonArray[1].jsonPrimitive.double }
            val detection = Detection(1f, box[0], box[1], box[2], box[3], keypoints)
            val roi = FaceMeshLandmarker(TensorModel { error("not run") }).roi(detection, image)
            val r = want["roi"]!!.jsonArray.map { it.jsonPrimitive.double }
            assertNear(r.take(4), listOf(roi.centreX, roi.centreY, roi.width, roi.height), 1e-3)
            assertEquals(FaceMeshLandmarker.normaliseRadians(r[4]), roi.rotation, 1e-6)
        }
    }

    @Test
    fun `landmarks map back through the rotated ROI`() {
        // A fake mesh model whose 478 points all sit at the tensor's (64, 192): left of centre, below it.
        val raw = FloatArray(478 * 3) { if (it % 3 == 0) 64f else if (it % 3 == 1) 192f else 0f }
        val model = TensorModel { listOf(raw, floatArrayOf(5f)) }
        val image = RgbaImage(400, 200, ByteArray(400 * 200 * 4))
        // Eyes on a line going down-right at 45° in pixels: rotation +π/4.
        val detection = Detection(0.9f, 0.4, 0.3, 0.6, 0.7, listOf(0.45 to 0.4, 0.5 to 0.5, 0.5 to 0.5, 0.5 to 0.6, 0.4 to 0.5, 0.6 to 0.5))
        val landmarker = FaceMeshLandmarker(model)
        val roi = landmarker.roi(detection, image)
        assertEquals(PI / 4, roi.rotation, 1e-9)
        val (points, presence) = landmarker.landmarks(detection, image)
        assertTrue(presence > 0.99f)
        // u = 0.25, v = 0.75 of the ROI: (−0.25, +0.25) of its size, rotated by 45°.
        val (ex, ey) = roi.toPhoto(0.25, 0.75)
        assertEquals(ex / 400, points[0].x, 1e-9)
        assertEquals(ey / 200, points[0].y, 1e-9)
        // Rotation by +45° of (−a, +a) is (−√2·a, 0): straight left of the centre.
        assertEquals(roi.centreY, ey, 1e-6)
        assertTrue(ex < roi.centreX)
    }

    @Test
    fun `weighted NMS merges overlaps by score and keeps separate faces`() {
        fun d(score: Float, x: Double) = Detection(score, x, 0.1, x + 0.2, 0.3, listOf(x to 0.1))
        val merged = SsdDecoder.weightedNms(listOf(d(0.9f, 0.10), d(0.3f, 0.12), d(0.8f, 0.6)), 0.3)
        assertEquals(2, merged.size)
        assertEquals(0.9f, merged[0].score)
        assertEquals((0.10 * 0.9 + 0.12 * 0.3) / 1.2, merged[0].xMin, 1e-9)
        assertEquals(0.6, merged[1].xMin, 1e-12)
    }

    @Test
    fun `stretched and letterboxed tensors sample the photo with a zero border`() {
        // 4 × 2 photo: left half red, right half blue.
        val pixels = ByteArray(4 * 2 * 4)
        for (y in 0 until 2) for (x in 0 until 4) {
            val o = (y * 4 + x) * 4
            if (x < 2) pixels[o] = 0xff.toByte() else pixels[o + 2] = 0xff.toByte()
            pixels[o + 3] = 0xff.toByte()
        }
        val image = RgbaImage(4, 2, pixels)
        val (roi, letterbox) = TensorSampler.letterboxed(image)
        assertEquals(Letterbox(0.0, 0.25), letterbox)
        val tensor = TensorSampler.nhwc(image, roi, 4, 4, ValueRange.SIGNED)
        // Row 0 is padding: −1 everywhere. Row 1, column 0 is red: (1, −1, −1).
        for (c in 0 until 3) assertEquals(-1f, tensor[c], 1e-6f)
        assertEquals(1f, tensor[(1 * 4 + 0) * 3], 1e-6f)
        assertEquals(-1f, tensor[(1 * 4 + 0) * 3 + 2], 1e-6f)
        assertEquals(1f, tensor[(1 * 4 + 3) * 3 + 2], 1e-6f)
    }

    private fun assertNear(expected: List<Double>, actual: List<Double>, tolerance: Double) {
        assertEquals(expected.size, actual.size)
        for (i in expected.indices) assertTrue(abs(expected[i] - actual[i]) <= tolerance, "index $i: expected ${expected[i]}, got ${actual[i]}")
    }

    private fun golden(): JsonObject =
        Json.parseToJsonElement(javaClass.getResource("/blazeface_group_three_01.json")!!.readText()).jsonObject
}
