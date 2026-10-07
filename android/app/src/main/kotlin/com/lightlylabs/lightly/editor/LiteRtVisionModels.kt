package com.lightlylabs.lightly.editor

import android.content.Context
import com.lightlylabs.lightly.vision.BlazeFaceDetector
import com.lightlylabs.lightly.vision.FaceMeshLandmarker
import com.lightlylabs.lightly.vision.PeopleAnalyser
import com.lightlylabs.lightly.vision.PersonSegmenter
import com.lightlylabs.lightly.vision.PortraitMatting
import com.lightlylabs.lightly.vision.PoseDetector
import com.lightlylabs.lightly.vision.SubjectSaliency
import com.lightlylabs.lightly.vision.TensorModel
import org.tensorflow.lite.Interpreter
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The MediaPipe vision models (assets/vision, bundled by BundleVisionModelsTask) on the standalone
 * LiteRT runtime: no MediaPipe Tasks, no Play services, no network (docs/v1/android-vision-evaluation.md).
 * Each model is loaded on first use; its interpreter can be released while no analysis runs and reopens on the next
 * call (ReleasableInterpreter); every call is serialised per model, because an Interpreter is not thread-safe.
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
    private val portraitMatte by lazy { load(PORTRAIT_MATTE, listOf(elements(PortraitMatting.INPUT * PortraitMatting.INPUT))) }
    private val subjectSaliencyModel by lazy { load(SUBJECT_SALIENCY, listOf(elements(SubjectSaliency.INPUT * SubjectSaliency.INPUT))) }

    fun peopleAnalyser(): PeopleAnalyser? {
        val faces = faceDetector ?: return null
        return PeopleAnalyser(BlazeFaceDetector(faces), faceMesh?.let(::FaceMeshLandmarker), poseDetector?.let(::PoseDetector))
    }

    fun personSegmenter(): PersonSegmenter? = selfie?.let(::PersonSegmenter)

    /** MODNet, when this build packages it (optional asset): Background's person matte with hair detail. */
    fun portraitMatting(): PortraitMatting? = portraitMatte?.let(::PortraitMatting)

    /** Whether the optional MODNet asset is packaged (checked without loading it). */
    val hasPortraitMatte: Boolean by lazy { context.assets.list("vision")?.contains(PORTRAIT_MATTE) == true }

    /** U²-Netp, when this build packages it (optional asset, experimental): the class-agnostic subject. */
    fun subjectSaliency(): SubjectSaliency? = subjectSaliencyModel?.let(::SubjectSaliency)

    /** Whether the optional U²-Netp asset is packaged (checked without loading it). */
    val hasSubjectSaliency: Boolean by lazy { context.assets.list("vision")?.contains(SUBJECT_SALIENCY) == true }

    /**
     * The model identity recorded with a subject matte. With U²-Netp packaged the matte combines the saliency
     * subject with the person matte (VisionSubjectSegmenter), so both are named.
     */
    val subjectMatteModelRef: com.lightlylabs.lightly.session.ModelRef
        get() {
            val person = if (hasPortraitMatte) PORTRAIT_MATTE_MODEL else PERSON_MATTE_MODEL
            return if (!hasSubjectSaliency) person
            else com.lightlylabs.lightly.session.ModelRef("${SUBJECT_SALIENCY_MODEL.id}+${person.id}", "${SUBJECT_SALIENCY_MODEL.version}+${person.version}")
        }

    /** Picks one output tensor by its shape (or name); the adapter returns outputs in the order listed. */
    private fun interface OutputSelector {
        fun matches(shape: IntArray, name: String): Boolean
    }

    private fun lastDim(size: Int) = OutputSelector { shape, _ -> shape.last() == size && shape.fold(1) { a, b -> a * b } > size }
    private fun elements(count: Int) = OutputSelector { shape, _ -> shape.fold(1) { a, b -> a * b } == count }
    private fun named(name: String) = OutputSelector { _, tensorName -> tensorName == name }

    private fun load(asset: String, outputs: List<OutputSelector>): TensorModel? = try {
        // As the depth model: XNNPACK on devices; the arm64 emulator on Apple-silicon hosts dies with
        // SIGILL in XNNPACK's initialisation, so it runs the built-in kernels there.
        val interpreter = ReleasableInterpreter { Interpreter(ModelResources.mapAsset(context, "vision/$asset"), Interpreter.Options().setNumThreads(4).setUseXNNPACK(!isEmulator())) }
        val indices = interpreter.use { opened ->
            outputs.map { selector ->
                (0 until opened.outputTensorCount).firstOrNull { i ->
                    val tensor = opened.getOutputTensor(i)
                    selector.matches(tensor.shape(), tensor.name())
                } ?: throw IllegalStateException("$asset has no output matching the expected contract")
            }
        }
        LiteRtTensorModel(interpreter, indices)
    } catch (failure: Exception) {
        android.util.Log.w(LOG_TAG, "vision model $asset unavailable: $failure")
        null
    } catch (nativeMissing: UnsatisfiedLinkError) {
        android.util.Log.w(LOG_TAG, "LiteRT native library unavailable: $nativeMissing")
        null
    }

    private class LiteRtTensorModel(private val interpreter: ReleasableInterpreter, private val outputIndices: List<Int>) : TensorModel {
        private val inputElements = interpreter.use { it.getInputTensor(0).shape().fold(1) { a, b -> a * b } }

        override fun run(input: FloatArray): List<FloatArray> = interpreter.use { opened ->
            require(input.size == inputElements) { "model expects $inputElements input values, got ${input.size}" }
            val inputBuffer = ByteBuffer.allocateDirect(input.size * 4).order(ByteOrder.nativeOrder())
            inputBuffer.asFloatBuffer().put(input)
            val outputBuffers = HashMap<Int, Any>()
            for (i in 0 until opened.outputTensorCount) {
                val count = opened.getOutputTensor(i).shape().fold(1) { a, b -> a * b }
                outputBuffers[i] = ByteBuffer.allocateDirect(count * 4).order(ByteOrder.nativeOrder())
            }
            opened.runForMultipleInputsOutputs(arrayOf<Any>(inputBuffer), outputBuffers)
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
        const val PORTRAIT_MATTE = "portrait_matte.tflite"
        const val SUBJECT_SALIENCY = "subject_saliency.tflite"

        /** Recorded with the subject matte when it came from the person segmenter (the bundled file's SHA-256 prefix). */
        val PERSON_MATTE_MODEL = com.lightlylabs.lightly.session.ModelRef("mediapipe-selfie-segmenter-builtin", "400dd25939e5")

        /** Recorded with the subject matte when people were matted by MODNet (the bundled file's SHA-256 prefix). */
        val PORTRAIT_MATTE_MODEL = com.lightlylabs.lightly.session.ModelRef("modnet-photographic-512-fp16", "4b57ff612f1a")

        /** U²-Netp (the bundled file's SHA-256 prefix). */
        val SUBJECT_SALIENCY_MODEL = com.lightlylabs.lightly.session.ModelRef("u2netp-320-fp32", "40655434570d")

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
