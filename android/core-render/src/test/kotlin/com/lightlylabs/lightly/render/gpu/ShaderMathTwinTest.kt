package com.lightlylabs.lightly.render.gpu

import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.lut.CpuLutPassRenderer
import com.lightlylabs.lightly.render.lut.Lut3D
import com.lightlylabs.lightly.render.lut.LutPassPlan
import com.lightlylabs.lightly.render.testing.GoldenFixtures
import com.lightlylabs.lightly.render.testing.PixelDiffStats
import com.lightlylabs.lightly.render.testing.SyntheticLuts
import kotlin.math.floor
import kotlin.math.roundToInt
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * A float32 Kotlin twin of the generated fragment shader (mix-based trilinear, GLSL
 * `mix(x, y, a) = x·(1−a) + y·a`, unorm8 round-to-nearest output). It checks that the *algorithm*
 * the GPU will run agrees with the CPU oracle and the golden references. It does not prove a real
 * GPU executes it that way: GPU accuracy on Adreno/Mali is PENDING.
 */
class ShaderMathTwinTest {

    private fun mix(x: Float, y: Float, a: Float) = x * (1f - a) + y * a

    private fun applyLutTwin(lut: Lut3D, color: FloatArray) {
        val n = lut.dimension
        val scaled = FloatArray(3) { color[it].coerceIn(0f, 1f) * (n - 1) }
        val base = IntArray(3) { floor(scaled[it]).toInt().coerceIn(0, n - 2) }
        val frac = FloatArray(3) { scaled[it] - base[it] }
        fun corner(dr: Int, dg: Int, db: Int, channel: Int) = lut.rgba[lut.entryIndex(base[0] + dr, base[1] + dg, base[2] + db) + channel]
        for (channel in 0 until 3) {
            val c00 = mix(corner(0, 0, 0, channel), corner(1, 0, 0, channel), frac[0])
            val c10 = mix(corner(0, 1, 0, channel), corner(1, 1, 0, channel), frac[0])
            val c01 = mix(corner(0, 0, 1, channel), corner(1, 0, 1, channel), frac[0])
            val c11 = mix(corner(0, 1, 1, channel), corner(1, 1, 1, channel), frac[0])
            val c0 = mix(c00, c10, frac[1])
            val c1 = mix(c01, c11, frac[1])
            color[channel] = mix(c0, c1, frac[2])
        }
    }

    private fun renderTwin(source: Rgba8Image, plan: LutPassPlan): Rgba8Image {
        val out = ByteArray(source.pixels.size)
        val color = FloatArray(3)
        for (pixel in 0 until source.pixelCount) {
            val base = pixel * 4
            for (c in 0 until 3) color[c] = (source.pixels[base + c].toInt() and 0xff) / 255f
            for (lut in plan.passes) applyLutTwin(lut, color)
            // GLES unorm conversion: round to nearest after the single clamp.
            for (c in 0 until 3) out[base + c] = (color[c].coerceIn(0f, 1f) * 255f).roundToInt().toByte()
            out[base + 3] = source.pixels[base + 3]
        }
        return Rgba8Image(source.width, source.height, out)
    }

    @Test
    fun `shader algorithm reproduces golden references within 1 over 255`() {
        val report = StringBuilder()
        var worst = 0
        for (stem in listOf("a1629", "portrait_deep_03", "night_03")) {
            val case = GoldenFixtures.case(stem)
            val plan = LutPassPlan.ofBlended(Lut3D.fromLittleEndianBytes(case.fusedLutBytes()))
            val stats = PixelDiffStats.between(renderTwin(case.source(), plan), case.reference())
            report.appendLine("$stem: $stats")
            worst = maxOf(worst, stats.maxAbs)
        }
        println(report)
        assertTrue(worst <= 1, "shader twin vs golden:\n$report")
    }

    @Test
    fun `two-pass shader algorithm matches the CPU oracle within 1 over 255`() {
        val case = GoldenFixtures.case("portrait_deep_03") // the Auto LUT with the largest overshoot (1.475)
        val plan = LutPassPlan.of(Lut3D.fromLittleEndianBytes(case.fusedLutBytes()), 0.8f, SyntheticLuts.strongLook(), 0.9f)
        val source = case.source()

        val stats = PixelDiffStats.between(renderTwin(source, plan), CpuLutPassRenderer.render(source, plan))

        println("two-pass twin vs CPU oracle: $stats")
        assertTrue(stats.maxAbs <= 1, "two-pass twin vs CPU oracle: $stats")
    }
}
