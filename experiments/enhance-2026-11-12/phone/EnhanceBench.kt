package com.lightlylabs.lightly.capture

import android.content.Context
import android.os.Debug
import android.util.Log
import com.lightlylabs.lightly.editor.ThreadedXnnpackDelegate
import org.tensorflow.lite.Interpreter
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

/**
 * Enhance step 1 (2026-11-13): load time, inference time and memory of the candidate TFLite models on a review
 * Android phone. Not part of the app: copied into the scratch build's debug source set only, and started with
 * `am start ... --ez lightly.debug.enhanceBench true`. Models are copied to <files>/enhance-bench/ with run-as.
 * Results go to logcat (tag LightlyEnhanceBench) and enhance-bench/results.txt.
 */
internal object EnhanceBench {
    private const val TAG = "LightlyEnhanceBench"
    private const val XNNPACK_FLAG_FORCE_FP16 = 0x4  // same value as LiteRtLamaInpainter

    private val candidates = listOf("general-x4v3-256.tflite" to 256, "codeformer-w0.8-512.tflite" to 512)

    fun start(context: Context) = thread(name = "lightly-enhance-bench") {
        // Models are copied into the app's private files with run-as: files adb pushes to Android/data are invisible to the app.
        val folder = File(context.filesDir, "enhance-bench")
        val lines = mutableListOf<String>()
        // adb created the model folder, so the app cannot write there: results go to its private files (run-as).
        val results = File(context.filesDir, "enhance-bench-results.txt")
        for ((fp16, label) in listOf(false to "xnnpack-fp32", true to "xnnpack-fp16")) {
            for ((file, size) in candidates) {
                val model = File(folder, file)
                if (!model.exists()) continue
                results.writeText((lines + "started $file [$label]").joinToString("\n"))
                val line = runCatching { measure(model, size, fp16, label) }.getOrElse { "$file [$label] FAILED $it" }
                lines += line
                Log.i(TAG, line)
            }
        }
        results.writeText(lines.joinToString("\n"))
        Log.i(TAG, "done")
    }

    private fun measure(model: File, size: Int, fp16: Boolean, label: String): String {
        val before = pssMb()
        val threads = ThreadedXnnpackDelegate.performanceCoreCount()
        val delegate = ThreadedXnnpackDelegate.create(threads, if (fp16) XNNPACK_FLAG_FORCE_FP16 else 0)
            ?: return "${model.name} [$label] no delegate"
        val loadStart = System.nanoTime()
        val options = Interpreter.Options().setNumThreads(threads).addDelegate(delegate).setUseXNNPACK(false)
        val interpreter = Interpreter(model, options)
        val loadMs = (System.nanoTime() - loadStart) / 1_000_000
        val input = ByteBuffer.allocateDirect(4 * 3 * size * size).order(ByteOrder.nativeOrder())
        repeat(3 * size * size) { input.putFloat((Math.random() * 2 - 1).toFloat()) }
        input.rewind()
        val outputSize = interpreter.getOutputTensor(0).numBytes()
        val output = ByteBuffer.allocateDirect(outputSize).order(ByteOrder.nativeOrder())
        val firstStart = System.nanoTime()
        interpreter.run(input, output)
        val firstMs = (System.nanoTime() - firstStart) / 1_000_000
        val times = (0 until 3).map {
            input.rewind(); output.rewind()
            val start = System.nanoTime()
            interpreter.run(input, output)
            (System.nanoTime() - start) / 1_000_000
        }.sorted()
        val peak = pssMb()
        interpreter.close()
        delegate.close()
        return "${model.name} [$label, $threads threads] load $loadMs ms, first $firstMs ms, median ${times[1]} ms, " +
            "PSS $before -> $peak MB"
    }

    private fun pssMb(): Long = Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }.totalPss / 1024L
}
