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

/// A Look as the M2 pipeline applies it: a LUT, compiled offline (spec §4.5).
struct LUTLook: Identifiable, Equatable, Sendable {
    let id: String
    let version: Int
    let name: String
    let lut: LUT3D
}

/// One category of the stepped Look slider (spec D5/D6).
///
/// Stop 0 of every category is the implicit Auto stop (no Look); `lookIDs`
/// are stops 1…n in slider order. Parity with Android `LookBook`.
struct LUTLookCategory: Identifiable, Equatable, Sendable {
    /// Stable identifier, also used for the localised display name
    /// (`editor.lookCategory.<id>`). Same IDs as Android.
    let id: String
    let lookIDs: [String]
}

/// The Looks available to the LUT editor. Lookup is exact (spec §4.5): an
/// unknown ID is unavailable, never substituted.
struct LUTLookBook: Sendable {
    let looks: [LUTLook]
    /// Slider categories, in display order. Empty when only lookup matters
    /// (e.g. session tests).
    let categories: [LUTLookCategory]
    /// True for placeholder Looks that are neither curated nor validated;
    /// the editor must say so on screen rather than present them as the
    /// product's Looks.
    let isProvisional: Bool

    init(looks: [LUTLook], categories: [LUTLookCategory] = [], isProvisional: Bool = false) {
        self.looks = looks
        self.categories = categories
        self.isProvisional = isProvisional
    }

    /// No converted Look LUTs ship yet (desktop conversion and Lightroom
    /// validation are M4); the release book is empty until then.
    static let bundled = LUTLookBook(looks: [])

    func look(id: String) -> LUTLook? {
        looks.first { $0.id == id }
    }

    /// Stops 1…n of a category, in slider order. Unknown IDs are skipped
    /// (exact lookup; never substituted).
    func stops(inCategory categoryID: String) -> [LUTLook] {
        guard let category = categories.first(where: { $0.id == categoryID }) else { return [] }
        return category.lookIDs.compactMap(look(id:))
    }

    /// Slider position of `lookID` in a category: 0 (Auto) when there is
    /// no Look or it belongs to another category (Android `stopIndexOf`).
    func stopIndex(of lookID: String?, inCategory categoryID: String) -> Int {
        guard let lookID, let index = stops(inCategory: categoryID).firstIndex(where: { $0.id == lookID }) else {
            return 0
        }
        return index + 1
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
