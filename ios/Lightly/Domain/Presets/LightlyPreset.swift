import Foundation

/// A category a Look belongs to (spec §6.7).
enum PresetCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case recommended
    case favourites
    case aerial
    case landscape
    case film
    case cinematic
    case goldenHour = "golden_hour"
    case bw
    case urban
    case portrait
    case minimal
    case wedding

    var id: String { rawValue }

    var localizationKey: String { "looks.category.\(rawValue)" }

    /// SF Symbol icon for the category tab.
    var iconName: String {
        switch self {
        case .recommended: return "sparkles"
        case .favourites: return "star.fill"
        case .aerial: return "airplane"
        case .landscape: return "leaf.fill"
        case .film: return "film"
        case .cinematic: return "film.stack"
        case .goldenHour: return "sun.horizon.fill"
        case .bw: return "circle.lefthalf.filled"
        case .urban: return "building.2.fill"
        case .portrait: return "person.fill"
        case .minimal: return "square.grid.2x2"
        case .wedding: return "heart.fill"
        }
    }
}

/// A Look: a named, non-destructive recipe (spec §6.6).
///
/// All bundled presets are first-party (spec §0.2), so the identifier namespace
/// is ours and carries no third-party provenance.
struct LightlyPreset: Identifiable, Equatable, Codable, Sendable {
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

    /// Resolves a persisted Look identifier exactly, after explicit migrations.
    ///
    /// Never substitutes a different Look for a missing one.
    func resolvePreset(id: String) -> PresetLookupResult
}
