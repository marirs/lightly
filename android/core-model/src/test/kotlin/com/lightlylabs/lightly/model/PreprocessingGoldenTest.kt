package com.lightlylabs.lightly.model

import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.testing.GoldenFixtures
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/** Spec §4.6: the Kotlin canonical analysis input must match golden `input256.f32` to ≤ 1e-5. */
class PreprocessingGoldenTest {

    @Test
    fun `canonical analysis input matches golden input256 on every golden case`() {
        val report = StringBuilder()
        var worst = 0.0
        for (case in GoldenFixtures.cases) {
            val source = case.source()
            val actual = CanonicalAnalysisInput.prepare(source, originalLongEdge = maxOf(source.width, source.height))
            val expected = case.input256()
            assertEquals(3 * 256 * 256, expected.size, "golden tensor shape for ${case.stem}")
            assertEquals(expected.size, actual.size)
            var caseMax = 0.0
            for (i in actual.indices) caseMax = maxOf(caseMax, abs(actual[i] - expected[i]).toDouble())
            report.appendLine("%-20s %dx%d  max |Δ| %.3e".format(case.stem, source.width, source.height, caseMax))
            worst = maxOf(worst, caseMax)
        }
        println("Canonical analysis input vs golden input256.f32\n$report")
        assertTrue(worst <= 1e-5, "preprocessing exceeds 1e-5:\n$report")
    }

    @Test
    fun `the display proxy is rejected as model input`() {
        val proxy = Rgba8Image(800, 600, ByteArray(800 * 600 * 4))
        assertFailsWith<IllegalArgumentException> { CanonicalAnalysisInput.prepare(proxy, originalLongEdge = 4032) }
    }

    @Test
    fun `a small Original is used at its full size`() {
        val small = Rgba8Image(640, 480, ByteArray(640 * 480 * 4) { 0x40 })
        val tensor = CanonicalAnalysisInput.prepare(small, originalLongEdge = 640)
        assertTrue(tensor.all { abs(it - 0x40 / 255f) < 1e-6f }, "a flat image stays flat through the filter")
    }
}
