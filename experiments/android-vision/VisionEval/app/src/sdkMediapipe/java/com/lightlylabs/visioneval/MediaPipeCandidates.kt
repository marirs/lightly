package com.lightlylabs.visioneval

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.framework.image.ByteBufferExtractor
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.components.containers.NormalizedKeypoint
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.facedetector.FaceDetector
import com.google.mediapipe.tasks.vision.facelandmarker.FaceLandmarker
import com.google.mediapipe.tasks.vision.imagesegmenter.ImageSegmenter
import com.google.mediapipe.tasks.vision.imagesegmenter.ImageSegmenterResult
import com.google.mediapipe.tasks.vision.interactivesegmenterlegacy.InteractiveSegmenterLegacy
import org.json.JSONArray
import org.json.JSONObject

/*
 * MediaPipe Tasks Vision candidates. All models are Apache-2.0 files shipped as uncompressed APK
 * assets under assets/models (fetched + sha256-verified by scripts/prepare_assets.sh) and loaded
 * with setModelAssetPath, i.e. memory-mapped from the APK; nothing is downloaded at runtime.
 */

private fun baseOptions(modelAsset: String, delegate: Delegate): BaseOptions =
    BaseOptions.builder().setModelAssetPath("models/$modelAsset").setDelegate(delegate).build()

private fun MPImage.toConfidenceMask(): ConfidenceMask =
    ConfidenceMask.fromByteBuffer(width, height, ByteBufferExtractor.extract(this))

private fun Bitmap.toMpImage(): MPImage = BitmapImageBuilder(this).build()

/** BlazeFace via the Face Detector task: boxes + 6 keypoints (eyes, nose, mouth, ear tragions). */
class MediaPipeFaceDetectorCandidate(
    override val id: String,
    private val modelAsset: String,
) : VisionCandidate {
    override val kind = CandidateKind.FACE
    override val sdkCoordinate = MEDIAPIPE_COORDINATE
    override val modelDescription = "assets/models/$modelAsset (Apache-2.0)"
    private lateinit var detector: FaceDetector

    override fun initialise(context: Context): JSONObject {
        detector = FaceDetector.createFromOptions(
            context,
            FaceDetector.FaceDetectorOptions.builder()
                .setBaseOptions(baseOptions(modelAsset, Delegate.CPU))
                .setRunningMode(RunningMode.IMAGE)
                .setMinDetectionConfidence(0.5f)
                .build()
        )
        return JSONObject().put("delegate", "CPU").put("min_detection_confidence", 0.5)
    }

    override fun analyse(photo: Bitmap): CandidateOutput {
        val result = detector.detect(photo.toMpImage())
        val faces = JSONArray()
        for (detection in result.detections()) {
            val keypoints = detection.keypoints().orElse(emptyList())
            val landmarks = JSONObject()
            // BlazeFace keypoint order; names are the SUBJECT's left/right to match ML Kit.
            keypoints.forEachIndexed { index, keypoint ->
                landmarks.put(BLAZEFACE_KEYPOINTS.getOrElse(index) { "k$index" }, JsonGeometry.point(keypoint.x(), keypoint.y()))
            }
            faces.put(
                JSONObject()
                    .put("box", JsonGeometry.normalisedBox(detection.boundingBox(), photo.width, photo.height))
                    .put("score", detection.categories().firstOrNull()?.score()?.toDouble() ?: JSONObject.NULL)
                    .put("landmarks", landmarks)
                    .put("has_contours", false)
            )
        }
        return CandidateOutput(JSONObject().put("faces", faces))
    }

    override fun close() = detector.close()

    companion object {
        val BLAZEFACE_KEYPOINTS = listOf("right_eye", "left_eye", "nose_tip", "mouth_center", "right_ear_tragion", "left_ear_tragion")
    }
}

/** Face Landmarker (BlazeFace short-range + Face Mesh V2): 478 points incl. irises, up to numFaces. */
class MediaPipeFaceLandmarkerCandidate : VisionCandidate {
    override val id = "mp_face_landmarker"
    override val kind = CandidateKind.FACE
    override val sdkCoordinate = MEDIAPIPE_COORDINATE
    override val modelDescription = "assets/models/face_landmarker.task (Apache-2.0)"
    private lateinit var landmarker: FaceLandmarker

    override fun initialise(context: Context): JSONObject {
        landmarker = FaceLandmarker.createFromOptions(
            context,
            FaceLandmarker.FaceLandmarkerOptions.builder()
                .setBaseOptions(baseOptions("face_landmarker.task", Delegate.CPU))
                .setRunningMode(RunningMode.IMAGE)
                .setNumFaces(MAX_FACES)
                .setMinFaceDetectionConfidence(0.5f)
                .setMinFacePresenceConfidence(0.5f)
                .setOutputFaceBlendshapes(false)
                .build()
        )
        return JSONObject().put("delegate", "CPU").put("num_faces", MAX_FACES)
    }

    override fun analyse(photo: Bitmap): CandidateOutput {
        val result = landmarker.detect(photo.toMpImage())
        val faces = JSONArray()
        for (faceLandmarks in result.faceLandmarks()) {
            var minX = 1f; var minY = 1f; var maxX = 0f; var maxY = 0f
            val mesh = JSONArray()
            for (landmark in faceLandmarks) {
                mesh.put(JsonGeometry.point3(landmark.x(), landmark.y(), landmark.z()))
                minX = minOf(minX, landmark.x()); minY = minOf(minY, landmark.y())
                maxX = maxOf(maxX, landmark.x()); maxY = maxOf(maxY, landmark.y())
            }
            val landmarks = JSONObject()
            if (faceLandmarks.size > RIGHT_IRIS_CENTER) {
                // 468 and 473 are the two iris centres (refined mesh). Naming is nominal: the desktop
                // analysis pairs eyes by image x, so left/right conventions cannot skew the error.
                landmarks.put("right_eye", JsonGeometry.point(faceLandmarks[RIGHT_IRIS_CENTER].x(), faceLandmarks[RIGHT_IRIS_CENTER].y()))
                landmarks.put("left_eye", JsonGeometry.point(faceLandmarks[LEFT_IRIS_CENTER].x(), faceLandmarks[LEFT_IRIS_CENTER].y()))
            }
            faces.put(
                JSONObject()
                    .put("box", JsonGeometry.box(minX, minY, maxX - minX, maxY - minY))
                    .put("mesh_point_count", faceLandmarks.size)
                    .put("mesh", mesh)
                    .put("landmarks", landmarks)
                    .put("has_contours", true)
            )
        }
        return CandidateOutput(JSONObject().put("faces", faces))
    }

    override fun close() = landmarker.close()

    companion object {
        const val MAX_FACES = 10
        const val RIGHT_IRIS_CENTER = 468
        const val LEFT_IRIS_CENTER = 473
    }
}

/**
 * Image Segmenter with one of the published models. [maskMapping] turns the model's per-class
 * confidence masks into named masks (e.g. person = 1 - background for multiclass).
 */
class MediaPipeImageSegmenterCandidate(
    override val id: String,
    private val modelAsset: String,
    private val delegate: Delegate,
    private val maskMapping: (List<ConfidenceMask>) -> Map<String, ConfidenceMask>,
) : VisionCandidate {
    override val kind = CandidateKind.SEGMENTATION
    override val sdkCoordinate = MEDIAPIPE_COORDINATE
    override val modelDescription = "assets/models/$modelAsset (Apache-2.0)"
    private lateinit var segmenter: ImageSegmenter

    override fun initialise(context: Context): JSONObject {
        segmenter = ImageSegmenter.createFromOptions(
            context,
            ImageSegmenter.ImageSegmenterOptions.builder()
                .setBaseOptions(baseOptions(modelAsset, delegate))
                .setRunningMode(RunningMode.IMAGE)
                .setOutputConfidenceMasks(true)
                .setOutputCategoryMask(false)
                .build()
        )
        return JSONObject().put("delegate", delegate.name).put("labels", JSONArray(segmenter.labels))
    }

    override fun analyse(photo: Bitmap): CandidateOutput {
        val result: ImageSegmenterResult = segmenter.segment(photo.toMpImage())
        val confidenceImages = result.confidenceMasks().orElse(emptyList())
        val masks = confidenceImages.map { it.toConfidenceMask() }
        confidenceImages.forEach { it.close() }
        return CandidateOutput(
            JSONObject().put("class_count", masks.size)
                .put("mask_width", masks.firstOrNull()?.width ?: 0).put("mask_height", masks.firstOrNull()?.height ?: 0),
            maskMapping(masks),
        )
    }

    override fun close() = segmenter.close()
}

/**
 * Interactive segmenter (magic_touch) seeded automatically: centre of the largest BlazeFace face,
 * else the image centre. In the product the seed would be a user tap; this measures how well an
 * automatic seed recovers "the main subject". The seed detection is timed separately (seed_ms).
 */
class MediaPipeInteractiveCandidate : VisionCandidate {
    override val id = "mp_interactive_seeded"
    override val kind = CandidateKind.SEGMENTATION
    override val sdkCoordinate = MEDIAPIPE_COORDINATE
    override val modelDescription = "assets/models/magic_touch.tflite + blaze_face_short_range.tflite (Apache-2.0)"
    private lateinit var segmenter: InteractiveSegmenterLegacy
    private lateinit var seedDetector: FaceDetector

    override fun initialise(context: Context): JSONObject {
        segmenter = InteractiveSegmenterLegacy.createFromOptions(
            context,
            InteractiveSegmenterLegacy.InteractiveSegmenterLegacyOptions.builder()
                .setBaseOptions(baseOptions("magic_touch.tflite", Delegate.CPU))
                .setOutputConfidenceMasks(true)
                .setOutputCategoryMask(false)
                .build()
        )
        seedDetector = FaceDetector.createFromOptions(
            context,
            FaceDetector.FaceDetectorOptions.builder()
                .setBaseOptions(baseOptions("blaze_face_short_range.tflite", Delegate.CPU))
                .setRunningMode(RunningMode.IMAGE)
                .build()
        )
        return JSONObject().put("delegate", "CPU").put("api", "InteractiveSegmenterLegacy (RegionOfInterest keypoint)")
    }

    override fun analyse(photo: Bitmap): CandidateOutput {
        val image = photo.toMpImage()
        val seedStart = SystemClock.elapsedRealtimeNanos()
        val largestFace = seedDetector.detect(image).detections().maxByOrNull { it.boundingBox().width() * it.boundingBox().height() }
        val seedX = largestFace?.boundingBox()?.centerX()?.div(photo.width) ?: 0.5f
        val seedY = largestFace?.boundingBox()?.centerY()?.div(photo.height) ?: 0.5f
        val seedMs = EvalRunner.elapsedMs(seedStart)
        val result = segmenter.segment(image, InteractiveSegmenterLegacy.RegionOfInterest.create(NormalizedKeypoint.create(seedX, seedY)))
        val confidenceImages = result.confidenceMasks().orElse(emptyList())
        val masks = confidenceImages.map { it.toConfidenceMask() }
        confidenceImages.forEach { it.close() }
        val subject = masks.lastOrNull()
        return CandidateOutput(
            JSONObject().put("seed", JsonGeometry.point(seedX, seedY)).put("seed_source", if (largestFace != null) "face" else "centre")
                .put("seed_ms", seedMs).put("class_count", masks.size),
            if (subject != null) mapOf("subject" to subject) else emptyMap(),
        )
    }

    override fun close() {
        segmenter.close()
        seedDetector.close()
    }
}

const val MEDIAPIPE_COORDINATE = "com.google.mediapipe:tasks-vision:1.0.0"

object MediaPipeCandidates {
    /** Single-output models give P(person); multi-output models give P(background) first. */
    private fun personFromSelfie(masks: List<ConfidenceMask>): Map<String, ConfidenceMask> = when {
        masks.isEmpty() -> emptyMap()
        masks.size == 1 -> mapOf("person" to masks[0])
        else -> mapOf("person" to masks.last())
    }

    // selfie_multiclass_256x256 labels: 0 background, 1 hair, 2 body-skin, 3 face-skin, 4 clothes, 5 others.
    private fun multiclass(masks: List<ConfidenceMask>): Map<String, ConfidenceMask> = if (masks.size < 6) emptyMap() else mapOf(
        "person" to ConfidenceMask.inverted(masks[0]),
        "hair" to masks[1],
        "body_skin" to masks[2],
        "face_skin" to masks[3],
        "clothes" to masks[4],
    )

    private fun hair(masks: List<ConfidenceMask>): Map<String, ConfidenceMask> =
        masks.lastOrNull()?.let { mapOf("hair" to it) } ?: emptyMap()

    // deeplab_v3 (PASCAL VOC): 0 background ... 15 person.
    private fun deeplab(masks: List<ConfidenceMask>): Map<String, ConfidenceMask> = if (masks.size < 16) emptyMap() else mapOf(
        "foreground" to ConfidenceMask.inverted(masks[0]),
        "person" to masks[15],
    )

    fun all(): List<VisionCandidate> = listOf(
        MediaPipeFaceDetectorCandidate("mp_face_short", "blaze_face_short_range.tflite"),
        MediaPipeFaceDetectorCandidate("mp_face_full", "blaze_face_full_range.tflite"),
        MediaPipeFaceLandmarkerCandidate(),
        MediaPipeImageSegmenterCandidate("mp_selfie_square", "selfie_segmenter.tflite", Delegate.CPU, ::personFromSelfie),
        MediaPipeImageSegmenterCandidate("mp_selfie_landscape", "selfie_segmenter_landscape.tflite", Delegate.CPU, ::personFromSelfie),
        MediaPipeImageSegmenterCandidate("mp_multiclass", "selfie_multiclass_256x256.tflite", Delegate.CPU, ::multiclass),
        MediaPipeImageSegmenterCandidate("mp_multiclass_gpu", "selfie_multiclass_256x256.tflite", Delegate.GPU, ::multiclass),
        MediaPipeImageSegmenterCandidate("mp_hair", "hair_segmenter.tflite", Delegate.CPU, ::hair),
        MediaPipeImageSegmenterCandidate("mp_deeplab", "deeplab_v3.tflite", Delegate.CPU, ::deeplab),
        MediaPipeInteractiveCandidate(),
    )
}
