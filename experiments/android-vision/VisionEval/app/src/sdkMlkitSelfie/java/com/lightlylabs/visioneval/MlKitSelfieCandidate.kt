package com.lightlylabs.visioneval

import android.content.Context
import android.graphics.Bitmap
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.Segmenter
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import org.json.JSONObject

/** ML Kit Selfie Segmentation (beta, bundled, people only). Mask returned at input size. */
class MlKitSelfieCandidate : VisionCandidate {
    override val id = "mlkit_selfie"
    override val kind = CandidateKind.SEGMENTATION
    override val sdkCoordinate = "com.google.mlkit:segmentation-selfie:16.0.0-beta6"
    override val modelDescription = "bundled in AAR"
    private lateinit var segmenter: Segmenter

    override fun initialise(context: Context): JSONObject {
        segmenter = Segmentation.getClient(
            SelfieSegmenterOptions.Builder().setDetectorMode(SelfieSegmenterOptions.SINGLE_IMAGE_MODE).build()
        )
        return JSONObject().put("detector_mode", "SINGLE_IMAGE_MODE").put("raw_size_mask", false)
    }

    override fun analyse(photo: Bitmap): CandidateOutput {
        val mask = Tasks.await(segmenter.process(InputImage.fromBitmap(photo, 0)))
        val confidence = ConfidenceMask.fromByteBuffer(mask.width, mask.height, mask.buffer)
        return CandidateOutput(
            JSONObject().put("mask_width", mask.width).put("mask_height", mask.height),
            mapOf("person" to confidence),
        )
    }

    override fun close() = segmenter.close()

    companion object {
        fun all(): List<VisionCandidate> = listOf(MlKitSelfieCandidate())
    }
}
