package com.lightlylabs.lightly.develop

import com.lightlylabs.lightly.render.lut.Lut3D
import java.util.concurrent.Callable
import java.util.concurrent.ExecutorService

/**
 * The device bake of rendering-v2.md §4.2: develop.global sampled on an N³ grid (`linspace(0,1,N)`
 * per axis), stored in the contract layout `[b][g][r]`, red fastest, as float32 RGBA.
 *
 * The grid planes (one per blue index) are independent, so a bake can be split across an
 * [ExecutorService]; the result is identical to a single-threaded bake.
 */
object LutBaker {
    fun bake(stage: DevelopGlobal, dimension: Int = Lut3D.CONTRACT_DIMENSION, executor: ExecutorService? = null, parallelism: Int = 1): Lut3D {
        val rgba = FloatArray(Lut3D.floatCount(dimension))
        if (executor == null || parallelism <= 1) {
            bakePlanes(stage, dimension, rgba, 0, dimension)
        } else {
            val chunk = (dimension + parallelism - 1) / parallelism
            val tasks = (0 until dimension step chunk).map { first ->
                Callable { bakePlanes(stage, dimension, rgba, first, minOf(dimension, first + chunk)) }
            }
            executor.invokeAll(tasks).forEach { it.get() } // get() rethrows a failed plane
        }
        return Lut3D(dimension, rgba)
    }

    private fun bakePlanes(stage: DevelopGlobal, dimension: Int, rgba: FloatArray, firstBlue: Int, endBlue: Int) {
        val out = DoubleArray(3)
        val scratch = DoubleArray(DevelopGlobal.SCRATCH_SIZE)
        val step = dimension - 1
        val linear = DoubleArray(dimension) { ColourMath.srgbToLinear(it.toDouble() / step) }
        for (b in firstBlue until endBlue) for (g in 0 until dimension) for (r in 0 until dimension) {
            stage.evaluateLinear(linear[r], linear[g], linear[b], out, scratch)
            val base = (r + dimension * (g + dimension * b)) * 4
            rgba[base] = out[0].toFloat()
            rgba[base + 1] = out[1].toFloat()
            rgba[base + 2] = out[2].toFloat()
            rgba[base + 3] = 1f
        }
    }
}
