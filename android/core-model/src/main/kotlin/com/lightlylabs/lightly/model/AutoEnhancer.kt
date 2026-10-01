package com.lightlylabs.lightly.model

import com.lightlylabs.lightly.render.image.Rgba8Image
import com.lightlylabs.lightly.render.lut.Lut3D
import com.lightlylabs.lightly.session.AutoGuardrail
import com.lightlylabs.lightly.session.AutoResult
import com.lightlylabs.lightly.session.SourceFingerprint

/**
 * The classifier: canonical input `[1,3,256,256]` → raw linear basis weights.
 *
 * PENDING (physical device): the production implementation is an ONNX Runtime Android session
 * (CPU/XNNPACK, fp32). It is intentionally NOT implemented in M2: ORT crashed with SIGILL on the
 * x86_64 emulator in M1, and no physical phone has run it yet, so nothing here claims that
 * inference works on Android. Tests use a fake.
 */
interface AutoModel {
    val modelId: String

    /** Changes whenever weights, basis LUTs or preprocessing change (spec §4.6). */
    val modelVersion: String

    /** @param input float32 NCHW `[1,3,256,256]` from [CanonicalAnalysisInput]. Returns `weights[3]`. */
    fun predictWeights(input: FloatArray): FloatArray
}

/** An Auto result plus the LUT it renders with (fused, guardrailed, not yet strength-blended). */
class AutoDevelopment(val result: AutoResult, val lut: Lut3D)

/**
 * Develop step (spec §2.3): canonical input → model → fuse → guardrail.
 *
 * The model runs at most once per (Original fingerprint, model version) (spec §5.2); the result
 * is memoised for the lifetime of this object. Not thread-safe: in the app it is called from the
 * session's single develop coroutine.
 *
 * @param initialStrength Auto strength for a fresh result. Spec U2 recommends 0.75 pending the
 *   retrained model; it is a parameter so that decision is made by the caller, not buried here.
 */
class AutoEnhancer(
    private val model: AutoModel,
    private val basis: BasisLuts,
    private val guardrail: AutoGuardrail?,
    private val initialStrength: Float,
) {
    private data class MemoKey(val fingerprint: SourceFingerprint, val modelVersion: String)

    private val memo = HashMap<MemoKey, AutoDevelopment>()

    fun develop(fingerprint: SourceFingerprint, analysisSource: Rgba8Image): AutoDevelopment {
        val key = MemoKey(fingerprint, model.modelVersion)
        memo[key]?.let { return it }

        val originalLongEdge = maxOf(fingerprint.pixelWidth, fingerprint.pixelHeight)
        val input = CanonicalAnalysisInput.prepare(analysisSource, originalLongEdge)
        val weights = model.predictWeights(input)
        require(weights.size == AutoResult.WEIGHT_COUNT && weights.all { it.isFinite() }) {
            "Model returned invalid weights ${weights.toList()}"
        }
        val result = AutoResult(
            modelId = model.modelId,
            modelVersion = model.modelVersion,
            weights = weights.toList(),
            guardrail = guardrail,
            strength = initialStrength,
        )
        val development = AutoDevelopment(result, lutFor(result))
        memo[key] = development
        return development
    }

    /**
     * Rebuilds the LUT from a stored AutoResult without running the model, so a restored session
     * re-renders with its saved weights (spec §4.6) even if a newer model is installed.
     */
    fun lutFor(result: AutoResult): Lut3D =
        AutoGuardrails.apply(result.guardrail, basis.fuse(result.weights.toFloatArray()))
}
