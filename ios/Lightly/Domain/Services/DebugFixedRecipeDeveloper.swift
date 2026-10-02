import Foundation

/// A stand-in Develop engine used until the real one exists.
///
/// **This is not the Develop engine.** It performs genuine rendering through
/// Core Image, but it does not look at the photograph: it returns the same
/// conservative recipe every time, regardless of scene, exposure, or subject.
///
/// The distinction is deliberate and is surfaced to the user through
/// `DevelopImplementationKind.debugFixedRecipe`:
///
/// - **Real:** the pixels genuinely change, through the same renderer Phase 2
///   will keep. Compare therefore shows a true before/after.
/// - **Not real:** every analysis listed in spec §5 — scene type, faces, white
///   balance estimation, dynamic range, noise — is absent.
///
/// Two rules from spec §4.4 shape the implementation:
///
/// 1. **No fabricated delay.** This engine is fast because it does little. It
///    does not sleep to feel substantial, so the developing state passes almost
///    instantly. That flicker is honest: it is what "no analysis" looks like.
/// 2. **No fabricated stages.** `performedStages` lists only the stages this
///    engine actually applies. It omits Detail and Clarity because it does not
///    perform them, even though the spec's full list includes them.
struct DebugFixedRecipeDeveloper: PhotoDeveloping {

    let implementationKind: DevelopImplementationKind = .debugFixedRecipe

    /// Only the stages this engine genuinely applies.
    ///
    /// Detail and Clarity are absent because texture and local-contrast work do
    /// not exist yet. Listing them would be exactly the theatre §4.4 forbids.
    let performedStages: [DevelopStage] = [
        .whiteBalance,
        .exposure,
        .highlights,
        .shadows,
        .colour
    ]

    /// The fixed recipe.
    ///
    /// Values are modest, matching the spec's "subtle by default" principle
    /// (§2.7), and are close to the worked example in §5 — but they are a
    /// constant, not a measurement.
    static let fixedRecipe = DevelopRecipe(
        whiteBalance: .init(temperature: 180, tint: -3),
        exposure: 0.18,
        highlights: -0.31,
        shadows: 0.22,
        contrast: 0.08,
        vibrance: 0.12,
        clarity: 0,
        dehaze: 0,
        sharpening: 0,
        noiseReduction: 0
    )

    func develop(
        _ photo: SelectedPhoto,
        onStageCompleted: @escaping @Sendable (DevelopStage) -> Void
    ) async throws -> DevelopRecipe {
        // Stages are reported as the recipe is assembled. There is no work to
        // pace, so they complete immediately and together — which is precisely
        // the point. When the real engine lands, each callback will fire after
        // the corresponding analysis genuinely finishes.
        for stage in performedStages {
            try Task.checkCancellation()
            onStageCompleted(stage)
        }

        return Self.fixedRecipe
    }
}
