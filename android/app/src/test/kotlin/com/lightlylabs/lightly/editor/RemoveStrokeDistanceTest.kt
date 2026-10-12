package com.lightlylabs.lightly.editor

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * RemoveEngine.StrokeDistance replaces the per-pixel RemoveEngine.distanceToStroke in the mask and the paste-back
 * (2026-10-12, Remove speed). The stored patch must not change: within the caller's reach the distance has to be the
 * same double, bit for bit, and beyond it only "farther than the reach" matters (the mask is 0 and the alpha is 0).
 */
class RemoveStrokeDistanceTest {
    private fun assertMatchesReference(points: List<Pair<Double, Double>>, reach: Double, pixels: Sequence<Pair<Double, Double>>) {
        val fast = RemoveEngine.StrokeDistance(points)
        for ((x, y) in pixels) {
            val reference = RemoveEngine.distanceToStroke(x, y, points)
            val measured = fast.distanceWithin(x, y, reach, fast.segmentsNearRow(y, reach))
            if (reference <= reach) assertEquals(reference.toRawBits(), measured.toRawBits(), "pixel ($x, $y): $reference vs $measured")
            else assertTrue(measured > reach, "pixel ($x, $y) beyond the reach measured $measured")
        }
    }

    private fun grid(width: Int, height: Int) = sequence { for (y in 0 until height) for (x in 0 until width) yield(x + 0.5 to y + 0.5) }

    @Test fun aWigglyFingerStrokeOfManyPointsMatchesTheReferenceBitForBit() {
        val random = java.util.Random(7)
        // A finger path: one point per touch event, small steps, a few repeated points (zero-length segments).
        var x = 60.0; var y = 80.0
        val points = (0 until 160).map {
            if (it % 37 != 0) { x += random.nextGaussian() * 2 + 1.2; y += random.nextGaussian() * 2 + 0.3 }
            x to y
        }
        for (reach in listOf(12.0, 12.0 + RemoveEngine.FEATHER_PX, 17.37)) assertMatchesReference(points, reach, grid(400, 260))
    }

    @Test fun aDabAndATwoPointStrokeMatchTheReference() {
        assertMatchesReference(listOf(100.0 to 90.0), 20.0, grid(220, 200))
        assertMatchesReference(listOf(150.0 to 100.0, 180.0 to 110.0), 13.0, grid(320, 220))
    }

    @Test fun randomSubPixelSamplesMatchTheReference() {
        val random = java.util.Random(11)
        val points = (0 until 40).map { random.nextDouble() * 300 to random.nextDouble() * 300 }
        val samples = generateSequence { random.nextDouble() * 340 - 20 to random.nextDouble() * 340 - 20 }.take(60_000)
        assertMatchesReference(points, 9.5, samples)
    }
}
