import Foundation

/// What kind of engine produced a development.
///
/// Spec §24.8 forbids presenting placeholder image processing as finished
/// functionality. Making the engine declare its own maturity — rather than
/// leaving it to a UI flag someone can forget — means an unfinished engine
/// cannot ship silently looking production-ready.
enum DevelopImplementationKind: Sendable, Equatable {

    /// The real engine: scene and quality analysis choose the recipe (§5, §17).
    case production

    /// A debug engine that performs *genuine* rendering but does **not**
    /// analyse the photograph. It applies a fixed recipe, so the pixels really
    /// change, while the intelligence that chooses those numbers does not yet
    /// exist.
    ///
    /// The distinction matters and must be stated plainly to anyone running the
    /// app: the *rendering* is real, the *judgement* is not.
    case debugFixedRecipe

    /// Whether the UI must display a visible non-production notice.
    ///
    /// Deliberately *not* compiled out in release. Suppressing the disclosure
    /// there would let a placeholder ship silently — the exact failure this
    /// type exists to prevent. Release safety is instead enforced at the
    /// composition root, which refuses to compile while the engine is a
    /// placeholder (see `DependencyContainer.live()`).
    var requiresDebugDisclosure: Bool {
        self != .production
    }
}

/// Produces a development recipe for a photograph and reports genuine progress.
///
/// Progress is reported per stage as that stage's work actually completes.
/// Implementations must not emit stages they did not perform, and must not
/// insert delays to make the process feel substantial (spec §4.4).
protocol PhotoDeveloping: Sendable {

    /// The maturity of this implementation. Drives the debug disclosure.
    var implementationKind: DevelopImplementationKind { get }

    /// The stages this implementation genuinely performs.
    ///
    /// The developing UI renders exactly this list — never the full enum — so a
    /// partial engine cannot imply work it does not do.
    var performedStages: [DevelopStage] { get }

    /// Analyses the photograph and produces a recipe.
    ///
    /// - Parameters:
    ///   - photo: The immutable original. Implementations must not mutate it.
    ///   - onStageCompleted: Invoked as each stage in `performedStages`
    ///     finishes. Called on an arbitrary executor.
    /// - Returns: The recipe to render.
    /// - Throws: `LightlyError.developFailed` when the pipeline cannot complete.
    func develop(
        _ photo: SelectedPhoto,
        onStageCompleted: @escaping @Sendable (DevelopStage) -> Void
    ) async throws -> DevelopRecipe
}
