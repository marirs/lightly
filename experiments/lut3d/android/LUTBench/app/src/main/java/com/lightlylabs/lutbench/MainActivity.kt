package com.lightlylabs.lutbench

import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import android.widget.ScrollView
import android.widget.TextView

/**
 * Entry point. Does nothing unless started with `--ez run_bench true`, so that launching it once
 * (to make Android create the external files dir before `adb push`) has no side effects.
 */
class MainActivity : Activity() {
    private lateinit var logView: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep the screen on for the duration of the run without touching the global
        // `svc power stayon` setting; these are window flags owned by this app only.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        logView = TextView(this).apply { setPadding(24, 24, 24, 24); textSize = 11f }
        setContentView(ScrollView(this).apply { addView(logView) })

        val shouldRunBench = intent?.getBooleanExtra("run_bench", false) ?: false
        val shouldRunNnapiDiagnostic = intent?.getBooleanExtra("nnapi_diag", false) ?: false
        if (shouldRunNnapiDiagnostic && !benchStarted) {
            benchStarted = true
            Thread({
                Bench(applicationContext, OrtBench.EXECUTION_PROVIDERS) { line -> runOnUiThread { appendLog(line) } }.runNnapiDiagnostic()
            }, "lutbench-diag").start()
            return
        }
        if (!shouldRunBench) {
            appendLog("LUTBench idle. Start with --ez run_bench true")
            // Touch the dir so `adb push` has a target owned by this app.
            getExternalFilesDir(null)
            return
        }
        if (benchStarted) {
            appendLog("Benchmark already running in this process")
            return
        }
        benchStarted = true
        val benchThread = Thread({
            // Optional `--es eps cpu,xnnpack` restricts ORT EPs (`none` = skip ORT; used for
            // emulator smoke tests where ORT's CPU kernels SIGILL on the virtual CPU).
            val requestedEps = intent?.getStringExtra("eps")
                ?.split(",")?.map { it.trim() }?.filter { it in OrtBench.EXECUTION_PROVIDERS }
                ?: OrtBench.EXECUTION_PROVIDERS
            Bench(applicationContext, requestedEps) { line -> runOnUiThread { appendLog(line) } }.runAll()
        }, "lutbench")
        benchThread.start()
    }

    private fun appendLog(line: String) {
        Log.i(TAG, line)
        logView.append(line + "\n")
    }

    companion object {
        const val TAG = "LUTBench"
        @Volatile private var benchStarted = false
    }
}
