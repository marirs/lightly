import CoreGraphics
import Foundation
import Observation

/// An edit in the M2 pipeline: Auto strength and at most one Look.
///
/// One Look slot, not a list: applying a Look *replaces* the previous one
/// (spec §4.1 — Auto then Look, two passes), so Looks can never stack.
/// The Look is referenced by its pack `lookId` and `lookVersion` (spec
/// `LookRef`), never by category or stop, so relabelling or reordering the
/// catalog cannot change what a saved edit replays.
struct LUTEditState: Equatable, Sendable {
    /// 0 is Auto off; 1 is the model's full output (strength blend, §4.2).
    var autoStrength: Float = 0
    var lookID: String?
    /// The pack's version of `lookID` when the edit was committed.
    var lookVersion: String?
    /// Kept for the edit-state contract; the stepped slider never changes it
    /// (it picks a preset, it is not an intensity control, spec D6).
    var lookStrength: Float = 1

    static let original = LUTEditState()
}

/// Whether Auto can be used for this photo.
enum AutoAvailability: Equatable, Sendable {
    case pending
    case available
    case unavailable(AutoUnavailableReason)
}

/// Renders LUT passes over RGBA8 pixels; `MetalLUTRenderer` in the app,
/// wrappers in tests (e.g. a slow one to exercise latest-wins).
protocol LUTRendering: Sendable {
    func apply(
        _ passes: [LUT3D], toRGBA8 pixels: [UInt8], width: Int, height: Int, maximumTileSide: Int
    ) throws -> [UInt8]
}

extension MetalLUTRenderer: LUTRendering {}

/// Editing state, preview and history for the M2 LUT pipeline (spec §5).
///
/// Preview: a display-sized copy of the decoded original, rendered through
/// the shared latest-wins scheduler. Auto: computed once from the ≤1024
/// analysis proxy. Undo/Reset walk a stack of `LUTEditState`s; Compare shows
/// the original preview. Export re-renders the full-resolution original
/// with the same passes (see `LUTEditSession+Export`).
///
/// The editor screen drives this session through `LUTEditorViewModel`.
/// In this build Auto is explicitly unavailable (no production model) and
/// the Looks come from the bundled Look pack (see
/// `DependencyContainer.live()`).
@MainActor
@Observable
final class LUTEditSession {

    let photo: SelectedPhoto

    private(set) var autoAvailability: AutoAvailability = .pending
    private(set) var renderedImage: CGImage
    private(set) var isShowingOriginal = false
    /// Spec §3 undo cap; same value and semantics as Android
    /// `UndoStack.DEFAULT_CAPACITY` (the starting entry counts).
    static let historyCapacity = 50

    private(set) var history: [LUTEditState] = [.original]
    /// The Look a restored edit referred to that this pack does not have.
    /// Spec §4.5: shown as "Look unavailable", replaced by Auto, never by a
    /// similar-looking substitute.
    private(set) var unavailableRestoredLookID: String?
    private(set) var historyIndex = 0
    /// Renders that reached the screen (diagnostic for latest-wins tests).
    private(set) var publishedRenderCount = 0

    var committedState: LUTEditState { history[historyIndex] }
    var canUndo: Bool { historyIndex > 0 }
    var displayedImage: CGImage { isShowingOriginal ? previewOriginal : renderedImage }

    let lookBook: LUTLookBook
    let previewBase: (pixels: [UInt8], width: Int, height: Int)
    let renderer: any LUTRendering

    private let previewOriginal: CGImage
    private let autoEnhancer: any AutoEnhancing
    private let scheduler: LatestWinsRenderScheduler<[LUT3D]>
    private(set) var autoLUT: LUT3D?
    private var latestRevision: UInt64 = 0
    private var outstandingRenders: [UInt64: Task<Void, Never>] = [:]

    init(
        photo: SelectedPhoto,
        autoEnhancer: any AutoEnhancing,
        lookBook: LUTLookBook,
        renderer: any LUTRendering,
        previewLongEdge: Int = 1_290,
        restoring savedEdit: LUTEditState? = nil
    ) throws {
        guard let preview = AnalysisProxy.downscaled(photo.image, maximumLongEdge: previewLongEdge) else {
            throw LightlyError.developFailed
        }
        let base = (try MetalLUTRenderer.rgba8Bytes(of: preview), preview.width, preview.height)
        self.photo = photo
        self.autoEnhancer = autoEnhancer
        self.lookBook = lookBook
        self.renderer = renderer
        self.previewBase = base
        self.previewOriginal = try MetalLUTRenderer.makeImage(rgba8: base.0, width: base.1, height: base.2)
        self.renderedImage = previewOriginal
        self.scheduler = LatestWinsRenderScheduler { passes in
            let output = try renderer.apply(
                passes, toRGBA8: base.0, width: base.1, height: base.2,
                maximumTileSide: MetalLUTRenderer.defaultMaximumTileSide
            )
            return try MetalLUTRenderer.makeImage(rgba8: output, width: base.1, height: base.2)
        }
        if let savedEdit { restore(savedEdit) }
    }

    /// Starts from a saved edit instead of the original.
    ///
    /// The Look is resolved by ID only; an unknown ID falls back to "no
    /// Look" (Auto) and is remembered so the editor can say so.
    // DEFERRED: a known ID whose `lookVersion` differs (the pack rebuilt that
    // Look's LUT) replays the current LUT and records the current version.
    // Telling the user the Look changed is a product decision for the
    // recovery-snapshot work (spec §5.5, M4).
    // DEFERRED: Auto strength is restored as saved, but Auto is only applied
    // once `prepareAuto()` makes it available; no model ships in this build.
    private func restore(_ savedEdit: LUTEditState) {
        var state = savedEdit
        if let lookID = savedEdit.lookID {
            if let look = lookBook.look(id: lookID) {
                state.lookVersion = look.version
            } else {
                unavailableRestoredLookID = lookID
                state.lookID = nil
                state.lookVersion = nil
                state.lookStrength = LUTEditState.original.lookStrength
            }
        }
        history = [state]
        historyIndex = 0
        render(state)
    }

    // MARK: - Auto

    /// Computes the Auto LUT from the analysis proxy (never the preview).
    func prepareAuto() async {
        guard let proxy = try? AnalysisProxy.make(from: photo) else {
            autoAvailability = .unavailable(.invalidBasis)
            return
        }
        switch await autoEnhancer.autoLUT(forAnalysisProxy: proxy) {
        case .lut(let lut):
            autoLUT = lut
            autoAvailability = .available
        case .unavailable(let reason):
            autoLUT = nil
            autoAvailability = .unavailable(reason)
        }
    }

    /// Commits an Auto strength. Ignored while Auto is unavailable, so an
    /// unavailable Auto can never be recorded as applied.
    func setAutoStrength(_ strength: Float) {
        guard autoAvailability == .available else { return }
        var next = committedState
        next.autoStrength = min(max(strength, 0), 1)
        commit(next)
    }

    // MARK: - Looks

    /// Shows a Look without committing it. Returns false for an unknown ID.
    @discardableResult
    func previewLook(id: String, strength: Float = 1) -> Bool {
        guard let look = lookBook.look(id: id) else { return false }
        var candidate = committedState
        candidate.lookID = id
        candidate.lookVersion = look.version
        candidate.lookStrength = strength
        render(candidate)
        return true
    }

    /// Commits a Look, replacing any previous one. False for an unknown ID.
    @discardableResult
    func applyLook(id: String, strength: Float = 1) -> Bool {
        guard let look = lookBook.look(id: id) else { return false }
        var next = committedState
        next.lookID = id
        next.lookVersion = look.version
        next.lookStrength = min(max(strength, 0), 1)
        commit(next)
        return true
    }

    /// Shows the committed edit without its Look (the slider's Auto stop)
    /// without committing it. Settling there commits via `resetToAuto()`,
    /// which is the same state change (Android `selectLook(null)`).
    func previewAutoStop() {
        var candidate = committedState
        candidate.lookID = nil
        candidate.lookVersion = nil
        candidate.lookStrength = LUTEditState.original.lookStrength
        render(candidate)
    }

    /// Abandons a transient preview and shows the committed edit again.
    func endLookPreview() {
        render(committedState)
    }

    // MARK: - History and Compare

    func undo() {
        guard canUndo else { return }
        historyIndex -= 1
        render(committedState)
    }

    /// "Reset to Auto" (spec §2 and §3): drops the Look and keeps Auto.
    ///
    /// Goes through `commit`, so it is one undoable step and a Reset that
    /// changes nothing adds no step. Parity with Android
    /// `EditSession.resetToAuto()`.
    // v3 differs: the earlier `reset()` replaced history with `[.original]`,
    // which also turned Auto off and made the edit impossible to undo
    // (Codex M2 finding 3).
    func resetToAuto() {
        var next = committedState
        next.lookID = nil
        next.lookVersion = nil
        // Strength belongs to the Look; restore the default so "no Look"
        // has one representation and a later Look starts at 100%.
        next.lookStrength = LUTEditState.original.lookStrength
        commit(next)
    }

    func beginCompare() { isShowingOriginal = true }
    func endCompare() { isShowingOriginal = false }

    /// Records `state` as one undo step and renders it.
    ///
    /// Committing the state that is already committed adds no step, but it
    /// still renders: a commit is also how a transient preview settles, and
    /// returning early would leave e.g. a previewed Look B on screen while
    /// history and export say Look A (Codex M2 finding 2).
    private func commit(_ state: LUTEditState) {
        guard state != committedState else {
            render(committedState)
            return
        }
        history.removeSubrange((historyIndex + 1)...)
        history.append(state)
        dropEntriesBeyondCapacity()
        historyIndex = history.count - 1
        render(state)
    }

    /// Spec §3: at most `historyCapacity` entries, dropping the oldest.
    /// Mirrors Android `UndoStack.commit`: the capacity counts the starting
    /// entry, so after the cap is reached the original can no longer be
    /// reached by Undo (the spec accepts that for 50 steps).
    private func dropEntriesBeyondCapacity() {
        let overflow = history.count - Self.historyCapacity
        guard overflow > 0 else { return }
        history.removeFirst(overflow)
    }

    // MARK: - Passes

    /// The LUT passes for a state: Auto first, then the Look, each its own
    /// pass (spec §4.1 forbids baking them together by default).
    func passes(for state: LUTEditState) -> [LUT3D] {
        var passes: [LUT3D] = []
        if let autoLUT, state.autoStrength > 0 {
            passes.append(autoLUT.blendedTowardIdentity(strength: state.autoStrength))
        }
        if let id = state.lookID, let look = lookBook.look(id: id), state.lookStrength > 0 {
            passes.append(look.lut.blendedTowardIdentity(strength: state.lookStrength))
        }
        return passes
    }

    // MARK: - Rendering

    private func render(_ state: LUTEditState) {
        latestRevision += 1
        let revision = latestRevision
        let passes = passes(for: state)
        guard !passes.isEmpty else {
            // Nothing to apply: show the original immediately and stop
            // anything older, exactly like the recipe path's identity case.
            publish(previewOriginal, revision: revision)
            let scheduler = scheduler
            Task { await scheduler.cancel(through: revision) }
            return
        }
        let scheduler = scheduler
        outstandingRenders[revision] = Task { [weak self] in
            let outcome = await scheduler.render(passes, revision: revision)
            self?.handle(outcome, revision: revision)
        }
    }

    private func handle(_ outcome: PreviewRenderOutcome, revision: UInt64) {
        outstandingRenders[revision] = nil
        if case .rendered(let image) = outcome {
            publish(image, revision: revision)
        }
    }

    private func publish(_ image: CGImage, revision: UInt64) {
        guard revision == latestRevision else { return }
        renderedImage = image
        publishedRenderCount += 1
    }

    /// Waits for every issued render to finish. For tests.
    func settleRendering() async {
        await scheduler.waitUntilIdle()
        while let (revision, task) = outstandingRenders.first {
            await task.value
            outstandingRenders[revision] = nil
        }
    }

    /// Scheduler counters, for tests asserting the queue stays bounded.
    func schedulerStatistics() async -> (peakOutstanding: Int, started: Int) {
        (await scheduler.peakOutstandingRequests, await scheduler.startedRenderCount)
    }
}
