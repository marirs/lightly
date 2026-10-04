package com.lightlylabs.lightly.editor

import android.content.Context
import com.lightlylabs.lightly.vision.BlazeFaceDetector
import com.lightlylabs.lightly.vision.FaceMeshLandmarker
import com.lightlylabs.lightly.vision.PeopleAnalyser
import com.lightlylabs.lightly.vision.PersonSegmenter
import com.lightlylabs.lightly.vision.PoseDetector
import com.lightlylabs.lightly.vision.TensorModel
import org.tensorflow.lite.Interpreter
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel

/**
 * The MediaPipe vision models (assets/vision, bundled by BundleVisionModelsTask) on the standalone
 * LiteRT runtime: no MediaPipe Tasks, no Play services, no network (docs/v1/android-vision-evaluation.md).
 * Each model is loaded on first use and kept for the process; every call is serialised per model,
 * because an Interpreter is not thread-safe.
 *
 * Without the assets (a release build without -PlightlyVisionModels=true, or a checkout without
 * experiments/android-vision/models) every accessor returns null: Portrait stays hidden in release
 * and people-dependent Background paths show the approved failure state.
 */
class LiteRtVisionModels private constructor(private val context: Context) {
    private val faceDetector by lazy { load(FACE_DETECTOR, listOf(lastDim(16), lastDim(1))) }
    private val faceMesh by lazy { load(FACE_MESH, listOf(elements(478 * 3), named("Identity_1"))) }
    private val poseDetector by lazy { load(POSE_DETECTOR, listOf(lastDim(12), lastDim(1))) }
    private val selfie by lazy { load(SELFIE, listOf(elements(256 * 256))) }

    fun peopleAnalyser(): PeopleAnalyser? {
        val faces = faceDetector ?: return null
        return PeopleAnalyser(BlazeFaceDetector(faces), faceMesh?.let(::FaceMeshLandmarker), poseDetector?.let(::PoseDetector))
    }

    fun personSegmenter(): PersonSegmenter? = selfie?.let(::PersonSegmenter)

    /** Picks one output tensor by its shape (or name); the adapter returns outputs in the order listed. */
    private fun interface OutputSelector {
        fun matches(shape: IntArray, name: String): Boolean
    }

    private fun lastDim(size: Int) = OutputSelector { shape, _ -> shape.last() == size && shape.fold(1) { a, b -> a * b } > size }
    private fun elements(count: Int) = OutputSelector { shape, _ -> shape.fold(1) { a, b -> a * b } == count }
    private fun named(name: String) = OutputSelector { _, tensorName -> tensorName == name }

    private fun load(asset: String, outputs: List<OutputSelector>): TensorModel? = try {
        val buffer = context.assets.openFd("vision/$asset").use { descriptor ->
            FileInputStream(descriptor.fileDescriptor).channel.use { channel ->
                channel.map(FileChannel.MapMode.READ_ONLY, descriptor.startOffset, descriptor.declaredLength)
            }
        }
        // As the depth model: XNNPACK on devices; the arm64 emulator on Apple-silicon hosts dies with
        // SIGILL in XNNPACK's initialisation, so it runs the built-in kernels there.
        val interpreter = Interpreter(buffer, Interpreter.Options().setNumThreads(4).setUseXNNPACK(!isEmulator()))
        val indices = outputs.map { selector ->
            (0 until interpreter.outputTensorCount).firstOrNull { i ->
                val tensor = interpreter.getOutputTensor(i)
                selector.matches(tensor.shape(), tensor.name())
            } ?: throw IllegalStateException("$asset has no output matching the expected contract")
        }
        LiteRtTensorModel(interpreter, indices)
    } catch (failure: Exception) {
        android.util.Log.w(LOG_TAG, "vision model $asset unavailable: $failure")
        null
    } catch (nativeMissing: UnsatisfiedLinkError) {
        android.util.Log.w(LOG_TAG, "LiteRT native library unavailable: $nativeMissing")
        null
    }

    private class LiteRtTensorModel(private val interpreter: Interpreter, private val outputIndices: List<Int>) : TensorModel {
        private val inputElements = interpreter.getInputTensor(0).shape().fold(1) { a, b -> a * b }

        override fun run(input: FloatArray): List<FloatArray> = synchronized(this) {
            require(input.size == inputElements) { "model expects $inputElements input values, got ${input.size}" }
            val inputBuffer = ByteBuffer.allocateDirect(input.size * 4).order(ByteOrder.nativeOrder())
            inputBuffer.asFloatBuffer().put(input)
            val outputBuffers = HashMap<Int, Any>()
            for (i in 0 until interpreter.outputTensorCount) {
                val count = interpreter.getOutputTensor(i).shape().fold(1) { a, b -> a * b }
                outputBuffers[i] = ByteBuffer.allocateDirect(count * 4).order(ByteOrder.nativeOrder())
            }
            interpreter.runForMultipleInputsOutputs(arrayOf<Any>(inputBuffer), outputBuffers)
            outputIndices.map { i ->
                val buffer = outputBuffers.getValue(i) as ByteBuffer
                buffer.rewind()
                FloatArray(buffer.capacity() / 4).also { buffer.asFloatBuffer().get(it) }
            }
        }
    }

    companion object {
        private const val LOG_TAG = "LightlyVision"
        const val FACE_DETECTOR = "blaze_face_full_range.tflite"
        const val FACE_MESH = "face_landmarks_detector.tflite"
        const val POSE_DETECTOR = "pose_detector.tflite"
        const val SELFIE = "selfie_segmenter.tflite"

        /** Recorded with the subject matte when it came from the person segmenter (the bundled file's SHA-256 prefix). */
        val PERSON_MATTE_MODEL = com.lightlylabs.lightly.session.ModelRef("mediapipe-selfie-segmenter-builtin", "400dd25939e5")

        private fun isEmulator(): Boolean = android.os.Build.HARDWARE in setOf("ranchu", "goldfish")

        @Volatile private var shared: LiteRtVisionModels? = null

        /** The set [get] created, if any (debug probe). */
        fun current(): LiteRtVisionModels? = shared

        /** One set per process; null when this build does not package the models. */
        fun get(context: Context, enabled: Boolean): LiteRtVisionModels? {
            if (!enabled) return null
            return shared ?: synchronized(this) { shared ?: LiteRtVisionModels(context.applicationContext).also { shared = it } }
        }
    }
}
