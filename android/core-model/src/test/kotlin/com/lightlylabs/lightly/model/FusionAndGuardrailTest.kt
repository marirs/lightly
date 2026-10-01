package com.lightlylabs.lightly.model

import com.lightlylabs.lightly.render.lut.Lut3D
import com.lightlylabs.lightly.render.testing.GoldenFixtures
import com.lightlylabs.lightly.render.testing.SyntheticLuts
import com.lightlylabs.lightly.session.AutoGuardrail
import java.io.File
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.test.fail

class FusionAndGuardrailTest {

    /**
     * Research basis LUTs (experiments/lut3d/models, git-ignored, research-only licence). Read in
     * place for the test only; never packaged. Missing → FAIL with instructions, not skip.
     */
    private val basis: BasisLuts by lazy {
        val dir = System.getProperty("lightly.modelsDir") ?: fail("System property lightly.modelsDir is not set")
        val file = File(dir, "ia3dlut_basis_luts_f32.bin")
        if (!file.isFile) {
            fail(
                "Basis LUTs not found at '$file'. Generate with experiments/lut3d/reference/convert.py, or pass " +
                    "-PlightlyModelsDir=/abs/path/to/experiments/lut3d/models (or LIGHTLY_MODELS_DIR).",
            )
        }
        // Load through the registry with the sha256 pinned by MODEL_CARD.json, as the app will.
        val card = File(dir, "MODEL_CARD.json").takeIf { it.isFile }?.readText()
            ?: fail("MODEL_CARD.json missing next to $file")
        val pinnedSha = Regex("\"ia3dlut_basis_luts_f32\\.bin\"\\s*:\\s*\\{[^}]*\"sha256\"\\s*:\\s*\"([0-9a-f]{64})\"")
            .find(card)?.groupValues?.get(1) ?: fail("MODEL_CARD.json has no sha256 for the basis file")
        val key = ModelKey("ia3dlut", "research-fivek-b491f6d")
        when (val resolution = BasisRegistry(listOf(InstalledBasis.fromFile(key, file, pinnedSha))).resolve(key)) {
            is BasisResolution.Available -> resolution.basis
            is BasisResolution.Unavailable -> fail("Research basis failed verification: ${resolution.reason}")
        }
    }

    @Test
    fun `fusing the basis with golden deploy weights reproduces every golden fused LUT`() {
        val report = StringBuilder()
        var worst = 0.0
        for (case in GoldenFixtures.cases) {
            val fused = basis.fuse(case.deployWeights())
            val golden = Lut3D.fromLittleEndianBytes(case.fusedLutBytes())
            var caseMax = 0.0
            for (i in fused.rgba.indices) caseMax = maxOf(caseMax, abs(fused.rgba[i] - golden.rgba[i]).toDouble())
            report.appendLine("%-20s max |Δ| %.3e".format(case.stem, caseMax))
            worst = maxOf(worst, caseMax)
        }
        println("Fusion vs golden fused_lut.f32\n$report")
        // 1e-5 in LUT units is 0.0026/255: far below anything visible, loose enough for summation order.
        assertTrue(worst <= 1e-5, "fusion differs from golden:\n$report")
    }

    @Test
    fun `fusion is linear in the weights and forces alpha to 1`() {
        val a = SyntheticLuts.outOfRangeAuto()
        val b = Lut3D.identity()
        val fused = BasisLuts(listOf(a, b)).fuse(floatArrayOf(2f, -1f))
        for (i in fused.rgba.indices) {
            val expected = if (i % 4 == 3) 1f else 2f * a.rgba[i] + -1f * b.rgba[i]
            assertEquals(expected, fused.rgba[i])
        }
    }

    @Test
    fun `endpoint guardrail maps out-of-range black to 0 and short white to 1`() {
        // Black corner below 0, white corner below 1 in every channel.
        val lut = SyntheticLuts.fromFunction(33) { r, g, b, out ->
            out[0] = 0.9f * r - 0.1f; out[1] = 0.8f * g - 0.05f; out[2] = 0.95f * b - 0.02f
        }

        val guarded = AutoGuardrails.apply(AutoGuardrail.ENDPOINT_V1, lut)

        val black = guarded.entryIndex(0, 0, 0)
        val white = guarded.entryIndex(32, 32, 32)
        for (channel in 0 until 3) {
            assertEquals(0f, guarded.rgba[black + channel], 1e-6f)
            assertEquals(1f, guarded.rgba[white + channel], 1e-6f)
        }
    }

    @Test
    fun `endpoint guardrail leaves an in-range channel untouched`() {
        // Black ≥ 0 and white ≥ 1 (highlights above 1 are allowed): nothing to correct.
        val lut = SyntheticLuts.fromFunction(33) { r, g, b, out ->
            out[0] = 0.02f + 1.1f * r; out[1] = g; out[2] = b
        }
        val guarded = AutoGuardrails.apply(AutoGuardrail.ENDPOINT_V1, lut)
        assertContentEquals(lut.rgba, guarded.rgba)
    }

    @Test
    fun `no guardrail returns the fused LUT itself`() {
        val lut = SyntheticLuts.outOfRangeAuto()
        assertSame(lut, AutoGuardrails.apply(null, lut))
    }
}
