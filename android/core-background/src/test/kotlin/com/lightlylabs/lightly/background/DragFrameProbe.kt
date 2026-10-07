package com.lightlylabs.lightly.background

import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Drag-frame timing probe (completion plan A1, 2026-10-07): the Background work of one ruler-drag frame at the app's
 * sizes (scene 320 × 480 with a replacement and lens blur, composite at the 533 × 800 half-size proxy), a new Look
 * each frame. Runs only with -Dlightly.probe=true; prints the median and quartiles of 40 frames after 10 warm-up frames.
 * Run with -Djava.util.concurrent.ForkJoinPool.common.parallelism=3 to match a 4-core device.
 */
class DragFrameProbe {
    @Test
    fun `drag frame background stage`() {
        assumeTrue(System.getProperty("lightly.probe") == "true")
        val (w, h) = 320 to 480
        val developed = ByteArray(w * h * 4) { i -> if (i % 4 == 3) -1 else ((i / 4 % w * 7 + i / 4 / w * 3 + i % 4 * 40) % 251).toByte() }
        val inside = { x: Int, y: Int -> val dx = (x - w / 2.0) / (w * 0.33); val dy = (y - h * 0.62) / (h * 0.45); dx * dx + dy * dy }
        val matte = FloatPlane(w, h, FloatArray(w * h) { p -> (1.5f - inside(p % w, p / w).toFloat() * 1.5f).coerceIn(0f, 1f) })
        val nearness = FloatPlane(w, h, FloatArray(w * h) { p -> if (matte.values[p] > 0.5f) 0.75f else 0.1f + 0.2f * (p % w).toFloat() / w })
        val analysis = BackgroundAnalysis(w, h, NormalisedDepth(DepthOrigin.ESTIMATED, nearness), matte)
        val (fw, fh) = 533 to 800
        val full = ReplacementPixels(fw, fh, ByteArray(fw * fh * 4) { if (it % 4 == 3) -1 else 60 })
        val plan = BackgroundPlan(ReplacementImage.gradient(w, h, 90.0, listOf("#3C4A55" to 0.0, "#C8A060" to 1.0)), FocusParams(60.0, 40.0, "lens", "round", 50.0), 0.8, null, full)
        val region = ByteArray(fw * fh * 4) { if (it % 4 == 3) -1 else 90 }
        val times = ArrayList<Double>()
        for (frame in 0 until 50) {
            val look = ByteArray(developed.size) { i -> if (i % 4 == 3) -1 else (developed[i] + frame * 3).toByte() }
            val t = System.nanoTime()
            val working = DragFrameCall.renderWorking(look, analysis, plan)
            BackgroundStage.applyRegion(region, 0, 0, fw, fh, fw, fh, working, full)
            if (frame >= 10) times += (System.nanoTime() - t) / 1e6
        }
        times.sort()
        println("PROBE drag frame (${System.getProperty("lightly.probe.label") ?: "?"}): median ${"%.0f".format(times[times.size / 2])} ms, " +
            "p25 ${"%.0f".format(times[times.size / 4])}, p75 ${"%.0f".format(times[times.size * 3 / 4])}, threads ${java.util.concurrent.ForkJoinPool.commonPool().parallelism + 1}")
    }
}
