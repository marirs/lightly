package com.lightlylabs.lightly.capture

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Choreographer
import android.view.FrameMetrics
import android.view.Window
import androidx.compose.runtime.Recomposer
import androidx.compose.ui.platform.findViewTreeCompositionContext
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.lightlylabs.lightly.MainActivity
import com.lightlylabs.lightly.editor.EditorViewModel
import com.lightlylabs.lightly.prefs.PreferencesStore
import com.lightlylabs.lightly.shell.DebugLaunchOptions
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.resume

/**
 * Persistent-session capture runner (debug source set only; release has a no-op hook).
 *
 * Launched once per device/orientation/theme/text-size batch with `--ez lightly.capture.runner true`;
 * the host then sends one broadcast per screen:
 *
 * ```
 * adb shell am broadcast -p com.lightlylabs.lightly -a com.lightlylabs.lightly.debug.CAPTURE \
 *   --ei seq 7 --es lightly.debug.photo <path> --es lightly.debug.editor dev-preset ...
 * ```
 * (the same extras as the per-launch path, see [DebugLaunchOptions]). For each request the runner
 *  1. resets every per-screen state: new shell and editor view models (the previous ones are cleared,
 *     which cancels their loads, renders, separation and toast timers), the content recomposed under a
 *     new key (scroll positions, sheets, dialogs, focus), keyboard hidden, favourites and appearance
 *     set from the request exactly as a launch sets them;
 *  2. applies the request with the same code as a launch ([DebugLaunchOptions.apply]);
 *  3. waits for an explicit render-complete signal, never a fixed sleep: the scenario job finished,
 *     the editor idle ([EditorViewModel.debugWorkIdle]: no load, prefetch or separation in flight and
 *     the latest requested preview published), Compose idle (no recomposer with pending work, which
 *     includes animations waiting for frames) on two consecutive vsyncs, and then one frame forced and
 *     confirmed drawn by FrameMetrics (its vsync at or after the idle point);
 *  4. logs `LightlyCapture: ready seq=<n> …` (or `failed seq=<n> …`), which the host waits for with
 *     `adb logcat -m 1 -e` before taking the screenshot.
 *
 * Per-launch captures can ask for the same signal with `--ei lightly.capture.signal <seq>` on the launch
 * intent (no runner): the state comes from the launch itself, and the runner's readiness checks decide
 * when it is drawn. This is the baseline the runner is validated against.
 *
 * Process-wide state is shared exactly as in the per-launch path, which also reuses one process
 * (NEW_TASK|CLEAR_TASK launches): the parsed look pack, the render threads and the export coordinator.
 */
internal object CaptureRunnerHook {
    const val EXTRA_RUNNER = "lightly.capture.runner"
    const val ACTION = "com.lightlylabs.lightly.debug.CAPTURE"
    private const val TAG = "LightlyCapture"
    private const val SCREEN_TIMEOUT_MILLIS = 120_000L

    /** Last FrameMetrics seen while waiting for the forced frame; logged on a timeout. */
    @Volatile private var lastFrameMetrics = "none"

    const val EXTRA_SIGNAL = "lightly.capture.signal"

    fun attach(activity: MainActivity, intent: Intent?, preferences: PreferencesStore, launchScenario: kotlinx.coroutines.Job?) {
        if (intent == null) return
        if (intent.hasExtra(EXTRA_SIGNAL)) signalLaunch(activity, intent.getIntExtra(EXTRA_SIGNAL, -1), intent.getStringExtra("lightly.debug.editor") ?: "?", launchScenario)
        if (!intent.getBooleanExtra(EXTRA_RUNNER, false)) return
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        // One request at a time, in arrival order: the host waits for each "ready" anyway.
        val requests = Channel<Pair<Int, DebugLaunchOptions.Request>>(Channel.UNLIMITED)
        val metricsThread = HandlerThread("lightly-capture-metrics").apply { start() }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, received: Intent) {
                requests.trySend(received.getIntExtra("seq", -1) to DebugLaunchOptions.Request.from(received))
            }
        }
        // Exported so `adb shell am broadcast` reaches it; it exists only in debug builds and only in a
        // process launched with the runner extra.
        ContextCompat.registerReceiver(activity, receiver, IntentFilter(ACTION), ContextCompat.RECEIVER_EXPORTED)
        activity.lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onDestroy(owner: LifecycleOwner) {
                activity.unregisterReceiver(receiver)
                scope.cancel()
                metricsThread.quitSafely()
            }
        })
        scope.launch {
            for ((seq, request) in requests) capture(activity, preferences, seq, request, Handler(metricsThread.looper))
        }
        Log.i(TAG, "attached pid=${android.os.Process.myPid()}")
    }

    /** Per-launch capture: same readiness as the runner, for the state the launch itself configured. */
    private fun signalLaunch(activity: MainActivity, seq: Int, label: String, launchScenario: kotlinx.coroutines.Job?) {
        val thread = HandlerThread("lightly-capture-metrics").apply { start() }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        activity.lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onDestroy(owner: LifecycleOwner) { scope.cancel(); thread.quitSafely() }
        })
        scope.launch {
            val started = SystemClock.elapsedRealtime()
            try {
                withTimeout(SCREEN_TIMEOUT_MILLIS) {
                    launchScenario?.join()
                    val editor = activity.activeEditorForCapture() ?: error("no editor")
                    val polls = awaitIdle(activity, editor)
                    val drawnVsync = awaitDrawnFrame(activity.window, Handler(thread.looper))
                    Log.i(TAG, "ready seq=$seq screen=$label ms=${SystemClock.elapsedRealtime() - started} idlePolls=$polls vsync=$drawnVsync")
                }
            } catch (timeout: TimeoutCancellationException) {
                Log.i(TAG, "failed seq=$seq screen=$label reason=timeout composeIdle=${composeIdle(activity)} frame=$lastFrameMetrics")
            }
        }
    }

    private suspend fun capture(activity: MainActivity, preferences: PreferencesStore, seq: Int, request: DebugLaunchOptions.Request, metricsHandler: Handler) {
        val started = SystemClock.elapsedRealtime()
        val label = request.editor ?: request.screen ?: "?"
        try {
            withTimeout(SCREEN_TIMEOUT_MILLIS) {
                val viewModels = activity.resetForCapture()
                // A launch passes favourites (possibly empty) every time; mirror that so none leak between screens.
                val normalised = request.copy(favourites = request.favourites ?: "")
                DebugLaunchOptions.apply(normalised, viewModels.shell, preferences, viewModels.editor)?.join()
                val polls = awaitIdle(activity, viewModels.editor)
                val drawnVsync = awaitDrawnFrame(activity.window, metricsHandler)
                Log.i(TAG, "ready seq=$seq screen=$label ms=${SystemClock.elapsedRealtime() - started} idlePolls=$polls vsync=$drawnVsync")
            }
        } catch (timeout: TimeoutCancellationException) {
            Log.i(TAG, "failed seq=$seq screen=$label reason=timeout editorIdle=${activity.isEditorIdleForCapture()} composeIdle=${composeIdle(activity)} frame=$lastFrameMetrics")
        } catch (error: Exception) {
            Log.i(TAG, "failed seq=$seq screen=$label reason=${error.javaClass.simpleName}: ${error.message}")
        }
    }

    private fun MainActivity.isEditorIdleForCapture(): Boolean = runCatching { activeEditorForCapture()?.debugWorkIdle() }.getOrNull() ?: false

    /** Two consecutive vsyncs with the editor and Compose both idle. Returns the vsyncs it took. */
    private suspend fun awaitIdle(activity: MainActivity, editor: EditorViewModel): Int {
        var stable = 0
        var polls = 0
        while (stable < 2) {
            awaitVsync()
            polls++
            stable = if (editor.debugWorkIdle() && composeIdle(activity)) stable + 1 else 0
        }
        return polls
    }

    /**
     * The window's recomposer has no pending work (invalidations or frame awaiters, i.e. running
     * animations). No recomposer found counts as not idle, so a broken lookup fails loudly.
     */
    private fun composeIdle(activity: MainActivity): Boolean {
        // Only this Activity's window recomposer: Recomposer.runningRecomposers is process-wide and,
        // during a CLEAR_TASK launch, still holds the previous (stopped, never-idle) Activity's one,
        // which made dev-original time out in launch-with-signal captures.
        val content = activity.findViewById<android.view.ViewGroup>(android.R.id.content)?.getChildAt(0) ?: return false
        val recomposer = content.findViewTreeCompositionContext() as? Recomposer ?: return false
        return !recomposer.hasPendingWork
    }

    private suspend fun awaitVsync(): Long = suspendCancellableCoroutine { continuation ->
        Choreographer.getInstance().postFrameCallback { frameTimeNanos -> if (continuation.isActive) continuation.resume(frameTimeNanos) }
    }

    /**
     * Forces one frame and waits until FrameMetrics reports a frame drawn for a vsync at or after the
     * force point, i.e. the idle content has been drawn and handed to the compositor.
     */
    private suspend fun awaitDrawnFrame(window: Window, handler: Handler): Long {
        val forcedAt = awaitVsync()
        return suspendCancellableCoroutine { continuation ->
            val listener = object : Window.OnFrameMetricsAvailableListener {
                override fun onFrameMetricsAvailable(source: Window, metrics: FrameMetrics, dropCount: Int) {
                    // VSYNC_TIMESTAMP is the frame time Choreographer used (the same clock as forcedAt). When
                    // frames are skipped, Choreographer moves its frame time forward but
                    // INTENDED_VSYNC_TIMESTAMP keeps the original, earlier vsync; comparing that made the
                    // forced frame look old, so the first Fold-inner screen never reported "ready".
                    val used = metrics.getMetric(FrameMetrics.VSYNC_TIMESTAMP)
                    lastFrameMetrics = "forcedAt=$forcedAt vsync=$used intended=${metrics.getMetric(FrameMetrics.INTENDED_VSYNC_TIMESTAMP)}"
                    if (used < forcedAt || !continuation.isActive) return
                    source.decorView.post { source.removeOnFrameMetricsAvailableListener(this) }
                    continuation.resume(used)
                }
            }
            window.addOnFrameMetricsAvailableListener(listener, handler)
            continuation.invokeOnCancellation { window.decorView.post { window.removeOnFrameMetricsAvailableListener(listener) } }
            window.decorView.invalidate()
        }
    }
}
