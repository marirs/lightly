package com.lightlylabs.lightly.editor

import android.content.Context
import com.lightlylabs.lightly.session.ModelRef
import org.tensorflow.lite.Interpreter
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * LaMa big-lama on LiteRT (standalone `com.google.ai.edge.litert:litert` 1.4.2, Interpreter API, CPU;
 * no Play services, no network). Model: our conversion `lama_512_fp32.tflite` of the pinned
 * big-lama weights (docs/v1/remove-evaluation.md §6; exact parity with PyTorch, 131 dB), inputs
 * `image` [1, 3, 512, 512] in 0…1 and `mask` [1, 1, 512, 512] with 1 = remove, output [1, 3, 512, 512].
 *
 * RELEASE GATE "pending legal sign-off (training data: Places2)": the model is packaged only when the
 * build enables it (BuildConfig.REMOVE_MODEL_ENABLED: debug builds when the git-ignored conversion
 * exists, release builds only with -PlightlyRemoveLegalSignOff=true). Without it [create] returns null
 * and every stroke shows the approved failure state; the tool stays offered and nothing else fills.
 *
 * Speed (2026-10-12, motorola edge 60, foreground): LiteRT's own XNNPACK ran on one core whatever
 * setNumThreads said (~16 s per stroke). The interpreter now gets a [ThreadedXnnpackDelegate] on the big cores:
 * the same kernels and a bit-identical output (checked on device), ~7.3 s. The 512 crop is unchanged.
 *
 * DEFERRED(remove-fp16): remove-evaluation §7 asks for fp16 weights (~103 MB); no fp16 LiteRT
 * conversion exists yet, so the fp32 export (206 MB) ships in debug builds.
 * DEFERRED(remove-fp16-inference): [FP16_INFERENCE] (XNNPACK fp16 arithmetic, ~3.8 s instead of ~7.3 s) changes
 * the generated fill (hole PSNR 41–46 dB against fp32, up to 26 levels on hair detail); off until the owner decides.
 * DEFERRED(accelerators): the GPU delegate is a separate, unapproved artifact; CPU only, as for depth.
 */
class LiteRtLamaInpainter private constructor(private val interpreter: ReleasableInterpreter, private val imageIndex: Int, private val maskIndex: Int) : Inpainter {
    override val model: ModelRef = MODEL_REF

    override fun releaseResources() = interpreter.release()

    override fun inpaint(image: FloatArray, mask: FloatArray): FloatArray = interpreter.use { interpreter ->
        val runStarted = System.nanoTime()
        val side = RemoveEngine.MODEL_SIDE
        val inputs = arrayOfNulls<Any>(2)
        inputs[imageIndex] = direct(image)
        inputs[maskIndex] = direct(mask)
        val output = ByteBuffer.allocateDirect(3 * side * side * 4).order(ByteOrder.nativeOrder())
        try {
            interpreter.runForMultipleInputsOutputs(inputs, mapOf(0 to output))
        } catch (failure: IllegalArgumentException) {
            throw RemoveUnavailableException("Remove model rejected the input: ${failure.message}")
        }
        output.rewind()
        RemoveEngine.timingLog("model run ${(System.nanoTime() - runStarted) / 1_000_000} ms")
        FloatArray(3 * side * side).also { output.asFloatBuffer().get(it) }
    }

    private fun direct(values: FloatArray): ByteBuffer =
        ByteBuffer.allocateDirect(values.size * 4).order(ByteOrder.nativeOrder()).also { it.asFloatBuffer().put(values) }

    companion object {
        const val ASSET_PATH = "models/lama_512_fp32.tflite"

        /** Recorded with each stroke (`result.patch.model`); the version is the model file's SHA-256 prefix. */
        val MODEL_REF = ModelRef("lama-big-lama-litert-fp32-512", "39fa82d6a2b5")

        /**
         * Owner decision pending (DEFERRED(remove-fp16-inference) above). When true, the delegate is created with
         * TFLITE_XNNPACK_DELEGATE_FLAG_FORCE_FP16 and falls back to fp32 where the CPU has no fp16 arithmetic. Turning it
         * on should also give MODEL_REF a new version, because the fill is then no longer the fp32 model's.
         */
        private const val FP16_INFERENCE = false
        private const val XNNPACK_FLAG_FORCE_FP16 = 0x4

        /** The arm64 emulator on Apple hosts dies in XNNPACK's initialisation (see LiteRtDepthEstimator). */
        private fun isEmulator(): Boolean = android.os.Build.HARDWARE in setOf("ranchu", "goldfish")

        /**
         * Opens LaMa with the threaded XNNPACK delegate when it can be created, else with LiteRT's default (one core).
         * [onDelegate] receives the delegate to close once the interpreter is closed.
         */
        private fun openInterpreter(context: Context, onDelegate: (ThreadedXnnpackDelegate?) -> Unit): Interpreter {
            val openStarted = System.nanoTime()
            val threads = ThreadedXnnpackDelegate.performanceCoreCount()
            val attempts = if (isEmulator()) emptyList() else listOfNotNull(XNNPACK_FLAG_FORCE_FP16.takeIf { FP16_INFERENCE }, 0)
            for (flags in attempts) {
                val delegate = ThreadedXnnpackDelegate.create(threads, flags) ?: continue
                try {
                    // setUseXNNPACK(false): LiteRT's default single-threaded XNNPACK must not take the graph first.
                    val options = Interpreter.Options().setNumThreads(threads).addDelegate(delegate).setUseXNNPACK(false)
                    return Interpreter(ModelResources.mapAsset(context, ASSET_PATH), options).also {
                        onDelegate(delegate)
                        RemoveEngine.timingLog("model open ${(System.nanoTime() - openStarted) / 1_000_000} ms ($threads threads, flags $flags)")
                    }
                } catch (rejected: Exception) {
                    // e.g. fp16 forced on a CPU without fp16 arithmetic: try the next configuration.
                    delegate.close()
                    runCatching { android.util.Log.w("LightlyRemove", "threaded XNNPACK (flags $flags) rejected: $rejected") }
                }
            }
            onDelegate(null)
            return Interpreter(ModelResources.mapAsset(context, ASSET_PATH), Interpreter.Options().setNumThreads(4).setUseXNNPACK(!isEmulator()))
                .also { RemoveEngine.timingLog("model open ${(System.nanoTime() - openStarted) / 1_000_000} ms (LiteRT default XNNPACK)") }
        }

        /** Null when the build does not carry the model (release gate) or the runtime cannot load it. */
        fun create(context: Context, enabled: Boolean): LiteRtLamaInpainter? {
            if (!enabled) return null
            return try {
                var openDelegate: ThreadedXnnpackDelegate? = null
                val interpreter = ReleasableInterpreter(
                    // The delegate outlives its interpreter: closed only after the interpreter is.
                    afterClose = { openDelegate?.close(); openDelegate = null },
                    open = { openInterpreter(context) { openDelegate = it } },
                )
                val side = RemoveEngine.MODEL_SIDE
                val (imageIndex, maskIndex) = try {
                    interpreter.use { opened ->
                        val shapes = (0 until opened.inputTensorCount).map { opened.getInputTensor(it).shape().toList() }
                        val image = shapes.indexOf(listOf(1, 3, side, side))
                        val mask = shapes.indexOf(listOf(1, 1, side, side))
                        // The contract is fixed; a different model file must not be fed silently.
                        require(shapes.size == 2 && image >= 0 && mask >= 0) { "unexpected inputs $shapes" }
                        require(opened.getOutputTensor(0).shape().toList() == listOf(1, 3, side, side)) { "unexpected output" }
                        image to mask
                    }
                } catch (rejected: Exception) {
                    interpreter.release() // no stroke will use or release a model that failed the check
                    throw rejected
                }
                // Kept open: create runs lazily for the first stroke, which uses this interpreter at once and releases it
                // after (releasing here opened LaMa twice for the first stroke, ~0.7 s each on the motorola edge 60).
                LiteRtLamaInpainter(interpreter, imageIndex, maskIndex)
            } catch (failure: Exception) {
                android.util.Log.w("LightlyRemove", "remove model unavailable: $failure")
                null
            } catch (nativeMissing: UnsatisfiedLinkError) {
                android.util.Log.w("LightlyRemove", "LiteRT native library unavailable: $nativeMissing")
                null
            }
        }
    }
}
