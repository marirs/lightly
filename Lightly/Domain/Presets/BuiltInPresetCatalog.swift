import Foundation

/// The bundled starter set of first-party Looks.
///
/// These are hand-authored for the UI shell. The converted library described in
/// spec §6 — the founders' own Lightroom presets run through the XMP pipeline —
/// is Phase 3 work, and will replace this set rather than extend it.
///
/// Every recipe here uses only parameters `RecipeRenderer` genuinely applies, so
/// no Look advertises an effect that does not appear on screen.
struct BuiltInPresetCatalog: PresetProviding {

    /// Number of Looks surfaced in the first viewport.
    ///
    /// Spec §7 and §0.11 require 3–6, deliberately selective; the remainder of
    /// a category is reached by scrolling or by switching tabs.
    static let recommendedCount = 6

    private let all: [LightlyPreset]

    init() {
        self.all = Self.starterSet
    }

    func presets(in category: PresetCategory) -> [LightlyPreset] {
        guard category != .recommended else {
            return recommended(for: .unclassified)
        }
        return all.filter { $0.category == category }
    }

    func recommended(for scene: SceneKind) -> [LightlyPreset] {
        // PHASE 4 DEBT: `scene` is accepted but not yet used, because nothing
        // produces a value other than `.unclassified`. The parameter exists so
        // that wiring the classifier is a change here rather than a change to
        // every call site — and so the absence is visible rather than implied.
        let ordering = Self.generalStarterOrder
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

        return ordering
            .compactMap { byID[$0] }
            .prefix(Self.recommendedCount)
            .map { $0 }
    }

    func preset(withID id: String) -> LightlyPreset? {
        all.first { $0.id == id }
    }

    // MARK: - Content

    /// The order used for the general starter set.
    ///
    /// A fixed, curated order — not a ranking. Nothing about it is personal to
    /// the photograph or the user, and the interface must not suggest otherwise.
    private static let generalStarterOrder = [
        "natural.true-to-life",
        "film.golden-memory",
        "natural.soft-light",
        "film.kodak-gold",
        "cinematic.wide-screen",
        "moody.overcast"
    ]

    private static let starterSet: [LightlyPreset] = [
        LightlyPreset(
            id: "natural.true-to-life",
            name: "True to Life",
            category: .natural,
            isIncludedInFreeTier: true,
            recipe: DevelopRecipe(
                whiteBalance: .neutral,
                exposure: 0.05,
                highlights: -0.12,
                shadows: 0.10,
                contrast: 0.04,
                vibrance: 0.06,
                clarity: 0, dehaze: 0, sharpening: 0, noiseReduction: 0
            )
        ),
        LightlyPreset(
            id: "natural.soft-light",
            name: "Soft Light",
            category: .natural,
            isIncludedInFreeTier: true,
            recipe: DevelopRecipe(
                whiteBalance: .init(temperature: 60, tint: 0),
                exposure: 0.10,
                highlights: -0.22,
                shadows: 0.20,
                contrast: -0.04,
                vibrance: 0.04,
                clarity: 0, dehaze: 0, sharpening: 0, noiseReduction: 0
            )
        ),
        LightlyPreset(
            id: "film.golden-memory",
            name: "Golden Memory",
            category: .film,
            isIncludedInFreeTier: true,
            recipe: DevelopRecipe(
                whiteBalance: .init(temperature: 420, tint: -6),
                exposure: 0.12,
                highlights: -0.26,
                shadows: 0.18,
                contrast: 0.10,
                vibrance: 0.14,
                clarity: 0, dehaze: 0, sharpening: 0, noiseReduction: 0
            )
        ),
        LightlyPreset(
            id: "film.kodak-gold",
            name: "Gold 200",
            category: .film,
            isIncludedInFreeTier: false,
            recipe: DevelopRecipe(
                whiteBalance: .init(temperature: 320, tint: 4),
                exposure: 0.08,
                highlights: -0.18,
                shadows: 0.14,
                contrast: 0.14,
                vibrance: 0.18,
                clarity: 0, dehaze: 0, sharpening: 0, noiseReduction: 0
            )
        ),
        LightlyPreset(
            id: "cinematic.wide-screen",
            name: "Wide Screen",
            category: .cinematic,
            isIncludedInFreeTier: false,
            recipe: DevelopRecipe(
                whiteBalance: .init(temperature: -140, tint: 8),
                exposure: -0.04,
                highlights: -0.30,
                shadows: 0.26,
                contrast: 0.18,
                vibrance: -0.06,
                clarity: 0, dehaze: 0, sharpening: 0, noiseReduction: 0
            )
        ),
        LightlyPreset(
            id: "moody.overcast",
            name: "Overcast",
            category: .moody,
            isIncludedInFreeTier: false,
            recipe: DevelopRecipe(
                whiteBalance: .init(temperature: -200, tint: 2),
                exposure: -0.08,
                highlights: -0.14,
                shadows: -0.10,
                contrast: 0.16,
                vibrance: -0.14,
                clarity: 0, dehaze: 0, sharpening: 0, noiseReduction: 0
            )
        ),
        LightlyPreset(
            id: "cinematic.night-drive",
            name: "Night Drive",
            category: .cinematic,
            isIncludedInFreeTier: false,
            recipe: DevelopRecipe(
                whiteBalance: .init(temperature: -320, tint: 12),
                exposure: -0.12,
                highlights: -0.20,
                shadows: 0.30,
                contrast: 0.22,
                vibrance: -0.10,
                clarity: 0, dehaze: 0, sharpening: 0, noiseReduction: 0
            )
        ),
        LightlyPreset(
            id: "moody.quiet-room",
            name: "Quiet Room",
            category: .moody,
            isIncludedInFreeTier: false,
            recipe: DevelopRecipe(
                whiteBalance: .init(temperature: -80, tint: -4),
                exposure: -0.06,
                highlights: -0.10,
                shadows: 0.06,
                contrast: 0.08,
                vibrance: -0.20,
                clarity: 0, dehaze: 0, sharpening: 0, noiseReduction: 0
            )
        )
    ]
}
