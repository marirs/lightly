package com.lightlylabs.lightly.background

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Peak-heap bound of Background with a subject matte (the case that exhausted the app's 192 MB heap on
 * the Pixel 9 Pro emulator at 1600 px). Runs in its own JVM with a 150 MB heap (core-background
 * `backgroundMemoryTest`, part of `test`): an OutOfMemoryError fails it. 150 MB leaves the app ≥ 42 MB
 * for everything else; the work below is the most the app holds for Background at once.
 */
class BackgroundMemoryTest {
    private fun scene(w: Int, h: Int): Triple<ByteArray, BackgroundAnalysis, FloatImage> {
        val developed = ByteArray(w * h * 4) { i -> if (i % 4 == 3) -1 else ((i / 4 % w + i / 4 / w + i % 4 * 40) % 251).toByte() }
        val nearness = FloatPlane(w, h, FloatArray(w * h) { (it % w).toFloat() / w })
        val matte = FloatPlane(w, h, FloatArray(w * h) { p -> val x = p % w - w / 2; val y = p / w - h / 2; if (x * x + y * y < (h / 3) * (h / 3)) 1f else 0f })
        val replacement = ReplacementImage.colour(w, h, "#3C4A55")
        return Triple(developed, BackgroundAnalysis(w, h, NormalisedDepth(DepthOrigin.ESTIMATED, nearness), matte), replacement)
    }

    private fun plan(style: String, replacement: FloatImage?, full: ReplacementPixels?) =
        BackgroundPlan(replacement, FocusParams(60.0, 40.0, style, "round", 50.0), 0.3, null, full)

    @Test
    fun `settled preview at 1024 px with a matte and a replacement, applied to the 1600 px display proxy`() {
        val (developed, analysis, replacement) = scene(BackgroundStage.PREVIEW_CAP, 683)
        val display = ByteArray(1600 * 1067 * 4) { if (it % 4 == 3) -1 else 90 }
        val full = ReplacementPixels(1600, 1067, ByteArray(1600 * 1067 * 4) { if (it % 4 == 3) -1 else 60 })
        for (style in listOf("lens", "soft", "swirl", "motion")) {
            val working = BackgroundStage.renderWorking(developed, analysis, plan(style, replacement, full), Refocus.FocusConstants.LAYERS_PER_SIDE_PREVIEW)
            val out = BackgroundStage.applyRegion(display, 0, 0, 1600, 1067, 1600, 1067, working, full)
            assertEquals(display.size, out.size)
        }
    }

    @Test
    fun `Save copy of a 12 MP frame at K = 8, tile by tile, next to the frame`() {
        val frame = ByteArray(4032 * 3024 * 4) { if (it % 4 == 3) -1 else 120 }
        val (ww, wh) = BackgroundStage.workingSize(4032, 3024, BackgroundStage.EXPORT_CAP)
        val (developed, analysis, replacement) = scene(ww, wh)
        val full = ReplacementPixels(1600, 1200, ByteArray(1600 * 1200 * 4) { if (it % 4 == 3) -1 else 60 })
        val working = BackgroundStage.renderWorking(developed, analysis, plan("lens", replacement, full), Refocus.FocusConstants.LAYERS_PER_SIDE_EXPORT)
        var tiles = 0
        for (y in 0 until 3024 step 1024) for (x in 0 until 4032 step 1024) {
            val tw = minOf(1024, 4032 - x)
            val th = minOf(1024, 3024 - y)
            val tile = ByteArray(tw * th * 4)
            for (row in 0 until th) System.arraycopy(frame, ((y + row) * 4032 + x) * 4, tile, row * tw * 4, tw * 4)
            BackgroundStage.applyRegion(tile, x, y, tw, th, 4032, 3024, working, full)
            tiles++
        }
        assertTrue(tiles == 12)
    }
}
