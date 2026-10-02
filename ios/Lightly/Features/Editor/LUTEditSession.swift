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

/// A history to start a session from: states, their revisions and the cursor.
struct RestoredEditHistory: Equatable, Sendable {
    let states: [LUTEditState]
    let revisions: [Int64]
    let cursor: Int
    let lastIssuedRevision: Int64

    /// A single committed edit (no undo history), at revision 0.
    init(single state: LUTEditState) {
        states = [state]
        revisions = [0]
        cursor = 0
        lastIssuedRevision = 0
    }

    /// A saved schema 2 session. The decoder has already enforced its invariants (non-empty,
    /// cursor in range, revisions not ahead of the counter).
    init(_ saved: SavedEditSession) {
        var states = saved.entries.map { entry in
            LUTEditState(
                autoStrength: entry.auto.strength,
                lookID: entry.look?.lookId,
                lookVersion: entry.look?.lookVersion,
                lookStrength: entry.look?.strength ?? LUTEditState.original.lookStrength
            )
        }
        var revisions = saved.entries.map(\.revision)
        var cursor = saved.cursor
        // A session saved with a larger cap keeps its newest entries, as committing would.
        let overflow = states.count - LUTEditSession.historyCapacity
        if overflow > 0 {
            states.removeFirst(overflow)
            revisions.removeFirst(overflow)
            cursor = max(cursor - overflow, 0)
        }
        self.states = states
        self.revisions = revisions
        self.cursor = cursor
        self.lastIssuedRevision = saved.lastIssuedRevision
    }
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
/// analysis proxy. Undo/Redo/Reset walk a stack of `LUTEditState`s; Compare shows
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
    /// Commit counter of each `history` entry (EditState `revision`). Kept beside the states
    /// rather than inside them so that "is this a change?" compares edits, not counters.
    private(set) var historyRevisions: [Int64] = [0]
    /// Monotonic across the session, including after undo-then-commit (Android
    /// `EditSession.lastIssuedRevision`), so it is stored rather than derived from the stack.
    private(set) var lastIssuedRevision: Int64 = 0
    private(set) var historyIndex = 0
    /// Renders that reached the screen (diagnostic for latest-wins tests).
    private(set) var publishedRenderCount = 0

    var committedState: LUTEditState { history[historyIndex] }
    var canUndo: Bool { historyIndex > 0 }
    var canRedo: Bool { historyIndex < history.count - 1 }

    /// How the committed Look relates to the pack. Anything but `.available` renders (and
    /// exports) without the Look while the reference itself is kept (spec §4.5).
    var committedLookResolution: LookResolution { resolution(of: committedState) }

    func resolution(of state: LUTEditState) -> LookResolution {
        lookBook.resolve(lookID: state.lookID, version: state.lookVersion)
    }
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
        restoring savedHistory: RestoredEditHistory? = nil
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
        if let savedHistory { restore(savedHistory) }
    }

    /// Starts from a saved history instead of the original.
    ///
    /// The states are taken exactly as saved: a Look that is missing from the pack or whose
    /// version changed keeps its reference and simply does not render (`passes(for:)`), so the
    /// editor can say so and nothing is substituted (shared/fixtures/edit-state/README.md).
    /// v3 differs: the earlier restore dropped an unknown Look ID and silently replayed the
    /// current LUT for a changed version.
    // DEFERRED: Auto strength is restored as saved, but Auto is only applied
    // once `prepareAuto()` makes it available; no model ships in this build.
    private func restore(_ saved: RestoredEditHistory) {
        history = saved.states
        historyRevisions = saved.revisions
        lastIssuedRevision = saved.lastIssuedRevision
        historyIndex = saved.cursor
        render(committedState)
    }

    // MARK: - Auto

    /// Computes the Auto LUT from the analysis proxy (never the preview).
    func prepareAuto() async {
        guard let proxy = try? AnalysisProxy.make(from: photo) else {
            autoAvailability = .unavailable(.analysisFailed)
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

    /// Previews a Strength for the committed Look while the control is dragged; not a step.
    func previewLookStrength(_ strength: Float) {
        guard committedLookResolution.rendersLook else { return }
        var candidate = committedState
        candidate.lookStrength = min(max(strength, 0), 1)
        render(candidate)
    }

    /// Commits a Strength for the committed Look (control released): one undo step. Without a
    /// rendered Look there is no Strength to set (Android `setLookStrength`).
    func setLookStrength(_ strength: Float) {
        guard committedLookResolution.rendersLook else { return }
        var next = committedState
        next.lookStrength = min(max(strength, 0), 1)
        commit(next)
    }

    /// "Use current version" for a changed Look: one undoable step that records the pack's
    /// current version, after which the Look renders. Nothing happens for any other resolution.
    func useCurrentLookVersion() {
        guard case .changed(_, _, let currentVersion) = committedLookResolution else { return }
        var next = committedState
        next.lookVersion = currentVersion
        commit(next)
    }

    // MARK: - History and Compare

    func undo() {
        guard canUndo else { return }
        historyIndex -= 1
        render(committedState)
    }

    func redo() {
        guard canRedo else { return }
        historyIndex += 1
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
        historyRevisions.removeSubrange((historyIndex + 1)...)
        lastIssuedRevision += 1
        history.append(state)
        historyRevisions.append(lastIssuedRevision)
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
        historyRevisions.removeFirst(overflow)
    }

    // MARK: - Saved session

    /// The history as EditState schema 2 (`SavedEditSession`), for persisting.
    ///
    /// `source` and `auto` describe the Original and the Auto result, which the session does not
    /// own; each entry's Auto strength comes from that entry.
    func savedSession(source: SavedSourceRef, auto: SavedAutoResult) -> SavedEditSession {
        let entries = zip(history, historyRevisions).map { state, revision in
            var entryAuto = auto
            entryAuto.strength = state.autoStrength
            let look = state.lookID.map {
                SavedLookRef(lookId: $0, lookVersion: state.lookVersion ?? "", strength: state.lookStrength)
            }
            return SavedEditState(source: source, auto: entryAuto, look: look, revision: revision)
        }
        return SavedEditSession(
            entries: entries, cursor: historyIndex, capacity: Self.historyCapacity, lastIssuedRevision: lastIssuedRevision
        )
    }

    // MARK: - Passes

    /// The LUT passes for a state: Auto first, then the Look, each its own
    /// pass (spec §4.1 forbids baking them together by default).
    func passes(for state: LUTEditState) -> [LUT3D] {
        var passes: [LUT3D] = []
        if let autoLUT, state.autoStrength > 0 {
            passes.append(autoLUT.blendedTowardIdentity(strength: state.autoStrength))
        }
        // Only an exact ID + version match renders; an unavailable or changed Look is left out of
        // the preview and therefore of Save copy, which uses these same passes.
        if case .available(let id) = resolution(of: state), let look = lookBook.look(id: id), state.lookStrength > 0 {
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
