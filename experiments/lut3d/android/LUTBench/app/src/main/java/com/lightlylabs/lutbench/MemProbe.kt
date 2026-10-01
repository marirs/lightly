package com.lightlylabs.lutbench

import android.os.Debug
import org.json.JSONObject
import java.io.File

/** Per-stage memory snapshots. All values in MB. */
class MemProbe {
    val perStage = JSONObject()

    private fun readProcStatusKb(key: String): Long? = try {
        File("/proc/self/status").readLines()
            .firstOrNull { it.startsWith("$key:") }
            ?.substringAfter(':')?.trim()?.split(Regex("\\s+"))?.firstOrNull()?.toLong()
    } catch (_: Exception) {
        null
    }

    fun peakRssMb(): Double? = readProcStatusKb("VmHWM")?.let { it / 1024.0 }

    /**
     * Records a snapshot. totalPss comes from Debug.getMemoryInfo, which walks smaps and costs
     * tens of ms, so it is only called between timed sections, never inside one.
     */
    fun snapshot(stage: String): JSONObject {
        val runtime = Runtime.getRuntime()
        val memoryInfo = Debug.MemoryInfo()
        Debug.getMemoryInfo(memoryInfo)
        val snapshot = JSONObject()
            .put("native_heap_alloc_mb", Debug.getNativeHeapAllocatedSize() / MB)
            .put("java_heap_used_mb", (runtime.totalMemory() - runtime.freeMemory()) / MB)
            .put("java_heap_max_mb", runtime.maxMemory() / MB)
            .put("total_pss_mb", memoryInfo.totalPss / 1024.0)
            .put("pss_mb_dbg", Debug.getPss() / 1024.0)
            .put("vm_rss_mb", readProcStatusKb("VmRSS")?.let { it / 1024.0 } ?: JSONObject.NULL)
            .put("vm_hwm_mb", readProcStatusKb("VmHWM")?.let { it / 1024.0 } ?: JSONObject.NULL)
        perStage.put(stage, snapshot)
        return snapshot
    }

    companion object {
        private const val MB = 1024.0 * 1024.0
    }
}
