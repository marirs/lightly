import Foundation

/// A stage of the Develop pipeline, as surfaced to the user (spec §4.4).
///
/// Spec §4.4 is explicit that only *real* pipeline stages may be displayed and
/// that fake delays must never be added for theatre. A stage therefore exists
/// here only if some implementation genuinely performs it; the developing UI
/// reports completion as the work actually finishes, and reports nothing when
/// no work is being done.
enum DevelopStage: String, CaseIterable, Identifiable, Sendable {
    case whiteBalance
    case exposure
    case highlights
    case shadows
    case colour
    case detail
    case clarity

    var id: String { rawValue }

    /// Localisation key for the stage label.
    var localizationKey: String {
        "develop.stage.\(rawValue)"
    }
}
