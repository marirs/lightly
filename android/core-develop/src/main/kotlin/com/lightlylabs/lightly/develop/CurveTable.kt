package com.lightlylabs.lightly.develop

/**
 * Point-curve tables (rendering-v2.md §4.1 G7, reference_model.curve_table / apply_curve_table).
 *
 * A curve is sampled at t = i/255 into 256 float32 values, so lookup cost is independent of the
 * number of control points. The values are stored as float32 because the reference casts them
 * (`astype(np.float32)`) before interpolating in float64; keeping that rounding keeps parity exact.
 */
class CurveTable private constructor(private val values: FloatArray) {

    /** `apply_curve_table`: clamp, then linear interpolation between neighbouring entries. */
    fun apply(encoded: Double): Double {
        val position = encoded.coerceIn(0.0, 1.0) * (SIZE - 1)
        val index = ColourMath.floorInt(position).coerceIn(0, SIZE - 2)
        val fraction = position - index
        return values[index].toDouble() * (1 - fraction) + values[index + 1].toDouble() * fraction
    }

    companion object {
        const val SIZE = 256

        /** [[x, y], …] in 0…255, x strictly increasing (checked when the recipe is parsed). */
        fun of(points: List<DoubleArray>): CurveTable {
            val xs = DoubleArray(points.size) { points[it][0] / 255.0 }
            val ys = DoubleArray(points.size) { points[it][1] / 255.0 }
            val table = FloatArray(SIZE)
            val second = if (points.size > 2) naturalSecondDerivatives(xs, ys) else null
            for (i in 0 until SIZE) {
                val t = i / 255.0
                val y = when {
                    second == null -> interpolateLinear(xs, ys, t)
                    t < xs.first() -> ys.first()
                    t > xs.last() -> ys.last()
                    else -> evaluateSpline(xs, ys, second, t.coerceIn(xs.first(), xs.last()))
                }
                table[i] = y.coerceIn(0.0, 1.0).toFloat()
            }
            return CurveTable(table)
        }

        /** np.interp: piecewise linear, holding the end values outside [x0, xN]. */
        private fun interpolateLinear(xs: DoubleArray, ys: DoubleArray, t: Double): Double {
            if (t <= xs.first()) return ys.first()
            if (t >= xs.last()) return ys.last()
            var segment = 0
            while (segment < xs.size - 2 && t >= xs[segment + 1]) segment++
            val fraction = (t - xs[segment]) / (xs[segment + 1] - xs[segment])
            return ys[segment] + fraction * (ys[segment + 1] - ys[segment])
        }

        /**
         * The natural spline's knot second derivatives, solved with the same Thomas elimination as
         * reference_model.natural_cubic_spline (so rounding follows the same path).
         */
        private fun naturalSecondDerivatives(xs: DoubleArray, ys: DoubleArray): DoubleArray {
            val n = xs.size
            val h = DoubleArray(n - 1) { xs[it + 1] - xs[it] }
            val sub = DoubleArray(n - 2) { h[it] }
            val diag = DoubleArray(n - 2) { 2 * (h[it] + h[it + 1]) }
            val sup = DoubleArray(n - 2) { h[it + 1] }
            val rhs = DoubleArray(n - 2) { 6 * ((ys[it + 2] - ys[it + 1]) / h[it + 1] - (ys[it + 1] - ys[it]) / h[it]) }
            for (i in 1 until n - 2) {
                val factor = sub[i] / diag[i - 1]
                diag[i] -= factor * sup[i - 1]
                rhs[i] -= factor * rhs[i - 1]
            }
            val interior = DoubleArray(n - 2)
            interior[n - 3] = rhs[n - 3] / diag[n - 3]
            for (i in n - 4 downTo 0) interior[i] = (rhs[i] - sup[i] * interior[i + 1]) / diag[i]
            return DoubleArray(n) { if (it == 0 || it == n - 1) 0.0 else interior[it - 1] }
        }

        private fun evaluateSpline(xs: DoubleArray, ys: DoubleArray, second: DoubleArray, q: Double): Double {
            val n = xs.size
            // np.searchsorted(xs, q, side="right") - 1, clipped to a valid segment.
            var count = 0
            while (count < n && xs[count] <= q) count++
            val segment = (count - 1).coerceIn(0, n - 2)
            val x0 = xs[segment]
            val x1 = xs[segment + 1]
            val width = x1 - x0
            val a = (x1 - q) / width
            val b = (q - x0) / width
            return a * ys[segment] + b * ys[segment + 1] + ((a * a * a - a) * second[segment] + (b * b * b - b) * second[segment + 1]) * width * width / 6
        }
    }
}
