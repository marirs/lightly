import CoreGraphics
import Foundation
import Observation

/// Which stage of the editing flow the user is in (spec §4.3–§4.5).
///
/// The three cases map exactly to the three screens the spec defines, so the
/// rules attached to each — what is visible, what is enabled — are decided in
/// one place rather than scattered across view conditionals.
enum EditPhase: Equatable, Sendable {
    /// A photograph is loaded and undeveloped. Crop and Develop only.
    case readyToDevelop
    /// Development is running. The photo stays visible behind an overlay.
    case developing
    /// A developed version exists. Compare, Share, Crop, contextual bar.
    case developed
}

/// Drives the editor screen.
///
/// Owns the immutable original, the edit history, and the currently rendered
/// image. Views read published state and call intents; they never compute
/// availability rules themselves.
@MainActor
@Observable
final class EditorViewModel {

    // MARK: - Immutable source

    /// The original photograph. Never mutated, never overwritten (spec §2.6).
    let original: SelectedPhoto

    // MARK: - State

    private(set) var phase: EditPhase = .readyToDevelop

    /// The non-destructive edit stack (spec §27).
    private(set) var history = EditHistory()

    /// The image currently displayed, after applying the history.
    private(set) var renderedImage: CGImage

    /// Stages whose work has genuinely completed during the current develop.
    private(set) var completedStages: Set<DevelopStage> = []

    /// True while the user holds Compare, showing the original.
    private(set) var isShowingOriginal = false

    /// The active recoverable failure for this editing session.
    private(set) var activeError: LightlyError?

    // MARK: - Dependencies

    private let developer: any PhotoDeveloping
    private let renderer: RecipeRenderer

    /// The in-flight development, retained so it can be cancelled.
    ///
    /// Readable internally so tests can await completion deterministically
    /// rather than polling for a state change. The app itself only ever
    /// cancels it.
    private(set) var developTask: Task<Void, Never>?

    init(
        original: SelectedPhoto,
        developer: any PhotoDeveloping,
        renderer: RecipeRenderer = RecipeRenderer()
    ) {
        self.original = original
        self.renderedImage = original.image
        self.developer = developer
        self.renderer = renderer
    }

    // MARK: - Derived availability rules

    /// Whether Compare may be offered.
    ///
    /// Spec §0.11 and §4.3: Compare stays unavailable until a developed version
    /// exists. Derived from history rather than from `phase` so that it remains
    /// correct after an undo returns the user to an undeveloped state.
    var isCompareAvailable: Bool {
        history.hasDevelopedVersion
    }

    /// Whether Share may be offered. Same gate as Compare — there is nothing
    /// worth sharing until the photograph has been developed.
    var isShareAvailable: Bool {
        history.hasDevelopedVersion
    }

    /// Whether the app must display a non-production processing notice.
    ///
    /// Read from the engine itself (spec §24.8), so a placeholder engine cannot
    /// be presented as finished by forgetting a flag.
    var requiresDebugDisclosure: Bool {
        developer.implementationKind.requiresDebugDisclosure
    }

    /// The stages the current engine genuinely performs.
    var displayedStages: [DevelopStage] {
        developer.performedStages
    }

    /// The image to display right now, accounting for Compare.
    var displayedImage: CGImage {
        isShowingOriginal ? original.image : renderedImage
    }

    /// Whether Undo is available (spec §27).
    var canUndo: Bool {
        history.canUndo
    }

    // MARK: - Intents

    /// Runs Develop.
    func develop() {
        guard phase == .readyToDevelop else { return }

        phase = .developing
        completedStages = []

        developTask = Task { [weak self] in
            await self?.performDevelop()
        }
    }

    /// Performs development and renders the result.
    ///
    /// Any failure returns the user to `readyToDevelop` with the original
    /// intact — spec §28 requires that a failed Develop leave the original
    /// unchanged and never strand the UI mid-state.
    private func performDevelop() async {
        do {
            let recipe = try await developer.develop(original) { [weak self] stage in
                Task { @MainActor in
                    self?.completedStages.insert(stage)
                }
            }

            try Task.checkCancellation()

            let rendered = try renderer.render(original.image, with: recipe)

            renderedImage = rendered
            history.record(.develop(recipe))
            phase = .developed
        } catch is CancellationError {
            // Cancellation unwinds with no side effects and no error (spec §28).
            phase = .readyToDevelop
            completedStages = []
        } catch let error as LightlyError {
            fail(with: error)
        } catch {
            fail(with: .developFailed)
        }
    }

    /// Returns to the undeveloped state and surfaces a defined failure.
    private func fail(with error: LightlyError) {
        phase = .readyToDevelop
        completedStages = []
        renderedImage = original.image
        guard error.isFault else { return }
        activeError = error
    }

    /// Cancels an in-flight development.
    ///
    /// The task handle is deliberately retained after cancelling. Clearing it
    /// here would discard the only way to observe the cancellation finishing,
    /// leaving the phase briefly stuck at `.developing` with nothing to await.
    /// The handle is replaced on the next `develop()`.
    func cancelDevelop() {
        developTask?.cancel()
    }

    /// Begins showing the original (press and hold Compare, spec §4.5).
    func beginCompare() {
        guard isCompareAvailable else { return }
        isShowingOriginal = true
    }

    /// Stops showing the original.
    func endCompare() {
        isShowingOriginal = false
    }

    /// Toggles the original/developed view.
    ///
    /// The accessibility alternative to press-and-hold, which VoiceOver and
    /// Switch Control users cannot perform reliably (spec §4.5).
    func toggleCompare() {
        guard isCompareAvailable else { return }
        isShowingOriginal.toggle()
    }

    /// Applies a Look at an intensity, recording both as reversible steps.
    ///
    /// Entitlement has already been checked at the Looks screen's apply
    /// checkpoint; this method commits the result.
    func applyLook(_ preset: LightlyPreset, intensity: Double) {
        history.record(.look(id: preset.id, recipe: preset.recipe))
        if intensity != 1 {
            history.recordIntensity(intensity)
        }
        rerenderFromHistory()
    }

    /// Renders a transient preview without touching history.
    ///
    /// Previewing must be free in both senses: no payment, and no permanent
    /// consequence. Nothing is recorded until the user applies, so abandoning
    /// the Looks screen leaves the edit stack exactly as it was.
    func previewLook(_ preset: LightlyPreset?, intensity: Double) {
        guard let preset else {
            rerenderFromHistory()
            return
        }

        let composed = history.composedRecipe
            .combined(with: preset.recipe.scaled(by: intensity))

        do {
            renderedImage = try renderer.render(original.image, with: composed)
        } catch {
            // A failed preview leaves the committed image on screen rather than
            // blanking it; the user has lost nothing.
            renderedImage = (try? renderer.render(
                original.image,
                with: history.composedRecipe
            )) ?? original.image
        }
    }

    /// Reverses the most recent operation (spec §27).
    ///
    /// Re-renders from the original rather than inverting the last filter,
    /// because only re-rendering guarantees the result is identical to never
    /// having applied the step.
    func undo() {
        guard history.canUndo else { return }
        history.undo()
        rerenderFromHistory()
    }

    /// Discards every operation and returns to the original (spec §12, Reset).
    func reset() {
        history.reset()
        rerenderFromHistory()
    }

    /// Rebuilds the displayed image from the current history.
    private func rerenderFromHistory() {
        // Composed rather than the Develop recipe alone, so an applied Look and
        // its intensity survive undo of a later step.
        let recipe = history.composedRecipe

        do {
            renderedImage = try renderer.render(original.image, with: recipe)
        } catch {
            // Re-rendering the original can only fail for environmental
            // reasons; fall back to the untouched source so the user is never
            // left looking at a stale result.
            renderedImage = original.image
            activeError = .developFailed
        }

        phase = history.hasDevelopedVersion ? .developed : .readyToDevelop
        if !isCompareAvailable {
            isShowingOriginal = false
        }
    }

    /// Dismisses the active failure.
    func dismissError() {
        activeError = nil
    }
}
