package com.lightlylabs.lightly.vision

import com.lightlylabs.lightly.session.ModelRef
import com.lightlylabs.lightly.session.NormalisedRect
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

/** A normalised point (top-left origin). */
data class Point(val x: Double, val y: Double)

/**
 * One detected face, normalised to the photo (top-left origin).
 *
 * [box] is the face box in Apple Vision's sense (VNFaceObservation.boundingBox), estimated from the
 * Face Mesh oval so that iOS's ring proportion applies unchanged (see [visionBoxFromOval]). It is the
 * face's identity in the recipe (`tools.portrait.faces[].face.box`).
 */
data class DetectedFace(
    val box: NormalisedRect,
    val score: Float,
    /** Face Mesh presence (sigmoid), 0…1; below 0.5 the landmarks are not a face. */
    val landmarkPresence: Float,
    /** The 478 Face Mesh V2 landmarks; empty when the landmark model did not run. */
    val landmarks: List<Point>,
) {
    val faceContour get() = region(FaceMeshRegions.FACE_OVAL)
    /** The eye on the image's left (the subject's right eye). */
    val imageLeftEye get() = region(FaceMeshRegions.IMAGE_LEFT_EYE)
    val imageRightEye get() = region(FaceMeshRegions.IMAGE_RIGHT_EYE)
    val imageLeftEyebrow get() = region(FaceMeshRegions.IMAGE_LEFT_EYEBROW)
    val imageRightEyebrow get() = region(FaceMeshRegions.IMAGE_RIGHT_EYEBROW)
    val outerLips get() = region(FaceMeshRegions.OUTER_LIPS)
    val innerLips get() = region(FaceMeshRegions.INNER_LIPS)

    private fun region(indices: IntArray): List<Point> = if (landmarks.size < FaceMeshRegions.LANDMARK_COUNT) emptyList() else indices.map { landmarks[it] }

    /**
     * The ellipse the face ring follows: the approved prototype's ring-to-face proportion measured
     * against Vision's box (iOS SceneAnalysis.swift `DetectedFace.ring`, 5c3a3ee): 0.86 × the box
     * width, 1.33 × its height, same horizontal centre, centre raised by 0.05 × the box height.
     */
    val ring: NormalisedRect
        get() {
            val width = box.width * RING_WIDTH_SCALE
            val height = box.height * RING_HEIGHT_SCALE
            val centreX = box.x + box.width / 2
            val centreY = box.y + box.height / 2 - box.height * RING_CENTRE_RAISE
            return clampedRect(centreX - width / 2, centreY - height / 2, width, height)
        }

    /**
     * Usable for Portrait (approved "No face can be edited": too small, turned away or too dark): at
     * least 5 % of the frame each way, with landmarks the mesh model accepts as a face.
     * v3 differs: iOS also requires Vision's face capture quality ≥ 0.2; no equivalent model ships on
     * Android, so the mesh presence score stands in (docs/v1/android-vision-evaluation.md §4).
     */
    val isUsable: Boolean
        get() = box.width >= MIN_FACE_FRACTION && box.height >= MIN_FACE_FRACTION && landmarkPresence >= MIN_LANDMARK_PRESENCE && landmarks.isNotEmpty()

    companion object {
        const val RING_WIDTH_SCALE = 0.86
        const val RING_HEIGHT_SCALE = 1.33
        const val RING_CENTRE_RAISE = 0.05
        const val MIN_FACE_FRACTION = 0.05
        const val MIN_LANDMARK_PRESENCE = 0.5f

        /** Recorded with Portrait edits (`face.detector`): the detector and the mesh model that drew the box. */
        val DETECTOR = ModelRef("mediapipe-blazeface-full-facemesh-v2", "3698b18f-c7d54204")

        /**
         * Vision's face box from the Face Mesh oval's bounding box, both in photo pixels. Measured on the
         * seven faces of the evaluation photos (portrait_medium_02, portrait_deep_02/03, portrait_light_01,
         * group_three_01 × 3), median of each ratio against macOS Vision's box:
         * width 1.108 × the oval width, height 0.886 × the oval height, centre lowered 0.022 × the oval height.
         */
        const val OVAL_TO_VISION_WIDTH = 1.108
        const val OVAL_TO_VISION_HEIGHT = 0.886
        const val OVAL_TO_VISION_CENTRE_DROP = 0.022

        fun visionBoxFromOval(oval: List<Point>): NormalisedRect {
            val x0 = oval.minOf { it.x }
            val x1 = oval.maxOf { it.x }
            val y0 = oval.minOf { it.y }
            val y1 = oval.maxOf { it.y }
            val width = (x1 - x0) * OVAL_TO_VISION_WIDTH
            val height = (y1 - y0) * OVAL_TO_VISION_HEIGHT
            val centreX = (x0 + x1) / 2
            val centreY = (y0 + y1) / 2 + (y1 - y0) * OVAL_TO_VISION_CENTRE_DROP
            return clampedRect(centreX - width / 2, centreY - height / 2, width, height)
        }

        /** A rect inside the unit frame (the recipe rejects anything outside it). */
        fun clampedRect(x: Double, y: Double, width: Double, height: Double): NormalisedRect {
            val x0 = x.coerceIn(0.0, 1.0)
            val y0 = y.coerceIn(0.0, 1.0)
            val x1 = (x + width).coerceIn(x0, 1.0)
            val y1 = (y + height).coerceIn(y0, 1.0)
            return NormalisedRect(x0, y0, x1 - x0, y1 - y0)
        }
    }
}

/** Closed polygons of the Face Mesh topology (mediapipe/python/solutions/face_mesh_connections.py). */
object FaceMeshRegions {
    const val LANDMARK_COUNT = 478
    val FACE_OVAL = intArrayOf(10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288, 397, 365, 379, 378, 400, 377, 152, 148, 176, 149, 150, 136,
        172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109)
    /** FACEMESH_RIGHT_EYE (the subject's right eye, on the image's left). */
    val IMAGE_LEFT_EYE = intArrayOf(33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246)
    /** FACEMESH_LEFT_EYE. */
    val IMAGE_RIGHT_EYE = intArrayOf(263, 249, 390, 373, 374, 380, 381, 382, 362, 398, 384, 385, 386, 387, 388, 466)
    /** FACEMESH_RIGHT_EYEBROW: lower edge, then the upper edge back. */
    val IMAGE_LEFT_EYEBROW = intArrayOf(46, 53, 52, 65, 55, 107, 66, 105, 63, 70)
    val IMAGE_RIGHT_EYEBROW = intArrayOf(276, 283, 282, 295, 285, 336, 296, 334, 293, 300)
    val OUTER_LIPS = intArrayOf(61, 146, 91, 181, 84, 17, 314, 405, 321, 375, 291, 409, 270, 269, 267, 0, 37, 39, 40, 185)
    val INNER_LIPS = intArrayOf(78, 95, 88, 178, 87, 14, 317, 402, 318, 324, 308, 415, 310, 311, 312, 13, 82, 81, 80, 191)
}

/**
 * BlazeFace full range (face_detection_full_range.pbtxt, face_detector_graph.cc): letterboxed 192 × 192,
 * RGB in [−1, 1], one 48 × 48 anchor layer, threshold 0.6, weighted NMS 0.3.
 * The short-range model misses a face of group_three_01 (evaluation §4), so it is not used.
 */
class BlazeFaceDetector(private val model: TensorModel) {
    private val decoder = SsdDecoder(INPUT, listOf(4), interpolatedScaleAspectRatio = 0.0, numKeypoints = 6, minScore = MIN_SCORE)

    fun detect(image: RgbaImage): List<Detection> {
        val (roi, letterbox) = TensorSampler.letterboxed(image)
        val outputs = model.run(TensorSampler.nhwc(image, roi, INPUT, INPUT, ValueRange.SIGNED))
        return decoder.decode(outputs[0], outputs[1], letterbox)
    }

    companion object {
        const val INPUT = 192
        const val MIN_SCORE = 0.6f
        /** Outputs: regressors [1, 2304, 16], classifier logits [1, 2304, 1]. */
        const val ANCHORS = 2304
    }
}

/**
 * Face Mesh V2 (`face_landmarks_detector.tflite` of face_landmarker.task, face_landmarks_detector_graph.cc):
 * ROI = the detection box × 1.5 about its centre, rotated so the eye keypoints (0 → 1) lie
 * horizontal (DetectionsToRects + RectTransformation of face_detector_graph.cc); sampled to 256 × 256
 * RGB in [0, 1] without keeping the aspect; 478 × (x, y, z) in tensor pixels; presence = sigmoid.
 */
class FaceMeshLandmarker(private val model: TensorModel) {
    fun roi(detection: Detection, image: RgbaImage): RotatedRect {
        val w = image.width.toDouble()
        val h = image.height.toDouble()
        val (x0, y0) = detection.keypoints[0]
        val (x1, y1) = detection.keypoints[1]
        // ComputeRotation: target angle 0 − atan2(−Δy, Δx) in pixels, normalised to [−π, π).
        val rotation = normaliseRadians(-atan2(-(y1 - y0) * h, (x1 - x0) * w))
        return RotatedRect(detection.centreX * w, detection.centreY * h, detection.width * w * ROI_SCALE, detection.height * h * ROI_SCALE, rotation)
    }

    /** The landmarks (normalised photo coordinates) and presence for one detection. */
    fun landmarks(detection: Detection, image: RgbaImage): Pair<List<Point>, Float> {
        val roi = roi(detection, image)
        val outputs = model.run(TensorSampler.nhwc(image, roi, INPUT, INPUT, ValueRange.UNIT))
        val raw = outputs[0]
        require(raw.size == FaceMeshRegions.LANDMARK_COUNT * 3) { "expected 478 × 3 landmark values, got ${raw.size}" }
        val presence = (1.0 / (1.0 + exp(-outputs[1][0].toDouble()))).toFloat()
        val points = List(FaceMeshRegions.LANDMARK_COUNT) { i ->
            // Tensor pixels → the ROI's unit square → photo pixels (the inverse of the crop) → normalised.
            val (px, py) = roi.toPhoto(raw[i * 3] / INPUT.toDouble(), raw[i * 3 + 1] / INPUT.toDouble())
            Point(px / image.width, py / image.height)
        }
        return points to presence
    }

    companion object {
        const val INPUT = 256
        const val ROI_SCALE = 1.5

        fun normaliseRadians(angle: Double): Double {
            var a = (angle + PI) % (2 * PI)
            if (a < 0) a += 2 * PI
            return a - PI
        }
    }
}

/**
 * The pose detector of pose_landmarker_lite.task (pose_detection_cpu.pbtxt): letterboxed 224 × 224,
 * [−1, 1], anchors from strides 8/16/32/32/32 (2254), threshold 0.5, weighted NMS 0.3. Used only to
 * know that a person is in the photo when no usable face is (iOS: VNDetectHumanRectanglesRequest).
 * Its box is the person's face region, which is what the approved dim rings mark.
 */
class PoseDetector(private val model: TensorModel) {
    private val decoder = SsdDecoder(INPUT, listOf(8, 16, 32, 32, 32), interpolatedScaleAspectRatio = 1.0, numKeypoints = 4, minScore = MIN_SCORE)

    fun detect(image: RgbaImage): List<Detection> {
        val (roi, letterbox) = TensorSampler.letterboxed(image)
        val outputs = model.run(TensorSampler.nhwc(image, roi, INPUT, INPUT, ValueRange.SIGNED))
        return decoder.decode(outputs[0], outputs[1], letterbox)
    }

    companion object {
        const val INPUT = 224
        const val MIN_SCORE = 0.5f
        const val ANCHORS = 2254
    }
}

/** What Portrait and Background need to know about people (iOS `PeopleAnalysis`). */
data class PeopleAnalysis(
    /** Faces, left to right ("Face 1, 2, 3" read as the photo does). */
    val faces: List<DetectedFace>,
    /** People without a usable face (the approved dim rings), normalised. */
    val people: List<NormalisedRect>,
) {
    val hasPerson get() = faces.isNotEmpty() || people.isNotEmpty()
    /** Left to right whatever order they were given in ("Face 1, 2, 3" read as the photo does). */
    val usableFaces get() = faces.filter { it.isUsable }.sortedBy { it.box.x }

    companion object {
        val NONE = PeopleAnalysis(emptyList(), emptyList())
    }
}

/**
 * Faces with landmarks, plus people the face detector cannot see (turned away, backlit). Any model may
 * be absent (null): the analysis then reports what the others found.
 */
class PeopleAnalyser(
    private val faces: BlazeFaceDetector?,
    private val landmarker: FaceMeshLandmarker?,
    private val poses: PoseDetector?,
) {
    companion object {
        /**
         * Person presence from the pose detector needs a higher score than its own 0.5 threshold. On the
         * evaluation photos the highest score without a person was 0.53 (landscape_02, the approved
         * bg-no-subject lake, at the editor's 1024 px analysis size: Portrait would have been offered)
         * and the lowest with one 0.67 (group_three_01); 0.6 separates them.
         */
        const val MIN_PERSON_SCORE = 0.6f
    }

    /** The same detectors without the landmark model: enough to know whether people are there. */
    fun withoutLandmarks() = PeopleAnalyser(faces, null, poses)

    fun analyse(image: RgbaImage): PeopleAnalysis {
        val detections = faces?.detect(image).orEmpty()
        val detected = detections.map { detection ->
            val (points, presence) = landmarker?.landmarks(detection, image) ?: (emptyList<Point>() to 0f)
            val box = if (presence >= DetectedFace.MIN_LANDMARK_PRESENCE && points.isNotEmpty()) DetectedFace.visionBoxFromOval(FaceMeshRegions.FACE_OVAL.map { points[it] })
            else DetectedFace.clampedRect(detection.xMin, detection.yMin, detection.width, detection.height)
            DetectedFace(box, detection.score, presence, if (presence >= DetectedFace.MIN_LANDMARK_PRESENCE) points else emptyList())
        }.sortedBy { it.box.x }
        val people = poses?.detect(image).orEmpty()
            .filter { it.score >= MIN_PERSON_SCORE }
            .map { DetectedFace.clampedRect(it.xMin, it.yMin, it.width, it.height) }
            .filter { person -> detected.none { overlaps(person, it.box) } }
        return PeopleAnalysis(detected, people)
    }

    private fun overlaps(a: NormalisedRect, b: NormalisedRect) =
        min(a.x + a.width, b.x + b.width) > max(a.x, b.x) && min(a.y + a.height, b.y + b.height) > max(a.y, b.y)
}
