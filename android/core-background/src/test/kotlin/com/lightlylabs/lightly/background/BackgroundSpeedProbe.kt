package com.lightlylabs.lightly.background

import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Speed probe for the Android rendering work package (completion plan A1): times the Background stages of a ruler-drag
 * frame and of a settled frame at the app's sizes, and samples the stacks of every thread to show where the time goes.
 * Not a pass/fail test: it runs only with -Plightly.probe (gradle) / -Dlightly.probe=true and prints its report.
 */
class BackgroundSpeedProbe {
    private fun scene(w: Int, h: Int): Triple<ByteArray, BackgroundAnalysis, FloatImage> {
        // A portrait-like layout: the subject an ellipse in the lower middle (near), the rest a far plane (a replacement
        // is placed as one plane), soft matte edge of a few pixels. Texture so convolutions see real values.
        val developed = ByteArray(w * h * 4) { i -> if (i % 4 == 3) -1 else ((i / 4 % w * 7 + i / 4 / w * 3 + i % 4 * 40) % 251).toByte() }
        val inside = { x: Int, y: Int -> val dx = (x - w / 2.0) / (w * 0.33); val dy = (y - h * 0.62) / (h * 0.45); dx * dx + dy * dy }
        val matte = FloatPlane(w, h, FloatArray(w * h) { p -> (1.5f - inside(p % w, p / w).toFloat() * 1.5f).coerceIn(0f, 1f) })
        val nearness = FloatPlane(w, h, FloatArray(w * h) { p -> if (matte.values[p] > 0.5f) 0.75f + 0.05f * (p / w).toFloat() / h else 0.1f })
        val replacement = ReplacementImage.gradient(w, h, 90.0, listOf("#3C4A55" to 0.0, "#C8A060" to 1.0))
        return Triple(developed, BackgroundAnalysis(w, h, NormalisedDepth(DepthOrigin.ESTIMATED, nearness), matte), replacement)
    }

    private fun plan(replacement: FloatImage, full: ReplacementPixels) =
        BackgroundPlan(replacement, FocusParams(60.0, 40.0, "lens", "round", 50.0), 0.8, null, full)

    private class Sampler : Thread("probe-sampler") {
        val counts = HashMap<String, Int>()
        @Volatile var running = true
        override fun run() {
            while (running) {
                for ((thread, stack) in Thread.getAllStackTraces()) {
                    if (thread === this || thread.state != State.RUNNABLE) continue
                    val top = stack.firstOrNull { it.className.startsWith("com.lightlylabs") } ?: continue
                    val key = "${top.className.substringAfterLast('.')}.${top.methodName}:${top.lineNumber}"
                    counts[key] = (counts[key] ?: 0) + 1
                }
                sleep(2)
            }
        }
    }

    private fun timed(label: String, block: () -> Unit): Double {
        var best = Double.MAX_VALUE
        repeat(8) { val t = System.nanoTime(); block(); best = minOf(best, (System.nanoTime() - t) / 1e6) }
        println("PROBE $label: best of 8 = ${"%.0f".format(best)} ms")
        return best
    }

    @Test
    fun `drag and settled Background stages`() {
        assumeTrue(System.getProperty("lightly.probe") == "true")
        println("PROBE cores=${Runtime.getRuntime().availableProcessors()}")
        val (dw, dh) = 853 to 1280
        val display = ByteArray(dw * dh * 4) { if (it % 4 == 3) -1 else ((it * 31) % 251).toByte() }
        val full = ReplacementPixels(dw, dh, ByteArray(dw * dh * 4) { if (it % 4 == 3) -1 else 60 })
        val sampler = Sampler().also { it.isDaemon = true; it.start() }
        for ((label, cap, layers) in listOf(Triple("drag 320", 320, Refocus.FocusConstants.LAYERS_PER_SIDE_PREVIEW),
                                           Triple("drag 640", BackgroundStage.INTERACTIVE_CAP, Refocus.FocusConstants.LAYERS_PER_SIDE_PREVIEW),
                                           Triple("settled 1024", BackgroundStage.PREVIEW_CAP, Refocus.FocusConstants.LAYERS_PER_SIDE_PREVIEW))
                                           .filter { System.getProperty("lightly.probe.only")?.let { only -> it.first.contains(only) } ?: true }) {
            val (ww, wh) = BackgroundStage.workingSize(dw, dh, cap)
            val (developed, analysis, replacement) = scene(ww, wh)
            var working: WorkingBackground? = null
            // Each drag frame has a new Look, so a new developed photo: vary it per run (the foreground estimate is cached
            // by content and would otherwise run once).
            var run = 0
            timed("$label renderWorking ${ww}x$wh (new Look each run)") {
                run++
                val graded = ByteArray(developed.size) { i -> if (i % 4 == 3) -1 else (developed[i] + run).toByte() }
                working = BackgroundStage.renderWorking(graded, analysis, plan(replacement, full), layers)
            }
            // A drag frame is composited at the half-size proxy (426×640 here), a settled frame at the display size.
            val frame = if (cap < BackgroundStage.PREVIEW_CAP) (dw / 2) to (dh / 2) else dw to dh
            val region = ByteArray(frame.first * frame.second * 4) { if (it % 4 == 3) -1 else 90 }
            timed("$label applyRegion ${frame.first}x${frame.second}") { BackgroundStage.applyRegion(region, 0, 0, frame.first, frame.second, frame.first, frame.second, working!!, full) }
        }
        sampler.running = false; sampler.join()
        val total = sampler.counts.values.sum().toDouble()
        sampler.counts.entries.sortedByDescending { it.value }.take(25).forEach { println("PROBE sample ${"%5.1f".format(it.value * 100 / total)} % ${it.key}") }
    }

    /**
     * One settled Background frame at the app's sizes (1067 × 1600 display, 1024 px working, replacement + blur, a new
     * Look so the foreground estimate runs). Run in a JVM capped with -Plightly.probe.heap=<MB>: the smallest cap at
     * which it completes is its live set plus its transient peak (completion plan A1, memory).
     */
    @Test
    fun `settled frame within the probe heap`() {
        assumeTrue(System.getProperty("lightly.probe") == "true")
        val (dw, dh) = 1067 to 1600
        val cap = System.getProperty("lightly.probe.cap")?.toInt() ?: BackgroundStage.PREVIEW_CAP
        val (ww, wh) = BackgroundStage.workingSize(dw, dh, cap)
        val (developed, analysis, replacement) = scene(ww, wh)
        val full = ReplacementPixels(dw, dh, ByteArray(dw * dh * 4) { if (it % 4 == 3) -1 else 60 })
        val region = ByteArray(dw * dh * 4) { if (it % 4 == 3) -1 else 90 }
        val working = BackgroundStage.renderWorking(developed, analysis, plan(replacement, full), Refocus.FocusConstants.LAYERS_PER_SIDE_PREVIEW)
        BackgroundStage.applyRegion(region, 0, 0, dw, dh, dw, dh, working, full)
        println("PROBE settled frame completed within ${Runtime.getRuntime().maxMemory() / 1_048_576} MB")
    }
}
