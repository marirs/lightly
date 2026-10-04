package com.lightlylabs.visioneval

import android.content.Context
import android.graphics.Bitmap
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceContour
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetector
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.face.FaceLandmark
import org.json.JSONArray
import org.json.JSONObject

/**
 * ML Kit Face Detection, bundled model (`com.google.mlkit:face-detection`).
 * ACCURATE + all landmarks + all contours + classification. Note ML Kit only computes contours
 * for the most prominent face; other faces get the 10 sparse landmarks only — recorded per face.
 */
class MlKitFaceCandidate(
    override val id: String,
    private val performanceMode: Int,
    private val minFaceSize: Float,
) : VisionCandidate {
    override val kind = CandidateKind.FACE
    override val sdkCoordinate = "com.google.mlkit:face-detection:16.1.7"
    override val modelDescription = "bundled in AAR (statically linked)"
    private lateinit var detector: FaceDetector

    override fun initialise(context: Context): JSONObject {
        val options = FaceDetectorOptions.Builder()
            .setPerformanceMode(performanceMode)
            .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
            .setContourMode(FaceDetectorOptions.CONTOUR_MODE_ALL)
            .setClassificationMode(FaceDetectorOptions.CLASSIFICATION_MODE_ALL)
            .setMinFaceSize(minFaceSize)
            .build()
        detector = FaceDetection.getClient(options)
        return JSONObject()
            .put("performance_mode", if (performanceMode == FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE) "accurate" else "fast")
            .put("min_face_size", minFaceSize.toDouble())
    }

    override fun analyse(photo: Bitmap): CandidateOutput {
        val faces = Tasks.await(detector.process(InputImage.fromBitmap(photo, 0)))
        val facesJson = JSONArray()
        for (face in faces) facesJson.put(faceJson(face, photo.width, photo.height))
        return CandidateOutput(JSONObject().put("faces", facesJson))
    }

    private fun faceJson(face: Face, width: Int, height: Int): JSONObject {
        val landmarks = JSONObject()
        for ((name, type) in LANDMARK_TYPES) {
            face.getLandmark(type)?.let { landmarks.put(name, JsonGeometry.normalisedPoint(it.position, width, height)) }
        }
        val contours = JSONObject()
        for ((name, type) in CONTOUR_TYPES) {
            val points = face.getContour(type)?.points ?: continue
            if (points.isEmpty()) continue
            contours.put(name, JSONArray(points.map { JsonGeometry.normalisedPoint(it, width, height) }))
        }
        return JSONObject()
            .put("box", JsonGeometry.normalisedBox(face.boundingBox, width, height))
            .put("landmarks", landmarks)
            .put("contours", contours)
            .put("has_contours", contours.length() > 0)
            .put("yaw", face.headEulerAngleY.toDouble())
            .put("pitch", face.headEulerAngleX.toDouble())
            .put("roll", face.headEulerAngleZ.toDouble())
            .put("smiling", face.smilingProbability?.toDouble() ?: JSONObject.NULL)
            .put("left_eye_open", face.leftEyeOpenProbability?.toDouble() ?: JSONObject.NULL)
            .put("right_eye_open", face.rightEyeOpenProbability?.toDouble() ?: JSONObject.NULL)
    }

    override fun close() = detector.close()

    companion object {
        // Names follow the SUBJECT's left/right, as ML Kit does.
        private val LANDMARK_TYPES = listOf(
            "left_eye" to FaceLandmark.LEFT_EYE, "right_eye" to FaceLandmark.RIGHT_EYE,
            "nose_base" to FaceLandmark.NOSE_BASE, "mouth_left" to FaceLandmark.MOUTH_LEFT,
            "mouth_right" to FaceLandmark.MOUTH_RIGHT, "mouth_bottom" to FaceLandmark.MOUTH_BOTTOM,
            "left_ear" to FaceLandmark.LEFT_EAR, "right_ear" to FaceLandmark.RIGHT_EAR,
            "left_cheek" to FaceLandmark.LEFT_CHEEK, "right_cheek" to FaceLandmark.RIGHT_CHEEK,
        )
        private val CONTOUR_TYPES = listOf(
            "face" to FaceContour.FACE,
            "left_eyebrow_top" to FaceContour.LEFT_EYEBROW_TOP, "left_eyebrow_bottom" to FaceContour.LEFT_EYEBROW_BOTTOM,
            "right_eyebrow_top" to FaceContour.RIGHT_EYEBROW_TOP, "right_eyebrow_bottom" to FaceContour.RIGHT_EYEBROW_BOTTOM,
            "left_eye" to FaceContour.LEFT_EYE, "right_eye" to FaceContour.RIGHT_EYE,
            "upper_lip_top" to FaceContour.UPPER_LIP_TOP, "upper_lip_bottom" to FaceContour.UPPER_LIP_BOTTOM,
            "lower_lip_top" to FaceContour.LOWER_LIP_TOP, "lower_lip_bottom" to FaceContour.LOWER_LIP_BOTTOM,
            "nose_bridge" to FaceContour.NOSE_BRIDGE, "nose_bottom" to FaceContour.NOSE_BOTTOM,
            "left_cheek" to FaceContour.LEFT_CHEEK, "right_cheek" to FaceContour.RIGHT_CHEEK,
        )

        fun all(): List<VisionCandidate> = listOf(
            MlKitFaceCandidate("mlkit_face_accurate", FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE, 0.05f),
            MlKitFaceCandidate("mlkit_face_fast", FaceDetectorOptions.PERFORMANCE_MODE_FAST, 0.05f),
        )
    }
}
