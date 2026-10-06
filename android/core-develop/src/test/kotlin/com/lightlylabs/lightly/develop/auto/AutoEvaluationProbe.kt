package com.lightlylabs.lightly.develop.auto

import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import javax.imageio.ImageIO
import kotlin.math.sqrt

/**
 * Android Auto, controlled evaluation (completion plan A3): the iOS protocol (experiments/auto-ci/eval/main.swift) on
 * the same 12 approved photos at 1024 px: each degraded in linear light ("under" −1.5 EV: × 0.354; "warm cast":
 * R × 1.18, B × 0.78), Auto run on the original and on each copy; mean CIELAB distance to the original before and after
 * (every 4th pixel), classed improved / unchanged / worse at ± 0.5. Faces: the desktop BlazeFace boxes (faces.json).
 * Development evidence only (synthetic degradations). Runs with -Plightly.probe; writes eval.txt.
 */
class AutoEvaluationProbe {
    @Test
    fun `controlled evaluation on the approved photos`() {
        assumeTrue(System.getProperty("lightly.probe") == "true")
        val dir = File(System.getProperty("lightly.autoEvalDir"))
        val faces = Regex(""""(\w+)": \[(.*?)\]\s*(,|\n\})""", RegexOption.DOT_MATCHES_ALL).findAll(File(dir, "faces.json").readText()).associate { m ->
            m.groupValues[1] to Regex("""\[([-\d.e]+),\s*([-\d.e]+),\s*([-\d.e]+),\s*([-\d.e]+)\]""").findAll(m.groupValues[2]).map {
                val (x0, y0, x1, y1) = it.destructured
                AutoAnalysis.Face(x0.toDouble(), y0.toDouble(), x1.toDouble() - x0.toDouble(), y1.toDouble() - y0.toDouble())
            }.toList()
        }
        val lines = ArrayList<String>()
        val counts = sortedMapOf<String, Int>()
        for (name in faces.keys) {
            val original = load(File(dir, "proxies/$name.png"))
            val f = faces.getValue(name)
            val originalCorrection = AutoAnalysis.analyse(original, f)
            val autoOriginal = corrected(original, originalCorrection)
            lines += "%-18s original: Auto moved it ΔE %.1f".format(name, deltaE(autoOriginal, original))
            lines += "                     " + originalCorrection.notes.drop(1).dropLast(1).joinToString("; ")
            for ((label, gains) in listOf("under -1.5EV" to doubleArrayOf(0.354, 0.354, 0.354), "warm cast" to doubleArrayOf(1.18, 1.0, 0.78))) {
                val degraded = degrade(original, gains)
                val correction = AutoAnalysis.analyse(degraded, f)
                val before = deltaE(degraded, original)
                val after = deltaE(corrected(degraded, correction), original)
                val verdict = if (after < before - 0.5) "improved" else if (after > before + 0.5) "WORSE" else "unchanged"
                counts["$label $verdict"] = (counts["$label $verdict"] ?: 0) + 1
                lines += " %-13s ΔE to original %.1f → %.1f  (%s)".format(label, before, after, verdict)
                lines += "                     " + correction.notes.drop(1).dropLast(1).joinToString("; ")
            }
        }
        lines += counts.entries.joinToString("; ") { "${it.key}: ${it.value}" }
        File(dir, "eval.txt").writeText(lines.joinToString("\n") + "\n")
        lines.forEach { println("PROBE $it") }
    }

    private fun load(file: File): AutoAnalysis.Image {
        val image = ImageIO.read(file)
        val w = image.width; val h = image.height
        val rgba = ByteArray(w * h * 4)
        for (y in 0 until h) for (x in 0 until w) {
            val p = image.getRGB(x, y); val i = (y * w + x) * 4
            rgba[i] = (p shr 16 and 0xff).toByte(); rgba[i + 1] = (p shr 8 and 0xff).toByte(); rgba[i + 2] = (p and 0xff).toByte(); rgba[i + 3] = -1
        }
        return AutoAnalysis.Image(w, h, rgba)
    }

    private fun degrade(image: AutoAnalysis.Image, gains: DoubleArray) = AutoAnalysis.Image(image.width, image.height, ByteArray(image.rgba.size) { i ->
        if (i % 4 == 3) -1 else (AutoCorrection.encode((AutoCorrection.decode((image.rgba[i].toInt() and 0xff) / 255.0) * gains[i % 4]).coerceIn(0.0, 1.0)) * 255 + 0.5).toInt().toByte()
    })

    /** The app's path: the correction baked into the 33³ LUT, sampled per pixel. */
    private fun corrected(image: AutoAnalysis.Image, correction: AutoCorrection): AutoAnalysis.Image {
        val lut = correction.lut()
        val out = FloatArray(3)
        val bytes = ByteArray(image.rgba.size)
        for (p in 0 until image.width * image.height) {
            val i = p * 4
            lut.sample((image.rgba[i].toInt() and 0xff) / 255f, (image.rgba[i + 1].toInt() and 0xff) / 255f, (image.rgba[i + 2].toInt() and 0xff) / 255f, out)
            for (c in 0 until 3) bytes[i + c] = (out[c] * 255 + 0.5f).toInt().coerceIn(0, 255).toByte()
            bytes[i + 3] = -1
        }
        return AutoAnalysis.Image(image.width, image.height, bytes)
    }

    private fun deltaE(a: AutoAnalysis.Image, b: AutoAnalysis.Image): Double {
        var sum = 0.0; var n = 0
        for (i in a.rgba.indices step 16) {
            val p = AutoAnalysis.lab(a.rgba[i].toInt() and 0xff, a.rgba[i + 1].toInt() and 0xff, a.rgba[i + 2].toInt() and 0xff)
            val q = AutoAnalysis.lab(b.rgba[i].toInt() and 0xff, b.rgba[i + 1].toInt() and 0xff, b.rgba[i + 2].toInt() and 0xff)
            sum += sqrt((p.first - q.first).let { it * it } + (p.second - q.second).let { it * it } + (p.third - q.third).let { it * it }); n++
        }
        return sum / n
    }
}
