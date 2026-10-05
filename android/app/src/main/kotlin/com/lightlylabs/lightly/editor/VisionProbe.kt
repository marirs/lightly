package com.lightlylabs.lightly.editor

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.lightlylabs.lightly.background.SegmentationUnavailableException
import com.lightlylabs.lightly.vision.PeopleAnalysis
import com.lightlylabs.lightly.vision.RgbaImage
import com.lightlylabs.lightly.vision.VisionSubjectSegmenter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer

/**
 * DEBUG builds only (`--es lightly.debug.visionProbe <folder>`): the functional check of the vision
 * integration on an emulator or dev phone (docs/v1/slice3-android.md, D3). For every .jpg in the folder
 * it runs the app's own people analysis (at the editor's analysis size) and subject separation (at the
 * display size), with the same models and code paths as the editor, and writes `<name>.json` (faces with
 * boxes, rings, scores, mesh presence, sample landmarks; people; timings; the separation outcome) and
 * `<name>__matte.png` beside it. Logs "LightlyVisionProbe done" when finished. Nothing leaves the device.
 */
object VisionProbe {
    private const val TAG = "LightlyVisionProbe"
    private const val ANALYSIS_LONG_EDGE = 1024
    private const val DISPLAY_LONG_EDGE = 1600

    fun run(folder: File): Job = CoroutineScope(SupervisorJob() + Dispatchers.Default).launch {
        // The process's models, created with the editor's environment at activity start.
        val models = LiteRtVisionModels.current()
        if (models == null) {
            android.util.Log.i(TAG, "no vision models in this build"); android.util.Log.i(TAG, "done 0"); return@launch
        }
        val photos = folder.listFiles { f -> f.name.endsWith(".jpg") }.orEmpty().sortedBy { it.name }
        for (photo in photos) {
            val result = JSONObject().put("photo", photo.name)
            runCatching {
                val bitmap = BitmapFactory.decodeFile(photo.absolutePath) ?: error("cannot decode")
                val analysis = rgba(bitmap, ANALYSIS_LONG_EDGE)
                val display = rgba(bitmap, DISPLAY_LONG_EDGE)
                var start = System.nanoTime()
                val people = models.peopleAnalyser()?.analyse(analysis) ?: PeopleAnalysis.NONE
                result.put("people_ms", (System.nanoTime() - start) / 1e6)
                result.put("analysis_size", JSONArray(listOf(analysis.width, analysis.height)))
                result.put("faces", JSONArray(people.faces.map { face ->
                    JSONObject().put("score", face.score.toDouble()).put("presence", face.landmarkPresence.toDouble()).put("usable", face.isUsable)
                        .put("box", rect(face.box)).put("ring", rect(face.ring))
                        .put("landmarks", JSONObject().apply {
                            for (i in listOf(1, 13, 33, 133, 152, 263, 362)) face.landmarks.getOrNull(i)?.let { put("$i", JSONArray(listOf(it.x, it.y))) }
                        })
                }))
                result.put("people", JSONArray(people.people.map(::rect)))
                result.put("has_person", people.hasPerson)
                val segmenter = VisionSubjectSegmenter(
                    people = { image -> models.peopleAnalyser()?.withoutLandmarks()?.analyse(image) ?: PeopleAnalysis.NONE },
                    personSegmenter = { models.personSegmenter() },
                    subjectSaliency = { models.subjectSaliency() },
                )
                // U²-Netp parity with the reference pipeline: the exact display pixels (PNG) and the raw 320 × 320
                // saliency (little-endian float32), so the reference can run on the same input offline.
                models.subjectSaliency()?.let { saliency ->
                    val t0 = System.nanoTime()
                    val raw = saliency.saliency(display)
                    result.put("saliency_ms", (System.nanoTime() - t0) / 1e6)
                    result.put("saliency_confident_area", com.lightlylabs.lightly.vision.SubjectSaliency.confidentArea(raw).toDouble())
                    File(folder, photo.nameWithoutExtension + "__saliency.f32").outputStream().use { out ->
                        val bytes = ByteBuffer.allocate(raw.values.size * 4).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                        bytes.asFloatBuffer().put(raw.values)
                        out.write(bytes.array())
                    }
                    File(folder, photo.nameWithoutExtension + "__display.png").outputStream().use { out ->
                        val argb = IntArray(display.width * display.height) { i ->
                            val o = i * 4
                            (0xff shl 24) or ((display.pixels[o].toInt() and 0xff) shl 16) or ((display.pixels[o + 1].toInt() and 0xff) shl 8) or (display.pixels[o + 2].toInt() and 0xff)
                        }
                        Bitmap.createBitmap(argb, display.width, display.height, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.PNG, 100, out)
                    }
                }
                start = System.nanoTime()
                val separation = try {
                    val matte = segmenter.segment(display.pixels, display.width, display.height)
                    if (matte == null) "no-subject" else {
                        val gray = IntArray(matte.width * matte.height) { i -> val v = (matte.values[i].coerceIn(0f, 1f) * 255).toInt(); (0xff shl 24) or (v shl 16) or (v shl 8) or v }
                        File(folder, photo.nameWithoutExtension + "__matte.png").outputStream().use { out ->
                            Bitmap.createBitmap(gray, matte.width, matte.height, Bitmap.Config.ARGB_8888).compress(Bitmap.CompressFormat.PNG, 100, out)
                        }
                        "matte"
                    }
                } catch (unavailable: SegmentationUnavailableException) {
                    "unavailable: ${unavailable.message}"
                }
                result.put("separation", separation).put("separation_ms", (System.nanoTime() - start) / 1e6)
                result.put("display_size", JSONArray(listOf(display.width, display.height)))
            }.onFailure { result.put("error", it.toString()) }
            File(folder, photo.nameWithoutExtension + ".json").writeText(result.toString(1))
            android.util.Log.i(TAG, "${photo.name}: ${result.optJSONArray("faces")?.length()} faces, separation ${result.optString("separation")}")
        }
        android.util.Log.i(TAG, "done ${photos.size}")
    }

    private fun rect(r: com.lightlylabs.lightly.session.NormalisedRect) = JSONArray(listOf(r.x, r.y, r.width, r.height))

    private fun rgba(bitmap: Bitmap, longEdge: Int): RgbaImage {
        val scale = minOf(1.0, longEdge.toDouble() / maxOf(bitmap.width, bitmap.height))
        val scaled = if (scale < 1.0) Bitmap.createScaledBitmap(bitmap, (bitmap.width * scale).toInt(), (bitmap.height * scale).toInt(), true) else bitmap
        val argb = scaled.copy(Bitmap.Config.ARGB_8888, false)
        val buffer = ByteBuffer.allocate(argb.byteCount)
        argb.copyPixelsToBuffer(buffer)
        return RgbaImage(argb.width, argb.height, buffer.array())
    }
}
