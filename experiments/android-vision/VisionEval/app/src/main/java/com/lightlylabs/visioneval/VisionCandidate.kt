package com.lightlylabs.visioneval

import android.content.Context
import android.graphics.Bitmap
import org.json.JSONObject

enum class CandidateKind { FACE, SEGMENTATION }

/**
 * One SDK + model + configuration under evaluation. Implementations live in the per-SDK source
 * sets (src/sdkXxx/java) and are listed by the flavour's CandidateRegistry.
 *
 * Contract used by [EvalRunner]:
 *  - [initialise] is called exactly once per process (each candidate runs in a fresh process, so
 *    this is a true cold start) and may block, e.g. for a Play services module download.
 *  - [analyse] is called repeatedly on the same bitmap (1 cold + N warm runs); only the first
 *    output is persisted, so implementations must be deterministic and side-effect free.
 */
interface VisionCandidate : AutoCloseable {
    val id: String
    val kind: CandidateKind
    /** Maven coordinate(s) of the SDK, recorded verbatim in the results. */
    val sdkCoordinate: String
    /** Model file(s) shipped in the APK (asset names) or "bundled in AAR" / "Play services module". */
    val modelDescription: String

    fun initialise(context: Context): JSONObject

    fun analyse(photo: Bitmap): CandidateOutput

    override fun close() {}
}

/**
 * [details] holds detections in normalised [0,1] image coordinates (origin top-left) so the
 * desktop analysis can compare candidates and phones at any resolution.
 */
class CandidateOutput(
    val details: JSONObject,
    val masks: Map<String, ConfidenceMask> = emptyMap(),
)

/** Row-major per-pixel confidence in [0,1]; [width]x[height] covers the full input image. */
class ConfidenceMask(val width: Int, val height: Int, val values: FloatArray) {
    init {
        require(values.size == width * height) { "mask ${width}x$height has ${values.size} values" }
    }

    companion object {
        /** Reads [width]*[height] floats from a buffer that may be positioned anywhere / any order. */
        fun fromFloatBuffer(width: Int, height: Int, buffer: java.nio.FloatBuffer): ConfidenceMask {
            val values = FloatArray(width * height)
            buffer.rewind()
            buffer.get(values)
            return ConfidenceMask(width, height, values)
        }

        fun fromByteBuffer(width: Int, height: Int, buffer: java.nio.ByteBuffer): ConfidenceMask {
            buffer.rewind()
            return fromFloatBuffer(width, height, buffer.order(java.nio.ByteOrder.nativeOrder()).asFloatBuffer())
        }

        /** 1 - x, e.g. person = 1 - background for multi-class segmenters. */
        fun inverted(source: ConfidenceMask): ConfidenceMask =
            ConfidenceMask(source.width, source.height, FloatArray(source.values.size) { 1f - source.values[it] })
    }
}
