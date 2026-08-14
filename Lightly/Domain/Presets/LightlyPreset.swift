import Foundation

/// A category a Look belongs to (spec §6.7).
///
/// The full list in the spec is longer; these are the categories with content
/// in the starter set. Adding a case without presets would show an empty tab.
enum PresetCategory: String, CaseIterable, Identifiable, Sendable {
    case recommended
    case film
    case natural
    case cinematic
    case moody

    var id: String { rawValue }

    var localizationKey: String { "looks.category.\(rawValue)" }
}

/// A Look: a named, non-destructive recipe (spec §6.6).
///
/// All bundled presets are first-party (spec §0.2), so the identifier namespace
/// is ours and carries no third-party provenance.
struct LightlyPreset: Identifiable, Equatable, Sendable {
    /// Stable identifier, e.g. `film.golden-memory`. Persisted in edit history,
    /// so it must not change once shipped.
    let id: String
    /// Display name. Not localised: Look names are brand content, and
    /// translating "Kodak Gold 200" would be wrong.
    let name: String
    let category: PresetCategory
    /// Whether this Look is available on the free tier (spec §26.1: 8–12 free).
    let isIncludedInFreeTier: Bool
    /// The adjustment this Look applies.
    ///
    /// PHASE 3 DEBT: tone curves, HSL, colour grading, and grain from the spec
    /// §6.6 schema are not yet modelled. The starter set uses only the
    /// parameters `RecipeRenderer` can genuinely render, so no Look claims an
    /// effect the engine cannot produce.
    let recipe: DevelopRecipe
}

/// Supplies Looks to the interface.
protocol PresetProviding: Sendable {
    /// Every Look in a category.
    func presets(in category: PresetCategory) -> [LightlyPreset]

    /// The Looks to surface first.
    ///
    /// - Parameter scene: The classified scene. Spec §7 requires this to be
    ///   scene-aware; until classification exists (Phase 4) callers pass
    ///   `.unclassified` and receive a general starter set, which the UI must
    ///   describe honestly rather than as a personalised recommendation.
    func recommended(for scene: SceneKind) -> [LightlyPreset]

    /// Looks up a Look by identifier.
    func preset(withID id: String) -> LightlyPreset?
}
