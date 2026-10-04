package com.lightlylabs.visioneval

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.graphics.ColorSpace
import android.os.Build
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Runs ONE candidate over every photo in assets/photos and writes
 * results/<candidate>/result.json + masks/<photo>__<mask>.png, then a `done` marker.
 *
 * One candidate per process (the adb driver force-stops between candidates) so that:
 *  - initialise() + first analyse() are a genuine cold start (no shared native libs / caches);
 *  - VmHWM (peak RSS) is attributable to that candidate alone.
 */
class EvalRunner(
    private val context: Context,
    private val warmRuns: Int,
    private val log: (String) -> Unit,
) {
    private val resultsRoot = File(context.getExternalFilesDir(null), "results")

    fun run(candidate: VisionCandidate) {
        val outDir = File(resultsRoot, candidate.id).apply { deleteRecursively(); mkdirs() }
        val memory = MemProbe()
        val result = JSONObject()
            .put("candidate", candidate.id)
            .put("kind", candidate.kind.name)
            .put("sdk", candidate.sdkCoordinate)
            .put("model", candidate.modelDescription)
            .put("device", deviceJson())
            .put("input_max_edge", INPUT_MAX_EDGE)
            .put("warm_runs", warmRuns)
            .put("thermal_start", DeviceInfo.thermalStatus(context))
        memory.snapshot("baseline")

        val initStart = SystemClock.elapsedRealtimeNanos()
        val initDetails = try {
            candidate.initialise(context)
        } catch (failure: Throwable) {
            log("${candidate.id}: initialise failed: $failure"); android.util.Log.e("VisionEval", "initialise failed", failure)
            result.put("init_error", failure.toString())
            finish(outDir, result, memory)
            return
        }
        result.put("init_ms", elapsedMs(initStart)).put("init_details", initDetails)
        memory.snapshot("after_init")
        log("${candidate.id}: init ${result.getDouble("init_ms").roundToInt()} ms")

        val photoResults = JSONArray()
        for (photoName in listPhotos()) {
            val bitmap = decodePhoto(photoName)
            val photoStem = photoName.substringBeforeLast('.')
            val photoResult = JSONObject().put("photo", photoStem).put("width", bitmap.width).put("height", bitmap.height)
            try {
                analysePhoto(candidate, bitmap, photoStem, outDir, photoResult)
            } catch (failure: Throwable) {
                log("${candidate.id}/$photoStem failed: $failure")
                photoResult.put("error", failure.toString())
            }
            bitmap.recycle()
            photoResults.put(photoResult)
            log("${candidate.id}/$photoStem first=${photoResult.optDouble("first_ms").roundToInt()} ms warm=${photoResult.optDouble("warm_median_ms").roundToInt()} ms")
        }
        result.put("photos", photoResults)
        // First analyse() of the process = cold inference (graph/delegate warm-up, lazy model load).
        photoResults.optJSONObject(0)?.let { result.put("cold_first_inference_ms", it.opt("first_ms")) }
        candidate.close()
        finish(outDir, result, memory)
    }

    private fun analysePhoto(candidate: VisionCandidate, bitmap: Bitmap, photoStem: String, outDir: File, photoResult: JSONObject) {
        val firstStart = SystemClock.elapsedRealtimeNanos()
        val output = candidate.analyse(bitmap)
        photoResult.put("first_ms", elapsedMs(firstStart))
        val warmTimes = (0 until warmRuns).map {
            val warmStart = SystemClock.elapsedRealtimeNanos()
            candidate.analyse(bitmap)
            elapsedMs(warmStart)
        }
        photoResult.put("warm_ms", JSONArray(warmTimes))
        if (warmTimes.isNotEmpty()) photoResult.put("warm_median_ms", warmTimes.sorted()[warmTimes.size / 2])
        photoResult.put("output", output.details)
        val maskJson = JSONObject()
        for ((maskName, mask) in output.masks) {
            val file = File(outDir, "masks/${photoStem}__$maskName.png")
            MaskIO.savePng(mask, file)
            maskJson.put(maskName, MaskIO.statistics(mask).put("file", "masks/${file.name}"))
        }
        if (maskJson.length() > 0) photoResult.put("masks", maskJson)
    }

    private fun finish(outDir: File, result: JSONObject, memory: MemProbe) {
        memory.snapshot("end")
        result.put("memory", memory.perStage)
        val baselineRss = memory.perStage.optJSONObject("baseline")?.optDouble("vm_rss_mb")
        val peakRss = memory.peakRssMb()
        result.put("peak_rss_mb", peakRss ?: JSONObject.NULL)
        if (peakRss != null && baselineRss != null) result.put("peak_rss_over_baseline_mb", peakRss - baselineRss)
        result.put("thermal_end", DeviceInfo.thermalStatus(context))
        File(outDir, "result.json").writeText(result.toString(2))
        File(outDir, "done").writeText("ok")
        log("${result.getString("candidate")}: done, peak RSS ${peakRss?.roundToInt()} MB")
    }

    fun listPhotos(): List<String> = (context.assets.list("photos") ?: emptyArray())
        .filter { it.endsWith(".jpg") || it.endsWith(".png") }
        .sorted()

    /**
     * Photos are decoded to sRGB ARGB_8888 with the long edge capped at [INPUT_MAX_EDGE] — the
     * resolution the editor would analyse (a preview-scale proxy), not the 12–50 MP original.
     * ImageDecoder applies EXIF orientation, matching what the user sees.
     */
    private fun decodePhoto(assetName: String): Bitmap {
        val source = ImageDecoder.createSource(context.assets, "photos/$assetName")
        return ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            val longEdge = max(info.size.width, info.size.height)
            if (longEdge > INPUT_MAX_EDGE) {
                val scale = INPUT_MAX_EDGE.toFloat() / longEdge
                decoder.setTargetSize((info.size.width * scale).roundToInt(), (info.size.height * scale).roundToInt())
            }
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE // MediaPipe/ML Kit read pixels on CPU
            decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB))
        }.let { decoded ->
            if (decoded.config == Bitmap.Config.ARGB_8888) decoded
            else decoded.copy(Bitmap.Config.ARGB_8888, false).also { decoded.recycle() }
        }
    }

    private fun deviceJson(): JSONObject = JSONObject()
        .put("manufacturer", Build.MANUFACTURER)
        .put("model", Build.MODEL)
        .put("marketing_name", DeviceInfo.marketingName(context))
        .put("soc", DeviceInfo.soc())
        .put("sdk_int", Build.VERSION.SDK_INT)
        .put("fingerprint", Build.FINGERPRINT)

    companion object {
        const val INPUT_MAX_EDGE = 2048

        fun elapsedMs(startNanos: Long): Double =
            ((SystemClock.elapsedRealtimeNanos() - startNanos) / 1e4).roundToInt() / 100.0
    }
}
