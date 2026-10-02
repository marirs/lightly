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

/**
 * What the O1 stage renders for a stored AutoResult. Either the LUT fused from the basis of the
 * exact version that produced the weights, or an explicit "Auto unavailable" — never a LUT built
 * from some other installed version (Codex M2 finding 4).
 */
sealed interface AutoLutResolution {
    /** Fused, guardrailed, not yet strength-blended. */
    class Ready(val result: AutoResult, val lut: Lut3D) : AutoLutResolution

    data class AutoUnavailable(
        val modelId: String,
        val modelVersion: String,
        val reason: BasisUnavailableReason,
    ) : AutoLutResolution
}

/** Resolves a stored AutoResult to its O1 LUT. A fun interface so the ViewModel can be tested with a fake. */
fun interface AutoLutResolver {
    fun resolve(result: AutoResult): AutoLutResolution
}

/** The production resolver: versioned, hash-verified basis from [BasisRegistry]. */
class RegistryAutoLutResolver(private val registry: BasisRegistry) : AutoLutResolver {
    override fun resolve(result: AutoResult): AutoLutResolution =
        when (val resolution = registry.resolve(ModelKey(result.modelId, result.modelVersion))) {
            is BasisResolution.Available ->
                AutoLutResolution.Ready(result, AutoGuardrails.apply(result.guardrail, resolution.basis.fuse(result.weights.toFloatArray())))
            is BasisResolution.Unavailable ->
                AutoLutResolution.AutoUnavailable(result.modelId, result.modelVersion, resolution.reason)
        }
}

/** An Auto result plus the LUT it renders with (fused, guardrailed, not yet strength-blended). */
class AutoDevelopment(val result: AutoResult, val lut: Lut3D)

sealed interface DevelopOutcome {
    class Developed(val development: AutoDevelopment) : DevelopOutcome

    /**
     * The model ran, but the basis for its own version is missing or fails verification. [result]
     * carries the weights so the session can still start with Auto shown as unavailable (Auto off).
     */
    data class Unavailable(val result: AutoResult, val unavailable: AutoLutResolution.AutoUnavailable) : DevelopOutcome
}

/**
 * Develop step (spec §2.3): canonical input → model → fuse → guardrail.
 *
 * The model runs at most once per (Original fingerprint, model version) (spec §5.2); successful
 * results are memoised for the lifetime of this object. Not thread-safe: in the app it is called
 * from the session's single develop coroutine.
 *
 * @param initialStrength Auto strength for a fresh result. Spec U2 recommends 0.75 pending the
 *   retrained model; it is a parameter so that decision is made by the caller, not buried here.
 */
class AutoEnhancer(
    private val model: AutoModel,
    private val resolver: AutoLutResolver,
    private val guardrail: AutoGuardrail?,
    private val initialStrength: Float,
) {
    private data class MemoKey(val fingerprint: SourceFingerprint, val modelVersion: String)

    private val memo = HashMap<MemoKey, AutoDevelopment>()

    fun develop(fingerprint: SourceFingerprint, analysisSource: Rgba8Image): DevelopOutcome {
        val key = MemoKey(fingerprint, model.modelVersion)
        memo[key]?.let { return DevelopOutcome.Developed(it) }

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
        return when (val resolution = resolver.resolve(result)) {
            is AutoLutResolution.Ready -> {
                val development = AutoDevelopment(result, resolution.lut)
                memo[key] = development
                DevelopOutcome.Developed(development)
            }
            is AutoLutResolution.AutoUnavailable -> DevelopOutcome.Unavailable(result, resolution)
        }
    }
}
