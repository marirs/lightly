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
    private let renderScheduler: PreviewRenderScheduler

    /// The in-flight development, retained so it can be cancelled.
    ///
    /// Readable internally so tests can await completion deterministically
    /// rather than polling for a state change. The app itself only ever
    /// cancels it.
    private(set) var developTask: Task<Void, Never>?

    // MARK: - Render publication

    /// Identifies one render request. A result is shown only while its
    /// ticket is still the newest one issued for this photo and the editor
    /// has not closed — the scheduler bounds work, this decides visibility.
    private struct RenderTicket: Equatable {
        let revision: UInt64
        let photoID: UUID
    }

    /// What to show when a render fails.
    private enum RenderFailurePolicy {
        /// A transient preview failed: fall back to the committed edit.
        case restoreCommittedEdit
        /// The committed edit failed: show the original and report it.
        case showOriginalAndReport
    }

    private var latestRenderRevision: UInt64 = 0
    private var isClosed = false
    private var outstandingRenders: [UInt64: Task<Void, Never>] = [:]
    private var schedulerControl: [Task<Void, Never>] = []

    /// Renders that reached the screen, and the revision of the last one.
    /// Diagnostic counters: tests assert that stale work never publishes.
    private(set) var publishedRenderCount = 0
    private(set) var lastPublishedRenderRevision: UInt64 = 0

    init(
        original: SelectedPhoto,
        developer: any PhotoDeveloping,
        previewRenderer: any PreviewRendering = PreviewRenderer()
    ) {
        self.original = original
        self.renderedImage = original.image
        self.developer = developer
        self.renderScheduler = PreviewRenderScheduler(
            renderer: previewRenderer,
            source: original.image,
            identity: original.fingerprint
        )
    }

    // MARK: - Derived availability rules

    /// The full recipe as it stands after all edits, suitable for export.
    ///
    /// Exposed so the export sheet can hand this to `ExportViewModel`, which
    /// renders at full resolution from the original using this recipe.
    var composedRecipe: DevelopRecipe {
        history.composedRecipe
    }

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

            let ticket = issueRenderTicket()
            let rendered = try await renderDevelopResult(recipe, ticket: ticket)

            publish(rendered, for: ticket)
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

    /// Renders the Develop result through the scheduler.
    ///
    /// A superseded, cancelled or no-longer-current render unwinds as
    /// cancellation: something newer (Reset, close) has already decided what
    /// the screen shows, and recording this Develop would overwrite it.
    private func renderDevelopResult(_ recipe: DevelopRecipe, ticket: RenderTicket) async throws -> CGImage {
        let outcome = await renderScheduler.render(recipe, revision: ticket.revision)
        guard isCurrent(ticket) else { throw CancellationError() }
        switch outcome {
        case .rendered(let image):
            return image
        case .superseded, .cancelled:
            throw CancellationError()
        case .failed(let error):
            throw error
        }
    }

    /// Returns to the undeveloped state and surfaces a defined failure.
    private func fail(with error: LightlyError) {
        guard !isClosed else { return }
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

        // v3 differs: v1 started one untracked Task per call, so a slider drag
        // queued a render per tick and a late one could overwrite Apply.
        scheduleRender(composed, ticket: issueRenderTicket(), onFailure: .restoreCommittedEdit)
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
        // A Develop still running would otherwise record itself on top of
        // the reset history when it finishes.
        developTask?.cancel()
        history.reset()
        rerenderFromHistory()
    }

    /// Ends this editing session: nothing rendered afterwards reaches the
    /// screen, and queued work is cancelled. Called when the photo is closed
    /// or replaced.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        developTask?.cancel()
        sendToScheduler { await $0.close() }
    }

    /// Rebuilds the displayed image from the current history.
    private func rerenderFromHistory() {
        // Composed rather than the Develop recipe alone, so an applied Look and
        // its intensity survive undo of a later step.
        let recipe = history.composedRecipe

        // Phase and Compare state update synchronously so the UI reflects the
        // change immediately; the pixel render follows asynchronously.
        phase = history.hasDevelopedVersion ? .developed : .readyToDevelop
        if !isCompareAvailable {
            isShowingOriginal = false
        }

        let ticket = issueRenderTicket()
        guard !recipe.isIdentity else {
            // Shown synchronously, so anything still rendering is now stale
            // and must be stopped rather than merely ignored.
            publish(original.image, for: ticket)
            sendToScheduler { await $0.cancel(through: ticket.revision) }
            return
        }

        scheduleRender(recipe, ticket: ticket, onFailure: .showOriginalAndReport)
    }

    // MARK: - Render scheduling

    private func issueRenderTicket() -> RenderTicket {
        latestRenderRevision += 1
        return RenderTicket(revision: latestRenderRevision, photoID: original.id)
    }

    private func isCurrent(_ ticket: RenderTicket) -> Bool {
        !isClosed && ticket.revision == latestRenderRevision && ticket.photoID == original.id
    }

    private func publish(_ image: CGImage, for ticket: RenderTicket) {
        guard isCurrent(ticket) else { return }
        renderedImage = image
        publishedRenderCount += 1
        lastPublishedRenderRevision = ticket.revision
    }

    private func scheduleRender(
        _ recipe: DevelopRecipe,
        ticket: RenderTicket,
        onFailure policy: RenderFailurePolicy
    ) {
        let scheduler = renderScheduler
        outstandingRenders[ticket.revision] = Task { [weak self] in
            let outcome = await scheduler.render(recipe, revision: ticket.revision)
            self?.handle(outcome, for: ticket, onFailure: policy)
        }
    }

    private func handle(
        _ outcome: PreviewRenderOutcome,
        for ticket: RenderTicket,
        onFailure policy: RenderFailurePolicy
    ) {
        outstandingRenders[ticket.revision] = nil
        guard isCurrent(ticket) else { return }

        switch outcome {
        case .rendered(let image):
            publish(image, for: ticket)
        case .superseded, .cancelled:
            break
        case .failed:
            apply(policy)
        }
    }

    private func apply(_ policy: RenderFailurePolicy) {
        switch policy {
        case .restoreCommittedEdit:
            // A failed preview leaves the committed image on screen rather
            // than blanking it; the user has lost nothing.
            rerenderFromHistory()
        case .showOriginalAndReport:
            // Re-rendering the committed edit can only fail for environmental
            // reasons; fall back to the untouched source so the user is never
            // left looking at a stale result.
            renderedImage = original.image
            activeError = .developFailed
        }
    }

    /// Runs a control message on the scheduler, tracked so tests can await it.
    private func sendToScheduler(_ message: @escaping @Sendable (PreviewRenderScheduler) async -> Void) {
        let scheduler = renderScheduler
        schedulerControl.append(Task { await message(scheduler) })
    }

    /// Waits until every render and control message issued so far has
    /// finished and been handled. For tests; the app never waits on renders.
    func settleRendering() async {
        while !schedulerControl.isEmpty || !outstandingRenders.isEmpty {
            for task in schedulerControl { await task.value }
            schedulerControl.removeAll()
            await renderScheduler.waitUntilIdle()
            while let (revision, task) = outstandingRenders.first {
                await task.value
                outstandingRenders[revision] = nil
            }
        }
    }

    /// Scheduler counters, for tests asserting the queue stays bounded.
    func renderSchedulerStatistics() async -> (peakOutstanding: Int, started: Int) {
        (await renderScheduler.peakOutstandingRequests, await renderScheduler.startedRenderCount)
    }

    /// Dismisses the active failure.
    func dismissError() {
        activeError = nil
    }
}
