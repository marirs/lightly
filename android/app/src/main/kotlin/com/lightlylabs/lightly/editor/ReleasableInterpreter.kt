package com.lightlylabs.lightly.editor

import org.tensorflow.lite.Interpreter

/**
 * A LiteRT interpreter that can be closed while it is idle and reopens on its next use (2026-10-07, A1 memory): the
 * vision, depth and Remove models held about 255 MB of native memory for the rest of the process after one analysis,
 * which Save copy of a 48 MP photo then had to fit beside its two full-size frames. [use] and [release] take the same
 * lock, so a release waits for an inference in progress and never closes an interpreter under it; a model object
 * stays valid after a release (the next [use] reopens the file, already memory-mapped).
 */
class ReleasableInterpreter(private val open: () -> Interpreter) {
    private var interpreter: Interpreter? = null

    init { ModelResources.register(this) }

    fun <T> use(block: (Interpreter) -> T): T = synchronized(this) { block(interpreter ?: open().also { interpreter = it }) }

    fun release() = synchronized(this) {
        interpreter?.close()
        interpreter = null
    }

    val isOpen: Boolean get() = synchronized(this) { interpreter != null }
}

/** Every [ReleasableInterpreter] of the process, so the editor can release them all when no analysis is running. */
object ModelResources {
    private val all = java.util.concurrent.CopyOnWriteArrayList<ReleasableInterpreter>()

    fun register(model: ReleasableInterpreter) { all += model }

    /** Closes every open interpreter; returns how many were open. */
    fun releaseAll(): Int = all.count { model -> model.isOpen.also { if (it) model.release() } }
}
