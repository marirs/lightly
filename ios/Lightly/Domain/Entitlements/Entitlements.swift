import Foundation

/// A capability that may require payment (spec §26).
///
/// Gating is expressed as capabilities rather than screens because §0.3 forbids
/// scattering locks through the editor: the user enters any tool and previews
/// freely, and entitlement is checked only at the moment of apply or export.
enum PaidCapability: String, CaseIterable, Sendable {
    /// Applying a Look outside the free set.
    case fullLooksLibrary
    /// Black-and-white treatments.
    case blackAndWhite
    /// Portrait tooling.
    case portraitTools
    /// Repair tooling.
    case repairTools
    /// RAW development.
    case rawDevelopment
    /// Maximum-quality export.
    case maximumQualityExport
    /// Generative operations, billed per use from a credit balance.
    case generativeOperation
}

/// What the user currently owns.
enum EntitlementLevel: Equatable, Sendable {
    /// Develop, Compare, Crop, basic export, and the free Looks set.
    case free
    /// Lightly Pro, by subscription or lifetime purchase.
    case pro
}

/// Resolves whether a paid capability may proceed.
///
/// Phase 1 ships the boundary and a permissive-free implementation; StoreKit 2
/// wiring is Phase 6. Defining the protocol now keeps call sites honest — a
/// feature added later cannot quietly skip the check.
protocol EntitlementResolving: Sendable {
    /// The user's current level.
    var level: EntitlementLevel { get }
    /// Remaining generative credits.
    var generativeCredits: Int { get }

    /// Whether the capability may be *applied or exported* right now.
    ///
    /// Callers must not use this to hide or disable UI. Preview is always free;
    /// this gate belongs at the apply/export boundary only (spec §0.3).
    func canApply(_ capability: PaidCapability) -> Bool
}

/// Phase 1 stand-in: everyone is on the free tier with no credits.
///
/// This makes the free-tier experience the default path during UI development,
/// which is the correct bias — §26.2 requires the free tier to feel complete
/// rather than crippled, and that is easiest to verify if it is what we see.
struct FreeTierEntitlementResolver: EntitlementResolving {
    let level: EntitlementLevel = .free
    let generativeCredits: Int = 0

    func canApply(_ capability: PaidCapability) -> Bool {
        switch capability {
        case .fullLooksLibrary, .blackAndWhite, .portraitTools,
             .repairTools, .rawDevelopment, .maximumQualityExport,
             .generativeOperation:
            return false
        }
    }
}
