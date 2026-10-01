package com.lightlylabs.lutbench

import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.provider.Settings

object DeviceInfo {
    fun thermalStatus(context: Context): String {
        if (Build.VERSION.SDK_INT < 29) return "unavailable(sdk<29)"
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return when (val status = powerManager.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> "none"
            PowerManager.THERMAL_STATUS_LIGHT -> "light"
            PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
            PowerManager.THERMAL_STATUS_SEVERE -> "severe"
            PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
            PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
            PowerManager.THERMAL_STATUS_SHUTDOWN -> "shutdown"
            else -> "unknown($status)"
        }
    }

    /** `getprop` is readable by apps for ro.* properties; used only for the marketing name. */
    fun systemProperty(name: String): String? = try {
        val process = ProcessBuilder("getprop", name).redirectErrorStream(true).start()
        val value = process.inputStream.bufferedReader().readText().trim()
        process.waitFor()
        value.ifEmpty { null }
    } catch (_: Exception) {
        null
    }

    fun marketingName(context: Context): String {
        val candidates = listOf("ro.product.marketname", "ro.product.vendor.marketname", "ro.vendor.product.display")
        for (property in candidates) systemProperty(property)?.let { return it }
        // Fallback: user-visible device name (user-editable, so lower confidence).
        val deviceName = Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
        return deviceName ?: "${Build.MANUFACTURER} ${Build.MODEL}"
    }

    fun soc(): String = if (Build.VERSION.SDK_INT >= 31) {
        "${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}"
    } else {
        Build.HARDWARE
    }
}
