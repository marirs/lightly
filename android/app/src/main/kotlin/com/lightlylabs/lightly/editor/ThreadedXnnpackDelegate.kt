package com.lightlylabs.lightly.editor

import org.tensorflow.lite.Delegate

/**
 * LiteRT's XNNPACK CPU delegate created with a thread pool of [threads] (src/main/jni/xnnpack_threads.c).
 *
 * 2026-10-12, Remove took ~16 s per stroke on the motorola edge 60 in the foreground: LiteRT 1.4.2's Java API ran
 * XNNPACK on one core whatever `Interpreter.Options.setNumThreads` said (measured: one busy thread, the others idle
 * at 0 ticks, the same time for 1, 4 and 8 threads). This delegate runs the same XNNPACK kernels on the same model;
 * only the work is split across cores.
 *
 * Owns a native delegate: [close] it after the interpreter that uses it has been closed, never before.
 */
class ThreadedXnnpackDelegate private constructor(private var handle: Long) : Delegate {
    override fun getNativeHandle(): Long = handle

    override fun close() {
        if (handle != 0L) nativeDelete(handle)
        handle = 0L
    }

    companion object {
        private val libraryLoaded: Boolean by lazy {
            try {
                // The runtime must be loaded first: the native side looks the XNNPACK C API up in it.
                org.tensorflow.lite.TensorFlowLite.init()
                System.loadLibrary("lightly_xnnpack")
                true
            } catch (missing: UnsatisfiedLinkError) {
                runCatching { android.util.Log.w("LightlyRemove", "threaded XNNPACK unavailable: $missing") }
                false
            }
        }

        /** Null when this ABI or runtime cannot provide it; the caller then keeps LiteRT's default XNNPACK. */
        fun create(threads: Int, extraFlags: Int = 0): ThreadedXnnpackDelegate? {
            if (threads < 2 || !libraryLoaded) return null
            val handle = nativeCreate(threads, extraFlags)
            return if (handle == 0L || handle == -1L) null else ThreadedXnnpackDelegate(handle)
        }

        /**
         * Threads for one inference: the big cores. Little cores only slow a statically split GEMM down (each tile waits
         * for the slowest thread). Counted as the CPUs within 15 % of the highest maximum frequency (a prime core and its
         * slightly slower big siblings count; 2.0 GHz little cores beside 2.5 GHz big ones do not); 4 when unreadable.
         */
        fun performanceCoreCount(): Int = runCatching {
            val frequencies = (0 until Runtime.getRuntime().availableProcessors()).mapNotNull { cpu ->
                java.io.File("/sys/devices/system/cpu/cpu$cpu/cpufreq/cpuinfo_max_freq").takeIf { it.canRead() }?.readText()?.trim()?.toLongOrNull()
            }
            val fastest = frequencies.maxOrNull() ?: return@runCatching 4
            frequencies.count { it >= fastest * 0.85 }.coerceIn(2, 4)
        }.getOrDefault(4)

        @JvmStatic private external fun nativeCreate(threads: Int, extraFlags: Int): Long
        @JvmStatic private external fun nativeDelete(handle: Long)
    }
}
