package com.lightlylabs.lightly.model

import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.lut.Lut3D
import com.lightlylabs.lightly.render.testing.SyntheticLuts
import com.lightlylabs.lightly.session.AutoGuardrail
import com.lightlylabs.lightly.session.SourceFingerprint
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertSame

/** Develop orchestration with a fake model; real ORT inference is PENDING on device. */
class AutoEnhancerTest {

    private class FakeAutoModel(
        override val modelVersion: String = "fake-1",
        private val weights: FloatArray = floatArrayOf(0.5f, 0.25f, 0.25f),
    ) : AutoModel {
        override val modelId: String = "ia3dlut"
        val inputs = mutableListOf<FloatArray>()
        override fun predictWeights(input: FloatArray): FloatArray {
            inputs += input
            return weights
        }
    }

    private val basis = BasisLuts(listOf(SyntheticLuts.outOfRangeAuto(), Lut3D.identity(), SyntheticLuts.strongLook()))
    private val image = Rgba8Image(1024, 768, ByteArray(1024 * 768 * 4) { (it % 251).toByte() })
    private val fingerprintA = SourceFingerprint("aa".repeat(32), 1000, 1024, 768)
    private val fingerprintB = SourceFingerprint("bb".repeat(32), 1000, 1024, 768)

    private fun enhancer(model: AutoModel) =
        AutoEnhancer(model, basis, guardrail = AutoGuardrail.ENDPOINT_V1, initialStrength = 0.75f)

    @Test
    fun `develop feeds the canonical 256 input to the model and records the result`() {
        val model = FakeAutoModel()
        val development = enhancer(model).develop(fingerprintA, image)

        assertEquals(3 * 256 * 256, model.inputs.single().size)
        assertContentEquals(CanonicalAnalysisInput.prepare(image, 1024), model.inputs.single())
        with(development.result) {
            assertEquals("ia3dlut", modelId)
            assertEquals("fake-1", modelVersion)
            assertEquals(listOf(0.5f, 0.25f, 0.25f), weights)
            assertEquals(AutoGuardrail.ENDPOINT_V1, guardrail)
            assertEquals(0.75f, strength)
        }
        val expectedLut = AutoGuardrails.apply(AutoGuardrail.ENDPOINT_V1, basis.fuse(floatArrayOf(0.5f, 0.25f, 0.25f)))
        assertContentEquals(expectedLut.rgba, development.lut.rgba)
    }

    @Test
    fun `the model runs at most once per Original and model version`() {
        val model = FakeAutoModel()
        val enhancer = enhancer(model)

        val first = enhancer.develop(fingerprintA, image)
        val again = enhancer.develop(fingerprintA, image)
        enhancer.develop(fingerprintB, image)

        assertSame(first, again)
        assertEquals(2, model.inputs.size, "A twice + B once = two model runs")
    }

    @Test
    fun `a stored AutoResult re-renders from its saved weights without running the model`() {
        val model = FakeAutoModel()
        val stored = enhancer(FakeAutoModel(weights = floatArrayOf(1f, 0f, 0f))).develop(fingerprintA, image).result

        val lut = enhancer(model).lutFor(stored)

        assertEquals(0, model.inputs.size)
        assertContentEquals(AutoGuardrails.apply(AutoGuardrail.ENDPOINT_V1, basis.fuse(floatArrayOf(1f, 0f, 0f))).rgba, lut.rgba)
    }

    @Test
    fun `invalid model output is rejected`() {
        val model = FakeAutoModel(weights = floatArrayOf(Float.NaN, 0f, 0f))
        assertFailsWith<IllegalArgumentException> { enhancer(model).develop(fingerprintA, image) }
    }
}
