package com.lightlylabs.lightly.render.testing

import com.lightlylabs.lightly.render.image.Rgba8Image
import kotlin.math.abs

/** 8-bit RGB difference statistics (alpha ignored), the units of the §4.4 tolerances. */
data class PixelDiffStats(
    val maxAbs: Int,
    val meanAbs: Double,
    /** Share of pixels whose largest channel difference is > 1 (§4.4: must be ≤ 1%). */
    val fractionOver1: Double,
) {
    companion object {
        fun between(actual: Rgba8Image, expected: Rgba8Image): PixelDiffStats {
            require(actual.width == expected.width && actual.height == expected.height) {
                "Size mismatch: ${actual.width}x${actual.height} vs ${expected.width}x${expected.height}"
            }
            var maxAbs = 0
            var sumAbs = 0L
            var over1 = 0L
            for (pixel in 0 until actual.pixelCount) {
                var pixelMax = 0
                for (channel in 0 until 3) {
                    val index = pixel * 4 + channel
                    val diff = abs((actual.pixels[index].toInt() and 0xff) - (expected.pixels[index].toInt() and 0xff))
                    sumAbs += diff
                    if (diff > pixelMax) pixelMax = diff
                }
                if (pixelMax > maxAbs) maxAbs = pixelMax
                if (pixelMax > 1) over1++
            }
            return PixelDiffStats(
                maxAbs = maxAbs,
                meanAbs = sumAbs.toDouble() / (actual.pixelCount * 3.0),
                fractionOver1 = over1.toDouble() / actual.pixelCount,
            )
        }
    }
}
