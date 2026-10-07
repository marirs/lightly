package com.lightlylabs.lightly.editor

import android.content.Context
import com.lightlylabs.lightly.session.ModelRef
import org.tensorflow.lite.Interpreter
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel

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
 * DEFERRED(remove-fp16): remove-evaluation §7 asks for fp16 weights (~103 MB); no fp16 LiteRT
 * conversion exists yet, so the fp32 export (206 MB) ships in debug builds.
 * DEFERRED(accelerators): the GPU delegate is a separate, unapproved artifact; CPU only, as for depth.
 */
class LiteRtLamaInpainter private constructor(private val interpreter: ReleasableInterpreter, private val imageIndex: Int, private val maskIndex: Int) : Inpainter {
    override val model: ModelRef = MODEL_REF

    override fun releaseResources() = interpreter.release()

    override fun inpaint(image: FloatArray, mask: FloatArray): FloatArray = interpreter.use { interpreter ->
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
        FloatArray(3 * side * side).also { output.asFloatBuffer().get(it) }
    }

    private fun direct(values: FloatArray): ByteBuffer =
        ByteBuffer.allocateDirect(values.size * 4).order(ByteOrder.nativeOrder()).also { it.asFloatBuffer().put(values) }

    companion object {
        const val ASSET_PATH = "models/lama_512_fp32.tflite"

        /** Recorded with each stroke (`result.patch.model`); the version is the model file's SHA-256 prefix. */
        val MODEL_REF = ModelRef("lama-big-lama-litert-fp32-512", "39fa82d6a2b5")

        /** The arm64 emulator on Apple hosts dies in XNNPACK's initialisation (see LiteRtDepthEstimator). */
        private fun isEmulator(): Boolean = android.os.Build.HARDWARE in setOf("ranchu", "goldfish")

        /** Null when the build does not carry the model (release gate) or the runtime cannot load it. */
        fun create(context: Context, enabled: Boolean): LiteRtLamaInpainter? {
            if (!enabled) return null
            return try {
                val model = context.assets.openFd(ASSET_PATH).use { descriptor ->
                    FileInputStream(descriptor.fileDescriptor).channel.use { channel ->
                        channel.map(FileChannel.MapMode.READ_ONLY, descriptor.startOffset, descriptor.declaredLength)
                    }
                }
                val interpreter = ReleasableInterpreter { Interpreter(model, Interpreter.Options().setNumThreads(4).setUseXNNPACK(!isEmulator())) }
                val side = RemoveEngine.MODEL_SIDE
                val (imageIndex, maskIndex) = interpreter.use { opened ->
                    val shapes = (0 until opened.inputTensorCount).map { opened.getInputTensor(it).shape().toList() }
                    val image = shapes.indexOf(listOf(1, 3, side, side))
                    val mask = shapes.indexOf(listOf(1, 1, side, side))
                    // The contract is fixed; a different model file must not be fed silently.
                    require(shapes.size == 2 && image >= 0 && mask >= 0) { "unexpected inputs $shapes" }
                    require(opened.getOutputTensor(0).shape().toList() == listOf(1, 3, side, side)) { "unexpected output" }
                    image to mask
                }
                interpreter.release() // opened for the contract check only; the first stroke reopens it
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
