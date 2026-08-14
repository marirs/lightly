import Foundation

/// A tool that can appear in the developed screen's bottom action bar.
enum ContextualTool: String, Identifiable, Sendable {
    case looks
    case magic
    case repairTools
    case blackAndWhite
    case portrait
    case perspective
    case lowLight
    case tone
    case grain
    case more

    var id: String { rawValue }

    var localizationKey: String { "tool.\(rawValue)" }

    /// SF Symbol used in the action bar.
    var symbolName: String {
        switch self {
        case .looks: "sparkles.rectangle.stack"
        case .magic: "wand.and.sparkles"
        case .repairTools: "bandage"
        case .blackAndWhite: "circle.lefthalf.filled"
        case .portrait: "person.crop.circle"
        case .perspective: "skew"
        case .lowLight: "moon.stars"
        case .tone: "circle.righthalf.filled"
        case .grain: "circle.grid.3x3"
        case .more: "ellipsis"
        }
    }
}

/// The kind of photograph, which determines the contextual toolbar (spec §4.5).
///
/// Scene classification is Phase 4 work (§23). Until it exists, every
/// photograph resolves to `.unclassified`, which yields the general-purpose
/// bar. The enum is modelled now because §2.3 — contextual tools only — is a
/// core product principle, and the toolbar must be built against it from the
/// start rather than retrofitted.
enum SceneKind: String, Sendable, CaseIterable {
    case unclassified
    case landscape
    case portrait
    case architecture
    case night
    case monochrome
}

extension SceneKind {

    /// The action bar for this scene, exactly as specified in §4.5.
    ///
    /// Portrait tools appear only for `.portrait`, satisfying the acceptance
    /// criterion that they stay hidden when no portrait is detected.
    var toolbar: [ContextualTool] {
        switch self {
        case .landscape:
            [.looks, .magic, .repairTools, .blackAndWhite, .more]
        case .portrait:
            [.portrait, .looks, .magic, .repairTools, .more]
        case .architecture:
            [.perspective, .looks, .repairTools, .magic, .more]
        case .night:
            [.lowLight, .repairTools, .looks, .magic, .more]
        case .monochrome:
            [.tone, .grain, .repairTools, .more]
        case .unclassified:
            // The general bar, used until scene classification lands. It
            // deliberately excludes Portrait: showing portrait tools without
            // face detection would violate §2.3 and the V1 acceptance criteria.
            [.looks, .magic, .repairTools, .blackAndWhite, .more]
        }
    }
}
