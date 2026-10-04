package com.lightlylabs.lightly.background

/**
 * Runs [body] once per row, rows in parallel. Callers write only the output elements of their own
 * row and read shared inputs, so results are bit-identical to the sequential loop (same expression,
 * same order per element). Small images stay sequential: pull-push pyramids go down to 1 × 1, where
 * fork-join overhead outweighs the work.
 */
internal inline fun forEachRow(rows: Int, crossinline body: (Int) -> Unit) {
    if (rows < PARALLEL_MIN_ROWS) {
        for (y in 0 until rows) body(y)
        return
    }
    java.util.stream.IntStream.range(0, rows).parallel().forEach { body(it) }
}

/** A FloatArray of [width] × [height] × [channels] filled per element by [value], rows in parallel. */
internal inline fun parallelFloatArray(width: Int, height: Int, channels: Int, crossinline value: (Int) -> Float): FloatArray {
    val out = FloatArray(width * height * channels)
    val rowLength = width * channels
    forEachRow(height) { y ->
        val start = y * rowLength
        for (i in start until start + rowLength) out[i] = value(i)
    }
    return out
}

internal const val PARALLEL_MIN_ROWS = 64
