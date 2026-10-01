package com.lightlylabs.lutbench

import ai.onnxruntime.OrtLoggingLevel
import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Benchmark driver. Inputs are read from the app's external files dir (pushed by
 * run_android.sh); results go to files/results/. Every stage is wrapped so that one failure is
 * recorded verbatim and the run continues.
 */
class Bench(
    private val context: Context,
    private val enabledExecutionProviders: List<String>,
    private val uiLog: (String) -> Unit,
) {
    private val filesRoot: File = context.getExternalFilesDir(null) ?: throw IllegalStateException("no external files dir")
    private val modelsDir = File(filesRoot, "models")
    private val goldenDir = File(filesRoot, "golden")
    private val photosDir = File(filesRoot, "photos")
    private val resultsDir = File(filesRoot, "results")
    private val logFile = File(resultsDir, "log.txt")
    private val memory = MemProbe()
    private val root = JSONObject()

    private fun log(line: String) {
        uiLog(line)
        runCatching { logFile.appendText(line + "\n") }
    }

    private fun errorText(throwable: Throwable): String = "${throwable.javaClass.name}: ${throwable.message}"

    /** JSONObject rejects NaN/Infinity; map them to null. */
    private fun num(value: Double): Any = if (value.isNaN() || value.isInfinite()) JSONObject.NULL else value

    private fun timingJson(first: Double, rest: List<Double>): JSONObject =
        JSONObject().put("first", num(first)).put("median", num(median(rest))).put("n_median", rest.size)

    fun runAll() {
        resultsDir.mkdirs()
        resultsDir.listFiles()?.forEach { it.delete() }
        log("LUTBench start ${Build.MANUFACTURER} ${Build.MODEL} sdk ${Build.VERSION.SDK_INT}")
        val ort = OrtBench(File(modelsDir, "ia3dlut_classifier.onnx"), ::log)
        var gl: GlLut? = null
        try {
            root.put("platform", "android")
            root.put("harness", JSONObject()
                .put("build", "release (non-debuggable, debug-key signed)")
                .put("onnxruntime", "com.microsoft.onnxruntime:onnxruntime-android:1.30.0")
                .put("inference_median_n", INFERENCE_REPEATS)
                .put("apply_median_n", APPLY_REPEATS)
                .put("preprocess_method", "ImageDecoder(ALLOCATOR_SOFTWARE, target ColorSpace SRGB) -> RGBA8; whole-frame 256x256 resize ignoring aspect with antialiased bilinear (triangle filter, support scaled by downscale factor; port of torch F.interpolate(bilinear, antialias=True, align_corners=False) coefficients), separable H then V in float32. resize_ms includes Bitmap->byte[] copy."))
            val device = deviceJson()
            root.put("device", device)
            memory.snapshot("start")

            val basis = readFloatFile(File(modelsDir, "ia3dlut_basis_luts_f32.bin"))
            check(basis.size == 3 * LUT_FLOATS) { "basis LUT file has ${basis.size} floats, expected ${3 * LUT_FLOATS}" }

            root.put("model", loadModels(ort))
            memory.snapshot("after_model_load")

            gl = GlLut(::log)
            val glJson = JSONObject()
            root.put("gl", glJson)
            try {
                gl.init()
                device.put("gpu", "${gl.renderer} | ${gl.version}")
                glJson.put("renderer", gl.renderer).put("version", gl.version).put("limits", gl.limits)
                glJson.put("program_build_ms", gl.buildPrograms())
            } catch (throwable: Throwable) {
                glJson.put("error", errorText(throwable))
                log("GL init FAILED: ${errorText(throwable)}")
                gl = null
            }
            memory.snapshot("after_gl_init")

            val images = JSONArray()
            root.put("images", images)
            val goldenStems = goldenDir.listFiles()
                ?.filter { File(it, "source.png").exists() && File(it, "meta.json").exists() }
                ?.sortedBy { it.name } ?: emptyList()
            log("golden images: ${goldenStems.size}")
            for (stemDir in goldenStems) {
                val imageJson = JSONObject().put("stem", stemDir.name)
                images.put(imageJson)
                try {
                    benchImage(stemDir, imageJson, ort, gl, basis)
                } catch (throwable: Throwable) {
                    imageJson.put("error", errorText(throwable))
                    log("image ${stemDir.name} FAILED: ${errorText(throwable)}")
                }
                memory.snapshot("image_${stemDir.name}")
                writeResults()
                System.gc()
            }

            root.put("synthetic", if (gl != null && goldenStems.isNotEmpty()) benchSynthetic(gl, goldenStems.first()) else JSONObject().put("error", "skipped: GL unavailable or no golden images"))
            memory.snapshot("after_synthetic")
            root.put("photos_decode", benchPhotoDecode())
            device.put("thermal_end", DeviceInfo.thermalStatus(context))
        } catch (throwable: Throwable) {
            root.put("fatal_error", errorText(throwable))
            log("FATAL: ${errorText(throwable)}")
        } finally {
            runCatching { gl?.release() }
            runCatching { ort.closeAll() }
            runCatching {
                root.put("memory", JSONObject()
                    .put("peak_rss_mb", num(memory.peakRssMb() ?: Double.NaN))
                    .put("per_stage_mb", memory.perStage))
            }
            writeResults()
            File(resultsDir, "done").writeText(if (root.has("fatal_error")) "fatal" else "ok")
            log("LUTBench done")
        }
    }

    /** Separate process launch with ORT verbose logging, so NNAPI partitioning shows in logcat. */
    fun runNnapiDiagnostic() {
        resultsDir.mkdirs()
        val diagFile = File(resultsDir, "nnapi_diag.txt")
        val ort = OrtBench(File(modelsDir, "ia3dlut_classifier.onnx")) { line -> uiLog(line); diagFile.appendText(line + "\n") }
        try {
            ort.createEnvironment(OrtLoggingLevel.ORT_LOGGING_LEVEL_VERBOSE)
            for (ep in listOf("nnapi", "nnapi_cpu_disabled", "xnnpack")) {
                val entry = ort.loadExecutionProvider(ep)
                diagFile.appendText("$ep: $entry\n")
            }
        } catch (throwable: Throwable) {
            diagFile.appendText("FATAL: ${errorText(throwable)}\n")
        } finally {
            ort.closeAll()
            File(resultsDir, "done_diag").writeText("ok")
        }
    }

    private fun writeResults() {
        runCatching { File(resultsDir, "results.json").writeText(root.toString(2)) }
            .onFailure { log("writeResults failed: ${errorText(it)}") }
    }

    private fun deviceJson(): JSONObject = JSONObject()
        .put("model_id", "${Build.MANUFACTURER} ${Build.MODEL} (${Build.DEVICE})")
        .put("marketing_name", DeviceInfo.marketingName(context))
        .put("os", "Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT}, ${Build.ID})")
        .put("soc", DeviceInfo.soc())
        .put("gpu", JSONObject.NULL)
        .put("thermal_start", DeviceInfo.thermalStatus(context))
        .put("thermal_end", JSONObject.NULL)
        .put("cpu_abi", Build.SUPPORTED_ABIS.joinToString(","))
        .put("cpu_cores", Runtime.getRuntime().availableProcessors())
        .put("java_heap_max_mb", Runtime.getRuntime().maxMemory() / 1048576.0)

    private fun loadModels(ort: OrtBench): JSONObject {
        val model = JSONObject()
        ort.createEnvironment()
        root.put("model_env", JSONObject().put("env_create_s", ort.environmentCreateSeconds)
            .put("note", "load_cold_s excludes env creation (incl. libonnxruntime.so load); load_warm_s is median of ${OrtBench.WARM_LOAD_REPEATS} re-creations"))
        log("ORT env created in ${"%.3f".format(ort.environmentCreateSeconds)} s")
        root.getJSONObject("harness").put("execution_providers", JSONArray(enabledExecutionProviders))
        for (ep in enabledExecutionProviders) model.put(ep, ort.loadExecutionProvider(ep))
        return model
    }

    private fun benchImage(stemDir: File, imageJson: JSONObject, ort: OrtBench, gl: GlLut?, basis: FloatArray) {
        val stem = stemDir.name
        val meta = JSONObject(File(stemDir, "meta.json").readText())
        val goldenWeightsJson = meta.getJSONArray("weights_deploy")
        val goldenWeights = FloatArray(3) { goldenWeightsJson.getDouble(it).toFloat() }
        imageJson.put("width", meta.getInt("width")).put("height", meta.getInt("height"))
        imageJson.put("thermal", DeviceInfo.thermalStatus(context))
        log("== $stem ${meta.getInt("width")}x${meta.getInt("height")}")

        imageJson.put("inference", benchInference(stemDir, ort, goldenWeights))

        // Preprocessing: decode + antialiased resize on device, then classify with CPU EP.
        val preprocess = JSONObject()
        imageJson.put("preprocess", preprocess)
        val (sourceBitmap, decodeMs) = timedMs { decodeSrgb(File(stemDir, "source.png")) }
        preprocess.put("decode_ms", decodeMs)
        var sourceRgba: ByteArray? = null
        try {
            val (rgbaAndChw, resizeMs) = timedMs {
                val rgba = bitmapToRgba(sourceBitmap)
                rgba to AntialiasedResize.resizeToChw(rgba, sourceBitmap.width, sourceBitmap.height)
            }
            sourceRgba = rgbaAndChw.first
            val deviceChw = rgbaAndChw.second
            preprocess.put("resize_ms", resizeMs)
            val goldenChw = readFloatFile(File(stemDir, "input256.f32"))
            preprocess.put("tensor_max_abs_diff_vs_golden", maxAbsDiff(deviceChw, goldenChw))
            val session = ort.sessions["cpu"] ?: ort.sessions.values.firstOrNull()
            if (session != null) {
                ort.createInputTensor(deviceChw).use { tensor ->
                    val weights = ort.infer(session, tensor)
                    preprocess.put("weights", JSONArray(weights.map { it.toDouble() }))
                    preprocess.put("max_abs_diff_vs_golden", maxAbsDiff(weights, goldenWeights))
                }
                // Contrast: Bitmap.createScaledBitmap(filter=true) is a bilinear tap with no
                // antialiasing at large ratios, i.e. the upstream (resolution-dependent) path.
                val (scaledChw, scaledMs) = timedMs {
                    val scaled = Bitmap.createScaledBitmap(sourceBitmap, 256, 256, true)
                    val chw = rgbaToChw(bitmapToRgba(scaled), 256, 256)
                    scaled.recycle()
                    chw
                }
                ort.createInputTensor(scaledChw).use { tensor ->
                    val weights = ort.infer(session, tensor)
                    preprocess.put("scaled_bitmap_filter_true", JSONObject()
                        .put("resize_ms", scaledMs)
                        .put("tensor_max_abs_diff_vs_golden", maxAbsDiff(scaledChw, goldenChw))
                        .put("weights", JSONArray(weights.map { it.toDouble() }))
                        .put("max_abs_diff_vs_golden", maxAbsDiff(weights, goldenWeights)))
                }
            }
        } catch (throwable: Throwable) {
            preprocess.put("error", errorText(throwable))
            log("preprocess FAILED: ${errorText(throwable)}")
        }
        memory.snapshot("preprocess_$stem")

        // Fuse with golden weights to isolate the fuse stage from model parity.
        val goldenFused = readFloatFile(File(stemDir, "fused_lut.f32"))
        val fuseTimes = ArrayList<Double>()
        var fused = FloatArray(0)
        repeat(FUSE_REPEATS) { val (lut, ms) = timedMs { fuseLuts(basis, goldenWeights) }; fused = lut; fuseTimes.add(ms) }
        val preprocessWeights = preprocess.optJSONArray("weights")
        val fuseJson = JSONObject()
            .put("ms", median(fuseTimes.drop(1)))
            .put("first_ms", fuseTimes.first())
            .put("max_abs_diff_vs_golden", maxAbsDiffRgb(fused, goldenFused))
        if (preprocessWeights != null) {
            val deviceWeights = FloatArray(3) { preprocessWeights.getDouble(it).toFloat() }
            fuseJson.put("max_abs_diff_vs_golden_using_device_preprocess_weights", maxAbsDiffRgb(fuseLuts(basis, deviceWeights), goldenFused))
        }
        imageJson.put("fuse", fuseJson)

        val apply = JSONObject()
        imageJson.put("apply", apply)
        val rgba = sourceRgba ?: bitmapToRgba(sourceBitmap)
        val pixelCount = sourceBitmap.width * sourceBitmap.height
        val reference = decodeSrgb(File(stemDir, "reference.png"))
        check(reference.width == sourceBitmap.width && reference.height == sourceBitmap.height) { "reference.png size mismatch" }
        val referenceRgba = bitmapToRgba(reference)
        reference.recycle()

        // CPU reference (correctness only): applied with the golden fused LUT.
        try {
            val (cpuOut, cpuMs) = timedMs { applyLutCpu(rgba, pixelCount, goldenFused) }
            apply.put("cpu_reference", diffStats(cpuOut, referenceRgba, pixelCount)
                .put("full_ms", JSONObject().put("first", cpuMs).put("median", JSONObject.NULL))
                .put("note", "Kotlin exact trilinear, single thread, correctness only"))
        } catch (throwable: Throwable) {
            apply.put("cpu_reference", JSONObject().put("error", errorText(throwable)))
        }

        if (gl != null) benchGlApply(gl, stem, sourceBitmap, referenceRgba, goldenFused, apply, imageJson)
        sourceBitmap.recycle()
    }

    private fun benchInference(stemDir: File, ort: OrtBench, goldenWeights: FloatArray): JSONObject {
        val inference = JSONObject()
        val input = readFloatFile(File(stemDir, "input256.f32"))
        ort.createInputTensor(input).use { tensor ->
            for ((ep, session) in ort.sessions) {
                try {
                    val (firstWeights, firstMs) = timedMs { ort.infer(session, tensor) }
                    val times = ArrayList<Double>()
                    var weights = firstWeights
                    repeat(INFERENCE_REPEATS) { val (w, ms) = timedMs { ort.infer(session, tensor) }; weights = w; times.add(ms) }
                    inference.put(ep, JSONObject()
                        .put("first_ms", firstMs)
                        .put("median_ms", median(times))
                        .put("weights", JSONArray(weights.map { it.toDouble() }))
                        .put("max_abs_diff_vs_golden", maxAbsDiff(weights, goldenWeights)))
                    log("infer $ep first ${"%.2f".format(firstMs)} med ${"%.2f".format(median(times))} ms diff ${"%.2e".format(maxAbsDiff(weights, goldenWeights))}")
                } catch (throwable: Throwable) {
                    inference.put(ep, JSONObject().put("error", errorText(throwable)))
                }
            }
        }
        return inference
    }

    private fun previewBitmap(source: Bitmap): Bitmap {
        val scale = PREVIEW_LONG_EDGE.toDouble() / max(source.width, source.height)
        return Bitmap.createScaledBitmap(source, (source.width * scale).roundToInt(), (source.height * scale).roundToInt(), true)
    }

    private fun benchGlApply(gl: GlLut, stem: String, source: Bitmap, referenceRgba: ByteArray, fusedLut: FloatArray, apply: JSONObject, imageJson: JSONObject) {
        imageJson.put("lut_upload_ms", gl.uploadLut(fusedLut))
        val pixelCount = source.width * source.height
        val fullOutput = ByteBuffer.allocateDirect(pixelCount * 4)
        val outputBytes = ByteArray(pixelCount * 4)
        val preview = previewBitmap(source)
        val previewOutput = ByteBuffer.allocateDirect(preview.width * preview.height * 4)
        imageJson.put("preview_size", JSONArray(listOf(preview.width, preview.height)))
        for (variant in GlLut.VARIANTS) {
            val variantJson = JSONObject()
            apply.put(variant, variantJson)
            try {
                val fullFirst = gl.apply(variant, source, fullOutput)
                val fullRest = List(APPLY_REPEATS) { gl.apply(variant, source, fullOutput) }
                fullOutput.position(0)
                fullOutput.get(outputBytes)
                fullOutput.position(0)
                val stats = diffStats(outputBytes, referenceRgba, pixelCount)
                stats.keys().forEach { key -> variantJson.put(key, stats.get(key)) }
                variantJson.put("full_ms", timingJson(fullFirst, fullRest))
                val previewFirst = gl.apply(variant, preview, previewOutput)
                val previewRest = List(APPLY_REPEATS) { gl.apply(variant, preview, previewOutput) }
                variantJson.put("preview_ms", timingJson(previewFirst, previewRest))
                log("apply $variant full ${"%.1f".format(median(fullRest))} ms preview ${"%.1f".format(median(previewRest))} ms max ${stats.get("max_abs_diff")} frac>1 ${"%.2e".format(stats.getDouble("frac_gt1"))}")
                val outBitmap = rgbaToBitmap(outputBytes, source.width, source.height)
                savePng(outBitmap, File(resultsDir, "${stem}_android_$variant.png"))
                outBitmap.recycle()
            } catch (throwable: Throwable) {
                variantJson.put("error", errorText(throwable))
                log("apply $variant FAILED: ${errorText(throwable)}")
            }
        }
        preview.recycle()
    }

    private fun benchSynthetic(gl: GlLut, firstStemDir: File): JSONObject {
        val synthetic = JSONObject()
        synthetic.put("source", "${firstStemDir.name}/source.png upscaled with Bitmap.createScaledBitmap(filter=true), aspect ignored; timing only")
        val source = decodeSrgb(File(firstStemDir, "source.png"))
        gl.uploadLut(readFloatFile(File(firstStemDir, "fused_lut.f32")))
        for ((key, size) in listOf("12mp" to (4032 to 3024), "48mp" to (8064 to 6048))) {
            val applyJson = JSONObject()
            synthetic.put("${key}_apply_ms", applyJson)
            var big: Bitmap? = null
            var output: ByteBuffer? = null
            try {
                big = Bitmap.createScaledBitmap(source, size.first, size.second, true)
                output = try {
                    ByteBuffer.allocateDirect(size.first * size.second * 4)
                } catch (oom: OutOfMemoryError) {
                    applyJson.put("readback_mode", "strips (full-frame buffer OOM: ${oom.message})")
                    null
                }
                if (output != null) applyJson.put("readback_mode", "full_frame_buffer")
                for (variant in GlLut.VARIANTS) {
                    try {
                        val first = gl.apply(variant, big, output)
                        val rest = List(APPLY_REPEATS) { gl.apply(variant, big, output) }
                        applyJson.put(variant, timingJson(first, rest))
                        log("synthetic $key $variant median ${"%.1f".format(median(rest))} ms")
                    } catch (throwable: Throwable) {
                        applyJson.put(variant, JSONObject().put("error", errorText(throwable)))
                        log("synthetic $key $variant FAILED: ${errorText(throwable)}")
                    }
                }
                memory.snapshot("synthetic_$key")
                if (key == "12mp" && output != null) {
                    // JPEG encode of the last 12 MP output (rgba32f_manual variant).
                    val outBytes = ByteArray(size.first * size.second * 4)
                    output.position(0); output.get(outBytes); output.position(0)
                    val outBitmap = rgbaToBitmap(outBytes, size.first, size.second)
                    val stream = ByteArrayOutputStream(8 * 1024 * 1024)
                    val (_, encodeMs) = timedMs { outBitmap.compress(Bitmap.CompressFormat.JPEG, 90, stream) }
                    synthetic.put("12mp_jpeg_encode_ms", encodeMs)
                    synthetic.put("12mp_jpeg_bytes", stream.size())
                    outBitmap.recycle()
                }
            } catch (throwable: Throwable) {
                applyJson.put("error", errorText(throwable))
                log("synthetic $key FAILED: ${errorText(throwable)}")
            } finally {
                big?.recycle()
                output = null
                System.gc()
            }
        }
        source.recycle()
        return synthetic
    }

    private fun benchPhotoDecode(): JSONArray {
        val list = JSONArray()
        val photos = photosDir.listFiles()?.filter { it.name.lowercase().endsWith(".jpg") || it.name.lowercase().endsWith(".jpeg") }?.sortedBy { it.name } ?: emptyList()
        for (photo in photos) {
            try {
                val (bitmap, ms) = timedMs { decodeSrgb(photo) }
                list.put(JSONObject().put("file", photo.name).put("width", bitmap.width).put("height", bitmap.height).put("decode_ms", ms))
                bitmap.recycle()
            } catch (throwable: Throwable) {
                list.put(JSONObject().put("file", photo.name).put("error", errorText(throwable)))
            }
        }
        return list
    }

    companion object {
        const val INFERENCE_REPEATS = 20
        const val APPLY_REPEATS = 10
        const val FUSE_REPEATS = 11
        const val PREVIEW_LONG_EDGE = 2048
    }
}
