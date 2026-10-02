import CoreGraphics
import Foundation

/// Why Auto cannot be offered for a photo.
enum AutoUnavailableReason: Equatable, Sendable {
    /// No trained Auto model ships in this build (the retrained ia3dlut
    /// model is a later milestone). The UI must say Auto is unavailable,
    /// never fall back silently to an unrelated adjustment.
    case modelNotBundled
    /// The enhancer was configured inconsistently (e.g. basis LUTs of
    /// different sizes or a weight count that does not match).
    case invalidBasis
    /// The analysis proxy could not be made from the photo.
    case analysisFailed

    /// True for a failure that a retry may fix. "No model in this build" is not one: offering
    /// Retry there would be futile, so the editor goes straight to editing with a notice.
    var isRetryableFailure: Bool {
        switch self {
        case .modelNotBundled: return false
        case .invalidBasis, .analysisFailed: return true
        }
    }
}

/// What an enhancer produced for one photo.
enum AutoResult: Equatable, Sendable {
    case lut(LUT3D)
    case unavailable(AutoUnavailableReason)
}

/// Produces the photo-adaptive Auto LUT (spec §4.1 O1) from the analysis
/// proxy (≤1024 px, spec §4.6) — never from the display preview.
protocol AutoEnhancing: Sendable {
    func autoLUT(forAnalysisProxy proxy: CGImage) async -> AutoResult
}

/// The shipping enhancer until a model is bundled: explicitly unavailable.
struct ModelNotBundledAutoEnhancer: AutoEnhancing {
    func autoLUT(forAnalysisProxy proxy: CGImage) async -> AutoResult {
        .unavailable(.modelNotBundled)
    }
}

/// Fuses basis LUTs with per-photo weights: `L = Σ wᵢ·Bᵢ` (the ia3dlut
/// contract's fuse). The weights come from an injected predictor, which
/// is the Core ML model's job once one is bundled; tests inject a fixed or
/// proxy-derived predictor.
struct BasisAutoEnhancer: AutoEnhancing {
    let basis: [LUT3D]
    let predictWeights: @Sendable (CGImage) async -> [Float]

    func autoLUT(forAnalysisProxy proxy: CGImage) async -> AutoResult {
        let weights = await predictWeights(proxy)
        guard let first = basis.first, weights.count == basis.count,
              basis.allSatisfy({ $0.dimension == first.dimension }) else {
            return .unavailable(.invalidBasis)
        }
        var fused = [Float](repeating: 0, count: first.values.count)
        for (lut, weight) in zip(basis, weights) {
            for index in fused.indices { fused[index] += weight * lut.values[index] }
        }
        // Alpha is not a colour channel; keep it at 1 rather than Σw.
        for index in stride(from: 3, to: fused.count, by: 4) { fused[index] = 1 }
        guard let lut = try? LUT3D(dimension: first.dimension, values: fused) else {
            return .unavailable(.invalidBasis)
        }
        return .lut(lut)
    }
}

#if DEBUG
/// Delays another enhancer's result. DEBUG only, enabled by the launch
/// argument `--auto-delay-seconds <n>`.
///
/// Why: with no model bundled, Auto resolves instantly, so the "developing"
/// state cannot otherwise be observed in UI tests or demo recordings.
struct DelayedAutoEnhancer: AutoEnhancing {
    let wrapped: any AutoEnhancing
    let delay: Duration

    func autoLUT(forAnalysisProxy proxy: CGImage) async -> AutoResult {
        try? await Task.sleep(for: delay)
        return await wrapped.autoLUT(forAnalysisProxy: proxy)
    }
}
#endif
