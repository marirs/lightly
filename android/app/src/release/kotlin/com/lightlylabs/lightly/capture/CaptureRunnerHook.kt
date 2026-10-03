package com.lightlylabs.lightly.capture

import android.content.Intent
import com.lightlylabs.lightly.MainActivity
import com.lightlylabs.lightly.prefs.PreferencesStore

/**
 * Release builds: the persistent capture runner does not exist (its implementation lives in the debug
 * source set only), so nothing can drive the app from outside.
 */
internal object CaptureRunnerHook {
    @Suppress("UNUSED_PARAMETER")
    fun attach(activity: MainActivity, intent: Intent?, preferences: PreferencesStore, launchScenario: kotlinx.coroutines.Job?) = Unit
}
