package com.lightlylabs.lightly.render.lut

import com.lightlylabs.lightly.render.testing.GoldenFixtures
import com.lightlylabs.lightly.render.testing.PixelDiffStats
import com.lightlylabs.lightly.render.testing.SyntheticLuts
import kotlin.test.Test
import kotlin.test.assertTrue

/**
 * Per-platform golden test (spec §4.4) for the CPU reference: golden `fused_lut.f32` applied to
 * golden `source.png` must reproduce `reference.png`. The contract tolerance is max ≤ 2/255; an
 * exact CPU port is held to ≤ 1/255. Runs on every golden case on disk.
 */
class GoldenLutTest {

    @Test
    fun `fused LUT applied to every golden source matches the reference within 1 over 255`() {
        val report = StringBuilder()
        var worstMax = 0
        for (case in GoldenFixtures.cases) {
            val lut = Lut3D.fromLittleEndianBytes(case.fusedLutBytes())
            val rendered = CpuLutRenderer.apply(case.source(), lut)
            val stats = PixelDiffStats.between(rendered, case.reference())
            report.appendLine(
                "%-20s max %d/255  mean %.5f  >1: %.5f%%".format(case.stem, stats.maxAbs, stats.meanAbs, stats.fractionOver1 * 100),
            )
            worstMax = maxOf(worstMax, stats.maxAbs)
        }
        println("GoldenLutTest (${GoldenFixtures.cases.size} cases)\n$report")
        assertTrue(worstMax <= 1, "CPU reference exceeds 1/255 against golden references:\n$report")
    }

    @Test
    fun `golden Auto LUTs really exercise out-of-range entries`() {
        val luts = GoldenFixtures.cases.map { Lut3D.fromLittleEndianBytes(it.fusedLutBytes()) }
        assertTrue(luts.minOf { it.minValue() } < 0f, "no golden LUT goes below 0; the boundary tests would be vacuous")
        assertTrue(luts.maxOf { it.maxValue() } > 1f, "no golden LUT goes above 1; the boundary tests would be vacuous")
    }

    /**
     * Spec §4.2 allows baking O1+O2 when baked vs two-stage is max ≤ 2/255. Measured here over EVERY
     * 8-bit input colour (the domain an 8-bit decoded Original produces) for every golden Auto LUT
     * under the strong synthetic Look from test_lut_composition.py.
     *
     * CONTRACT ISSUE found in M2: the tolerance does not hold for every golden Auto LUT. The M1
     * measurement (max 1.64/255) sampled 25 000 random inputs on the first 8 golden LUTs only.
     * Auto LUTs with strong highlight overshoot (portrait_deep_03 reaches 1.475) put the §4.2
     * clamp kink inside a grid cell, which a single 33³ LUT cannot represent. The violating LUTs are
     * listed explicitly and asserted to still violate, so this list cannot go stale silently; the
     * contract decision (render O1 and O2 as two GPU stages, or revise the tolerance) is open — see
     * docs/m2/android-foundation.md. Every other LUT must stay within 2/255.
     */
    @Test
    fun `baked vs two-stage over every 8-bit input for every golden Auto LUT`() {
        val look = SyntheticLuts.strongLook()
        val report = StringBuilder()
        val withinTolerance = mutableListOf<String>()
        val overTolerance = mutableMapOf<String, Int>()
        for (case in GoldenFixtures.cases) {
            val stages = LutStages(Lut3D.fromLittleEndianBytes(case.fusedLutBytes()), look)
            val error = BakeError.overAll8BitInputs(stages, LutComposition.bake(stages))
            report.appendLine(
                "%-20s float max %.3f/255  encoded max %d/255  colours >2: %d".format(
                    case.stem, error.floatMax, error.encodedMax, error.coloursOver2,
                ),
            )
            if (error.encodedMax <= 2) withinTolerance += case.stem else overTolerance[case.stem] = error.encodedMax
        }
        println("Bake vs two-stage over all 16.7M 8-bit inputs\n$report")

        val unexpectedViolations = overTolerance.keys - knownBakeViolations.keys
        assertTrue(unexpectedViolations.isEmpty(), "new bake tolerance violations $unexpectedViolations:\n$report")
        for ((stem, ceiling) in knownBakeViolations) {
            val measured = overTolerance[stem]
            assertTrue(
                measured != null,
                "$stem now bakes within 2/255; remove it from knownBakeViolations and update the docs:\n$report",
            )
            assertTrue(measured <= ceiling, "$stem bake error grew to $measured/255 (recorded $ceiling/255):\n$report")
        }
    }

    /** Stem → encoded max error measured in M2 (8-bit units). See the test above. */
    private val knownBakeViolations = mapOf("a1629" to 3, "portrait_deep_03" to 6)

    @Test
    fun `baked and two-stage renders of a golden photo agree within 2 over 255 at partial strengths`() {
        val case = GoldenFixtures.case("a1629") // the LUT with the widest range (−0.14…1.35)
        val stages = LutStages.of(
            autoLut = Lut3D.fromLittleEndianBytes(case.fusedLutBytes()),
            autoStrength = 0.75f,
            lookLut = SyntheticLuts.strongLook(),
            lookStrength = 0.8f,
        )
        val source = case.source()

        val stats = PixelDiffStats.between(CpuLutRenderer.applyBaked(source, stages), CpuLutRenderer.applyTwoStage(source, stages))

        println("a1629 baked vs two-stage: $stats")
        assertTrue(stats.maxAbs <= 2, "baked vs two-stage on a1629: $stats")
    }
}
