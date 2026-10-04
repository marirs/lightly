package com.lightlylabs.visioneval

import android.content.Context
import android.graphics.Bitmap
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.facemesh.FaceMesh
import com.google.mlkit.vision.facemesh.FaceMeshDetection
import com.google.mlkit.vision.facemesh.FaceMeshDetector
import com.google.mlkit.vision.facemesh.FaceMeshDetectorOptions
import org.json.JSONArray
import org.json.JSONObject

/** ML Kit Face Mesh (beta, bundled): 468 3D points; documented max 2 faces, ~2 m selfie range. */
class MlKitFaceMeshCandidate : VisionCandidate {
    override val id = "mlkit_face_mesh"
    override val kind = CandidateKind.FACE
    override val sdkCoordinate = "com.google.mlkit:face-mesh-detection:16.0.0-beta3"
    override val modelDescription = "bundled in AAR"
    private lateinit var detector: FaceMeshDetector

    override fun initialise(context: Context): JSONObject {
        detector = FaceMeshDetection.getClient(
            FaceMeshDetectorOptions.Builder().setUseCase(FaceMeshDetectorOptions.FACE_MESH).build()
        )
        return JSONObject().put("use_case", "FACE_MESH")
    }

    override fun analyse(photo: Bitmap): CandidateOutput {
        val meshes = Tasks.await(detector.process(InputImage.fromBitmap(photo, 0)))
        val facesJson = JSONArray()
        for (mesh in meshes) {
            val width = photo.width.toFloat()
            val height = photo.height.toFloat()
            // z is in the same pixel scale as x; normalise by width for comparability.
            val points = JSONArray(mesh.allPoints.map {
                JsonGeometry.point3(it.position.x / width, it.position.y / height, it.position.z / width)
            })
            val contours = JSONObject()
            for ((name, type) in CONTOUR_TYPES) {
                contours.put(name, JSONArray(mesh.getPoints(type).map {
                    JsonGeometry.point(it.position.x / width, it.position.y / height)
                }))
            }
            facesJson.put(
                JSONObject()
                    .put("box", JsonGeometry.normalisedBox(mesh.boundingBox, photo.width, photo.height))
                    .put("mesh_point_count", mesh.allPoints.size)
                    .put("mesh", points)
                    .put("contours", contours)
                    .put("has_contours", true)
            )
        }
        return CandidateOutput(JSONObject().put("faces", facesJson))
    }

    override fun close() = detector.close()

    companion object {
        private val CONTOUR_TYPES = listOf(
            "face" to FaceMesh.FACE_OVAL,
            "left_eyebrow_top" to FaceMesh.LEFT_EYEBROW_TOP, "left_eyebrow_bottom" to FaceMesh.LEFT_EYEBROW_BOTTOM,
            "right_eyebrow_top" to FaceMesh.RIGHT_EYEBROW_TOP, "right_eyebrow_bottom" to FaceMesh.RIGHT_EYEBROW_BOTTOM,
            "left_eye" to FaceMesh.LEFT_EYE, "right_eye" to FaceMesh.RIGHT_EYE,
            "upper_lip_top" to FaceMesh.UPPER_LIP_TOP, "upper_lip_bottom" to FaceMesh.UPPER_LIP_BOTTOM,
            "lower_lip_top" to FaceMesh.LOWER_LIP_TOP, "lower_lip_bottom" to FaceMesh.LOWER_LIP_BOTTOM,
            "nose_bridge" to FaceMesh.NOSE_BRIDGE,
        )

        fun all(): List<VisionCandidate> = listOf(MlKitFaceMeshCandidate())
    }
}
