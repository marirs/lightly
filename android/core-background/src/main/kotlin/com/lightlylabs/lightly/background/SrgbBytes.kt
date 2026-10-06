package com.lightlylabs.lightly.background

/**
 * Exact tables for 8-bit sRGB in the Background stage (2026-10-06, speed): per-pixel `pow` calls were a large part of
 * a Background drag frame. Both tables give the same values as the functions they replace.
 */
internal object SrgbBytes {
    /** [Refocus.srgbToLinear] of each byte value b, computed from b / 255f exactly as the per-pixel code did. */
    val TO_LINEAR = FloatArray(256) { Refocus.srgbToLinear(it / 255f) }

    /** The byte the per-pixel code wrote for a linear value: (linearToSrgb(v) · 255 + 0.5) truncated, clamped. */
    fun reference(v: Float): Byte = (Refocus.linearToSrgb(v) * 255f + 0.5f).toInt().coerceIn(0, 255).toByte()

    /**
     * THRESHOLD[k] (k = 1…255): the smallest float v in [0, 1] whose [reference] byte is ≥ k. [reference] is
     * non-decreasing in v (Math.pow is semi-monotonic, and every other step preserves order), so the byte of v is the
     * number of thresholds ≤ v. Found by bisection on the float bit patterns (ordered like the values for v ≥ 0).
     */
    private val THRESHOLD = FloatArray(256).also { t ->
        for (k in 1..255) {
            var lo = 0                                   // bits of a float whose byte is < k
            var hi = java.lang.Float.floatToRawIntBits(1f) // bits of a float whose byte is ≥ k (255)
            while (hi - lo > 1) {
                val mid = (lo + hi) ushr 1
                if ((reference(java.lang.Float.intBitsToFloat(mid)).toInt() and 0xff) >= k) hi = mid else lo = mid
            }
            t[k] = java.lang.Float.intBitsToFloat(hi)
        }
    }

    private const val BUCKETS = 4096

    /** For each bucket [b/BUCKETS, (b+1)/BUCKETS): a byte no greater than that of any value in it (start of the scan). */
    private val BUCKET_START = IntArray(BUCKETS) { b ->
        val low = maxOf(0f, (b - 1).toFloat() / BUCKETS)
        reference(low).toInt() and 0xff
    }

    /** Same result as [reference] for every float. */
    fun encodeLinear(v: Float): Byte {
        if (!(v > 0f)) return reference(v)   // ≤ 0, −0 and NaN keep the original path
        if (v >= 1f) return 255.toByte()
        var k = BUCKET_START[(v * BUCKETS).toInt()]
        while (k < 255 && v >= THRESHOLD[k + 1]) k++
        return k.toByte()
    }
}
