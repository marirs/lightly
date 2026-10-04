package com.lightlylabs.visioneval

import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import android.widget.ScrollView
import android.widget.TextView
import java.io.File

/**
 * adb-driven entry point (see scripts/run_device.sh):
 *   am start -n com.lightlylabs.visioneval/.MainActivity --ez list true
 *       -> results/candidates.txt (one candidate id per line)
 *   am start -n com.lightlylabs.visioneval/.MainActivity --es candidate <id> [--ei warm_runs 3]
 *       -> results/<id>/{result.json,masks/<photo>__<mask>.png,done}
 * Launching without extras does nothing, so opening it from the launcher is harmless.
 */
class MainActivity : Activity() {
    private lateinit var logView: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Window flags owned by this app only; no global stay-awake setting is touched.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        logView = TextView(this).apply { setPadding(24, 24, 24, 24); textSize = 11f }
        setContentView(ScrollView(this).apply { addView(logView) })

        val resultsRoot = File(getExternalFilesDir(null), "results").apply { mkdirs() }
        if (intent?.getBooleanExtra("list", false) == true) {
            val ids = CandidateRegistry.create().map { it.id }
            File(resultsRoot, "candidates.txt").writeText(ids.joinToString("\n") + "\n")
            appendLog("candidates: $ids")
            return
        }
        val candidateId = intent?.getStringExtra("candidate")
        if (candidateId == null) {
            appendLog("VisionEval idle. Start with --es candidate <id> or --ez list true")
            return
        }
        if (runStarted) {
            appendLog("A candidate is already running in this process")
            return
        }
        runStarted = true
        val warmRuns = intent?.getIntExtra("warm_runs", 3) ?: 3
        Thread({
            val candidate = CandidateRegistry.create().firstOrNull { it.id == candidateId }
            if (candidate == null) {
                appendLogFromWorker("unknown candidate $candidateId")
                File(resultsRoot, "$candidateId/done").apply { parentFile?.mkdirs() }.writeText("unknown")
                return@Thread
            }
            EvalRunner(applicationContext, warmRuns) { appendLogFromWorker(it) }.run(candidate)
        }, "visioneval-$candidateId").start()
    }

    private fun appendLogFromWorker(line: String) = runOnUiThread { appendLog(line) }

    private fun appendLog(line: String) {
        Log.i(TAG, line)
        logView.append(line + "\n")
    }

    companion object {
        const val TAG = "VisionEval"
        @Volatile private var runStarted = false
    }
}
