package com.lightlylabs.lightly.capture

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import com.lightlylabs.lightly.editor.enhance.EnhanceEngine
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Debug and benchmark builds only: runs the Enhance engine on engine-check/input.png and writes output.png and
 * output.json beside it (experiments/enhance-2026-11-12/engine_check.py makes the input and the Mac copy's output to compare).
 * Nothing in the app opens Enhance yet (DEFERRED(enhance-ui)); this is how the engine is checked on a device or emulator:
 *
 *   adb push input.png /sdcard/Android/data/com.lightlylabs.lightly/files/engine-check/input.png
 *   adb shell am broadcast -n com.lightlylabs.lightly/.capture.EnhanceEngineCheckReceiver
 *   ... wait for "ENHANCE-CHECK done" in logcat, then pull output.png from the same folder
 *
 * The folder is the external files folder's engine-check when it exists (adb can push there, and the benchmark build
 * is not debuggable, so run-as cannot reach filesDir), else filesDir/engine-check (run-as, debug builds).
 *
 * The work runs on its own thread: CodeFormer takes minutes on the emulator's CPU kernels, longer than a receiver may.
 */
class EnhanceEngineCheckReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        Thread({ runCheck(app) }, "enhance-check").start()
    }

    private fun runCheck(context: Context) {
        val folder = context.getExternalFilesDir(null)?.let { File(it, "engine-check") }?.takeIf { it.isDirectory }
            ?: File(context.filesDir, "engine-check")
        try {
            val options = BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888; inScaled = false; inPremultiplied = false }
            val photo = BitmapFactory.decodeFile(File(folder, "input.png").absolutePath, options)
                ?: error("no files/engine-check/input.png")
            val loadStart = System.nanoTime()
            val result = EnhanceEngine.load(context).use { engine ->
                val loadMs = (System.nanoTime() - loadStart) / 1_000_000
                Log.i(TAG, "models loaded in $loadMs ms")
                val start = System.nanoTime()
                engine.enhance(photo).also { Log.i(TAG, "enhanced in ${(System.nanoTime() - start) / 1_000_000} ms") }
            }
            File(folder, "output.png").outputStream().use { result.image.compress(Bitmap.CompressFormat.PNG, 100, it) }
            val faces = JSONArray(result.faces.map { face ->
                JSONObject().put("eye_gap", face.eyeGap).put("restored", face.restored)
                    .put("point_source", face.pointSource?.name ?: JSONObject.NULL)
            })
            File(folder, "output.json").writeText(JSONObject().put("painting", result.isPainting).put("faces", faces).toString(1))
            Log.i(TAG, "done: ${result.image.width} x ${result.image.height}, faces $faces, PSS ${pssMb()} MB")
        } catch (failure: Throwable) {
            Log.e(TAG, "failed", failure)
            File(folder, "output.json").writeText(JSONObject().put("error", failure.toString()).toString())
        }
    }

    private fun pssMb(): Long = android.os.Debug.MemoryInfo().also { android.os.Debug.getMemoryInfo(it) }.totalPss / 1024L

    private companion object {
        const val TAG = "ENHANCE-CHECK"
    }
}
