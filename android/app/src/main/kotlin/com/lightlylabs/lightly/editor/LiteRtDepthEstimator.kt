package com.lightlylabs.lightly.editor

import android.content.Context
import com.lightlylabs.lightly.background.DepthEstimator
import com.lightlylabs.lightly.background.DepthModelInput
import com.lightlylabs.lightly.background.DepthUnavailableException
import com.lightlylabs.lightly.background.FloatPlane
import com.lightlylabs.lightly.session.ModelRef
import org.tensorflow.lite.Interpreter
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Depth Anything V2 Small on LiteRT (standalone `com.google.ai.edge.litert:litert`, Interpreter API,
 * CPU with XNNPACK; no Play services, no network). Model: our 518×392 conversion with int8 weights and
 * fp32 activations (docs/v1/depth-evaluation.md §3), input NCHW float32 [1, 3, 392, 518] ImageNet-
 * normalised, output [1, 392, 518] relative disparity (larger = nearer).
 *
 * RELEASE GATE "pending legal sign-off (training data)": the model is only packaged when the build
 * enables it (BuildConfig.DEPTH_MODEL_ENABLED; debug builds by default, release builds only with
 * -PlightlyDepthLegalSignOff=true). Otherwise [create] returns null and the app shows the approved
 * unavailable state.
 *
 * DEFERRED(accelerators): the evaluation's NPU → GPU → CPU order needs LiteRT's CompiledModel API
 * (litert 2.x, which also pulls ai-delivery / AiPack download components) or the separate GPU
 * delegate artifact; neither is approved here, so this runs on the CPU only.
 */
class LiteRtDepthEstimator private constructor(private val interpreter: ReleasableInterpreter) : DepthEstimator {
    override suspend fun estimate(input: DepthModelInput): FloatPlane = interpreter.use { interpreter ->
        val pixels = DepthModelInput.WIDTH * DepthModelInput.HEIGHT
        val inputBuffer = ByteBuffer.allocateDirect(input.tensor.size * 4).order(ByteOrder.nativeOrder())
        inputBuffer.asFloatBuffer().put(input.tensor)
        val outputBuffer = ByteBuffer.allocateDirect(pixels * 4).order(ByteOrder.nativeOrder())
        try {
            interpreter.run(inputBuffer, outputBuffer)
        } catch (failure: IllegalArgumentException) {
            throw DepthUnavailableException("Depth model rejected the input: ${failure.message}")
        }
        outputBuffer.rewind()
        val values = FloatArray(pixels).also { outputBuffer.asFloatBuffer().get(it) }
        FloatPlane(DepthModelInput.WIDTH, DepthModelInput.HEIGHT, values)
    }

    companion object {
        const val ASSET_PATH = "models/da2_small_518x392_wi8.tflite"

        /** Recorded with the edit (`depth.map.model`); the version is the model file's SHA-256 prefix. */
        val MODEL_REF = ModelRef("depth-anything-v2-small-518x392-wi8", "8e719085ce21")

        /**
         * The arm64 Android emulator on Apple M-series hosts kills the process with SIGILL inside the
         * XNNPACK delegate's initialisation (tombstone: libtensorflowlite_jni.so, pthread_once, on the
         * first inference). Devices keep XNNPACK, the evaluated fast CPU path; only the emulator falls
         * back to the built-in kernels. Emulator timings therefore do not represent devices.
         */
        private fun isEmulator(): Boolean = android.os.Build.HARDWARE in setOf("ranchu", "goldfish")

        /** Null when the build does not carry the model (release gate) or the runtime cannot load it. */
        fun create(context: Context, enabled: Boolean): LiteRtDepthEstimator? {
            if (!enabled) return null
            return try {
                val interpreter = ReleasableInterpreter { Interpreter(ModelResources.mapAsset(context, ASSET_PATH), Interpreter.Options().setNumThreads(4).setUseXNNPACK(!isEmulator())) }
                interpreter.use { opened ->
                    val inputShape = opened.getInputTensor(0).shape().toList()
                    val outputShape = opened.getOutputTensor(0).shape().toList()
                    // The contract is fixed; a different model file must not be fed silently.
                    require(inputShape == listOf(1, 3, DepthModelInput.HEIGHT, DepthModelInput.WIDTH)) { "unexpected input $inputShape" }
                    require(outputShape.takeLast(2) == listOf(DepthModelInput.HEIGHT, DepthModelInput.WIDTH)) { "unexpected output $outputShape" }
                }
                LiteRtDepthEstimator(interpreter)
            } catch (failure: Exception) {
                // Missing asset, a model that does not match the contract, or a runtime that cannot load
                // it: the approved "unavailable" state, never a crash.
                android.util.Log.w("LightlyDepth", "depth model unavailable: $failure")
                null
            } catch (nativeMissing: UnsatisfiedLinkError) {
                android.util.Log.w("LightlyDepth", "LiteRT native library unavailable: $nativeMissing")
                null
            }
        }
    }
}
