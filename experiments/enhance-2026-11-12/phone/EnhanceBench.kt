package com.lightlylabs.lightly.capture

import android.content.Context
import android.os.Debug
import android.util.Log
import org.tensorflow.lite.Interpreter
import org.tensorflow.lite.gpu.GpuDelegate
import org.tensorflow.lite.gpu.GpuDelegateFactory
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

/**
 * Enhance step 1d (2026-11-13): GPU-friendly CodeFormer (codeformer_gpu.py) on the LiteRT GPU delegate, fp16, with the
 * compiled-kernel cache, run on real aligned faces. Not part of the app: copied into a scratch build only and started
 * with `am start ... --ez lightly.debug.enhanceBench true`. Launch twice: the first load compiles and caches the GPU
 * kernels, the second reads the cache.
 *
 * Inputs (copied in with run-as): <files>/enhance-bench/codeformer-gpu-w0.8-512.tflite and faces/<name>.bin
 * (float32 [1, 3, 512, 512], [-1, 1], from export_phone_faces.py). Outputs: faces-out/<name>.bin (same layout) and
 * enhance-bench-results.txt. compare_phone_faces.py turns the outputs into images.
 *
 * Earlier on the A069, one 512 px face: original CodeFormer 9.3 s (XNNPACK fp16) / 30 s (GPU, 1,252 of 2,245 ops);
 * GPU-friendly CodeFormer 2.4 s (GPU fp16, 1,880 of 1,920 ops), random input, 40 s load without the cache.
 */
internal object EnhanceBench {
    private const val TAG = "LightlyEnhanceBench"
    private const val MODEL_FILE = "codeformer-gpu-w0.8-512.tflite"
    private const val FACE_SIZE = 512

    /** [mode]: split16 / split32 (step 1d result), gpu16, gpu32, cpu or probes, from `--es lightly.debug.enhanceMode`. */
    fun start(context: Context, mode: String = "gpu16") = thread(name = "lightly-enhance-bench") {
        val folder = File(context.filesDir, "enhance-bench")
        val results = File(context.filesDir, "enhance-bench-results.txt")
        val line = runCatching {
            when (mode) {
                "probes" -> runProbes(folder)
                "split16", "split32" -> runSplit(context, folder, fp16 = mode == "split16")
                else -> runFaces(context, folder, mode)
            }
        }
            .getOrElse { "FAILED $it" }
        // Appended: the cold (compiling) and warm (cached) launches end up in one file.
        results.appendText(line + "\n")
        Log.i(TAG, line)
        Log.i(TAG, "done")
    }

    private fun runFaces(context: Context, folder: File, mode: String): String {
        val cacheFolder = File(context.filesDir, "enhance-gpu-cache").apply { mkdirs() }
        val kernelCacheExisted = cacheFolder.list()?.isNotEmpty() == true
        val delegate = if (mode == "cpu") null else GpuDelegate(
            GpuDelegateFactory.Options()
                .setPrecisionLossAllowed(mode == "gpu16")
                // Token names the model version and precision: a change must not reuse old compiled kernels.
                .setSerializationParams(cacheFolder.absolutePath, "codeformer-gpu-w0.8-512-v3-$mode"),
        )
        val interpreterOptions = Interpreter.Options().setNumThreads(4)
        delegate?.let { interpreterOptions.addDelegate(it) }
        val before = pssMb()
        val loadStart = System.nanoTime()
        val interpreter = Interpreter(File(folder, MODEL_FILE), interpreterOptions)
        val loadMs = (System.nanoTime() - loadStart) / 1_000_000

        val faces = File(folder, "faces").listFiles { file -> file.name.endsWith(".bin") }.orEmpty().sortedBy { it.name }
        val outputFolder = File(context.filesDir, "faces-out/$mode").apply { mkdirs() }
        val input = ByteBuffer.allocateDirect(4 * 3 * FACE_SIZE * FACE_SIZE).order(ByteOrder.LITTLE_ENDIAN)
        val output = ByteBuffer.allocateDirect(interpreter.getOutputTensor(0).numBytes()).order(ByteOrder.LITTLE_ENDIAN)
        val faceTimes = faces.map { face ->
            input.clear(); input.put(face.readBytes()); input.rewind(); output.clear()
            val start = System.nanoTime()
            interpreter.run(input, output)
            val ms = (System.nanoTime() - start) / 1_000_000
            output.rewind()
            val values = output.asFloatBuffer()
            val nonFinite = (0 until values.limit()).count { !values.get(it).isFinite() }
            output.rewind()
            File(outputFolder, face.name).writeBytes(ByteArray(output.remaining()).also { output.get(it) })
            "${face.nameWithoutExtension} $ms ms" + if (nonFinite > 0) " ($nonFinite non-finite)" else ""
        }
        val peak = pssMb()
        interpreter.close()
        delegate?.close()
        return "$mode kernel cache ${if (kernelCacheExisted) "present" else "empty"}: load $loadMs ms; " +
            faceTimes.joinToString(", ") + "; PSS $before -> $peak MB"
    }

    /**
     * Step 1d split (codeformer_split.py): encoder and decoder on the GPU, the token transformer + topk + codebook on
     * the CPU (XNNPACK, 4 threads), because the GPU delegate gets the transformer's matrix products wrong. Files:
     * codeformer-encoder/-middle/-decoder.tflite. Encoder outputs output_0..4 = lq + skips at 32/64/128/256 px; the
     * decoder takes args_0 = quantised features, args_1..4 = those skips.
     */
    private fun runSplit(context: Context, folder: File, fp16: Boolean): String {
        val cacheFolder = File(context.filesDir, "enhance-gpu-cache").apply { mkdirs() }
        val kernelCacheExisted = cacheFolder.list()?.isNotEmpty() == true
        val precision = if (fp16) "fp16" else "fp32"

        fun gpuInterpreter(part: String): Pair<Interpreter, GpuDelegate> {
            val delegate = GpuDelegate(
                GpuDelegateFactory.Options()
                    .setPrecisionLossAllowed(fp16)
                    // Token names the model part, its version and precision: never reuse kernels across them.
                    .setSerializationParams(cacheFolder.absolutePath, "codeformer-$part-v1-$precision"),
            )
            return Interpreter(File(folder, "codeformer-$part.tflite"), Interpreter.Options().addDelegate(delegate)) to delegate
        }

        val before = pssMb()
        val loadStart = System.nanoTime()
        val (encoder, encoderDelegate) = gpuInterpreter("encoder")
        val middle = Interpreter(File(folder, "codeformer-middle.tflite"), Interpreter.Options().setNumThreads(4))
        val (decoder, decoderDelegate) = gpuInterpreter("decoder")
        val loadMs = (System.nanoTime() - loadStart) / 1_000_000

        fun outputsOf(interpreter: Interpreter): Map<String, ByteBuffer> =
            interpreter.getSignatureOutputs("serving_default").associateWith { name ->
                ByteBuffer.allocateDirect(interpreter.getOutputTensorFromSignature(name, "serving_default").numBytes())
                    .order(ByteOrder.LITTLE_ENDIAN)
            }

        val encoded = outputsOf(encoder)
        val quantised = outputsOf(middle)
        val restored = outputsOf(decoder)
        val faces = File(folder, "faces").listFiles { file -> file.name.endsWith(".bin") }.orEmpty().sortedBy { it.name }
        val outputFolder = File(context.filesDir, "faces-out/split-$precision").apply { mkdirs() }
        val input = ByteBuffer.allocateDirect(4 * 3 * FACE_SIZE * FACE_SIZE).order(ByteOrder.LITTLE_ENDIAN)
        val faceTimes = faces.map { face ->
            input.clear(); input.put(face.readBytes()); input.rewind()
            (encoded.values + quantised.values + restored.values).forEach { it.clear() }
            val t0 = System.nanoTime()
            encoder.runSignature(mapOf("args_0" to input), encoded)
            val t1 = System.nanoTime()
            middle.runSignature(mapOf("args_0" to encoded.getValue("output_0").rewind()), quantised)
            val t2 = System.nanoTime()
            val decoderInputs = mutableMapOf<String, Any>("args_0" to quantised.getValue("output_0").rewind())
            for (skip in 1..4) decoderInputs["args_$skip"] = encoded.getValue("output_$skip").rewind()
            decoder.runSignature(decoderInputs, restored)
            val t3 = System.nanoTime()
            val output = restored.getValue("output_0").rewind() as ByteBuffer
            val values = output.asFloatBuffer()
            val nonFinite = (0 until values.limit()).count { !values.get(it).isFinite() }
            File(outputFolder, face.name).writeBytes(ByteArray(output.remaining()).also { output.get(it) })
            "${face.nameWithoutExtension} ${(t3 - t0) / 1_000_000} ms (enc ${(t1 - t0) / 1_000_000}, " +
                "mid ${(t2 - t1) / 1_000_000}, dec ${(t3 - t2) / 1_000_000})" + if (nonFinite > 0) " $nonFinite non-finite" else ""
        }
        val peak = pssMb()
        listOf(encoder, middle, decoder).forEach { it.close() }
        encoderDelegate.close(); decoderDelegate.close()
        return "split-$precision kernel cache ${if (kernelCacheExisted) "present" else "empty"}: load $loadMs ms; " +
            faceTimes.joinToString(", ") + "; PSS $before -> $peak MB"
    }

    /**
     * Debugging the all-NaN GPU output: each model in enhance-bench/probes/ is CodeFormer cut after one stage
     * (convert_gpu_probes.py). Runs the first face through it on the GPU (fp32) and on the CPU and compares.
     */
    private fun runProbes(folder: File): String {
        val face = File(folder, "faces").listFiles { file -> file.name.endsWith(".bin") }.orEmpty().minBy { it.name }
        val input = ByteBuffer.allocateDirect(4 * 3 * FACE_SIZE * FACE_SIZE).order(ByteOrder.LITTLE_ENDIAN)
        input.put(face.readBytes())
        val probes = File(folder, "probes").listFiles { file -> file.name.endsWith(".tflite") }.orEmpty().sortedBy { it.name }
        return probes.joinToString("\n") { probe ->
            val (gpu, gpuNodes) = runOnce(probe, input, gpu = true)
            val (cpu, _) = runOnce(probe, input, gpu = false)
            val nonFinite = gpu.count { !it.isFinite() }
            val maxDifference = gpu.indices.maxOf { kotlin.math.abs(gpu[it] - cpu[it]) }
            "probe ${probe.nameWithoutExtension}: $gpuNodes, gpu non-finite $nonFinite of ${gpu.size}, " +
                "max |gpu - cpu| $maxDifference, cpu max ${cpu.maxOf { kotlin.math.abs(it) }}"
        }
    }

    private fun runOnce(model: File, input: ByteBuffer, gpu: Boolean): Pair<FloatArray, String> {
        val delegate = if (gpu) GpuDelegate(GpuDelegateFactory.Options().setPrecisionLossAllowed(false)) else null
        val options = Interpreter.Options().setNumThreads(4)
        delegate?.let { options.addDelegate(it) }
        val interpreter = Interpreter(model, options)
        val output = ByteBuffer.allocateDirect(interpreter.getOutputTensor(0).numBytes()).order(ByteOrder.LITTLE_ENDIAN)
        input.rewind()
        interpreter.run(input, output)
        output.rewind()
        val values = FloatArray(output.remaining() / 4).also { output.asFloatBuffer().get(it) }
        interpreter.close()
        delegate?.close()
        return values to (if (gpu) "gpu" else "cpu")
    }

    private fun pssMb(): Long = Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }.totalPss / 1024L
}
