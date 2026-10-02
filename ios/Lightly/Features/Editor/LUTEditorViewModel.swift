import CoreGraphics
import Foundation
import Observation

/// What the editor shows for the open photo (spec §2, §5.1).
enum LUTEditorPhase: Equatable, Sendable {
    /// The preview is up and Auto is being prepared from the analysis
    /// proxy. The photo stays visible; edit controls are not offered yet.
    case developing
    /// Editing is possible. Auto may still be unavailable — that never
    /// blocks Looks, Compare, Undo, Reset or Save copy.
    case ready
    /// Auto genuinely failed for this photo (not "no model in this build"). The user chooses
    /// Retry or Continue without Auto; the photo stays visible.
    case autoFailed(AutoUnavailableReason)
    /// The photo could not be prepared for editing (decode or GPU set-up).
    case failed(LightlyError)
}

/// Progress of the most recent Save copy (spec §2 step 7).
enum SaveCopyStatus: Equatable, Sendable {
    case idle
    case saving
    /// A new photo was added; the original was not touched (spec D8).
    case saved
    case failed(LightlyError)
}

/// What the editor must say about Auto (spec §2: never imply an enhancement that is not there).
enum AutoNotice: Equatable, Sendable {
    /// No Auto model ships in this build. Nothing to retry.
    case notInBuild
    /// Auto failed for this photo and the user chose to continue without it.
    case failed
}

/// What the editor must say about the committed Look when it is not rendered (spec §4.5).
enum LookNotice: Equatable, Sendable {
    /// The Look is not in this build's pack.
    case unavailable
    /// The Look has changed since the edit; "Use current version" applies the pack's version.
    case changed(lookName: String)
}

/// One stop of a category's stepped slider. Stop 0 is "no Look": the edit
/// without a creative Look ("Original", or "Auto" while Auto is applied).
struct LookStop: Equatable, Sendable {
    /// nil for the Auto stop.
    let lookID: String?
    /// The Look's name; nil for the Auto stop, whose label depends on
    /// whether Auto is applied (`LUTEditorViewModel.noLookStopLabel`).
    let lookName: String?

    var isAutoStop: Bool { lookID == nil }
}

/// Drives the editor screen from a `LUTEditSession` (spec §2 primary flow):
/// photo → Auto → stepped Looks (preview while dragging, commit on settle)
/// → Compare → Undo / Reset to Auto → Save copy.
///
/// The session owns edit state, preview rendering and history; this type
/// adds only what the screen needs on top: the phase, the selected
/// category, the stop being dragged over, Compare's hold/toggle split and
/// Save copy status. Views read state and call intents; they never touch
/// the session directly.
@MainActor
@Observable
final class LUTEditorViewModel {

    let photo: SelectedPhoto
    let lookBook: LUTLookBook

    private(set) var phase: LUTEditorPhase
    private(set) var selectedCategoryID: String?
    private(set) var saveStatus: SaveCopyStatus = .idle
    /// The stop under the finger while the slider moves; nil once settled.
    private(set) var previewedStopIndex: Int?
    /// Compare engaged by the toggle (the non-hold alternative, spec D10).
    private(set) var isCompareToggledOn = false
    /// Compare engaged by press-and-hold on the photo.
    private(set) var isCompareHeld = false
    /// The Strength under the finger while the Strength control moves; nil once released.
    private(set) var previewedLookStrength: Float?

    /// nil only when the photo could not be prepared (`phase == .failed`).
    private(set) var session: LUTEditSession?

    /// Readable so tests can await completion instead of polling.
    private(set) var developTask: Task<Void, Never>?
    private(set) var saveTask: Task<Void, Never>?

    private let libraryWriter: any PhotoLibraryWriting
    private var isClosed = false

    /// Creates the session and starts Auto immediately: selecting a photo
    /// develops it, there is no Develop button (spec D2).
    ///
    /// - Parameter renderer: nil when Metal could not be set up; the editor
    ///   then reports a failure instead of editing without a renderer.
    // DEFERRED: the display preview is downscaled on the main actor inside
    // `LUTEditSession.init`. Fine for library-sized photos; move it off the
    // main actor before 48 MP captures are common inputs.
    init(
        photo: SelectedPhoto,
        autoEnhancer: any AutoEnhancing,
        lookBook: LUTLookBook,
        renderer: (any LUTRendering)?,
        libraryWriter: any PhotoLibraryWriting,
        previewLongEdge: Int = 1_290,
        // DEFERRED: the app passes neither yet. Relaunch restore needs the Original again, which
        // iOS can only reopen with Photos read access or a private copy of the photo; both are a
        // product decision for the recovery snapshot (spec §5.5, M4). Tests exercise both paths.
        restoring savedEdit: LUTEditState? = nil,
        restoringSession savedSession: SavedEditSession? = nil
    ) {
        self.photo = photo
        self.lookBook = lookBook
        self.libraryWriter = libraryWriter
        let restored = savedSession.map(RestoredEditHistory.init) ?? savedEdit.map(RestoredEditHistory.init(single:))
        // The pack's first category, unless a restored Look lives elsewhere.
        // Never a named default: categories are pack data.
        let restoredLookCategory = restored.flatMap { $0.states[$0.cursor].lookID }.flatMap { lookID in
            lookBook.categories.first { $0.lookIDs.contains(lookID) }?.id
        }
        self.selectedCategoryID = restoredLookCategory ?? lookBook.categories.first?.id

        guard let renderer,
              let session = try? LUTEditSession(
                photo: photo, autoEnhancer: autoEnhancer, lookBook: lookBook,
                renderer: renderer, previewLongEdge: previewLongEdge, restoring: restored
              ) else {
            self.phase = .failed(.developFailed)
            return
        }
        self.session = session
        self.phase = .developing
        startAuto(on: session)
    }

    private func startAuto(on session: LUTEditSession) {
        developTask = Task { [weak self] in
            await session.prepareAuto()
            self?.finishDeveloping()
        }
    }

    /// "No model in this build" goes straight to editing with a notice: retrying cannot help.
    /// A genuine failure stops on Retry / Continue so it is never mistaken for an edited photo.
    private func finishDeveloping() {
        guard !isClosed else { return }
        if case .unavailable(let reason) = autoAvailability, reason.isRetryableFailure, !hasContinuedWithoutAuto {
            phase = .autoFailed(reason)
        } else {
            phase = .ready
        }
    }

    /// Set once the user chose Continue after an Auto failure; Auto then stays off for this photo.
    private(set) var hasContinuedWithoutAuto = false

    /// Retry after a genuine Auto failure.
    func retryAuto() {
        guard case .autoFailed = phase, let session else { return }
        phase = .developing
        startAuto(on: session)
    }

    /// Continue editing without Auto after a genuine failure; the notice says Auto failed.
    func continueWithoutAuto() {
        guard case .autoFailed = phase else { return }
        hasContinuedWithoutAuto = true
        phase = .ready
    }

    // MARK: - Derived state

    var displayedImage: CGImage { session?.displayedImage ?? photo.image }

    var isShowingOriginal: Bool { session?.isShowingOriginal ?? false }

    var autoAvailability: AutoAvailability { session?.autoAvailability ?? .pending }

    /// True once Auto is known to be unavailable; the screen must say so
    /// rather than imply the photo was enhanced.
    var isAutoUnavailable: Bool {
        if case .unavailable = autoAvailability { return true }
        return false
    }

    /// The Auto notice to show, if any. While a failure waits for Retry/Continue the failure row
    /// itself explains it, so no separate notice is shown.
    var autoNotice: AutoNotice? {
        guard case .unavailable(let reason) = autoAvailability else { return nil }
        if reason.isRetryableFailure {
            return phase == .ready ? .failed : nil
        }
        return .notInBuild
    }

    var isReady: Bool { phase == .ready }

    var categories: [LUTLookCategory] { lookBook.categories }

    /// Auto followed by the selected category's Looks.
    var stops: [LookStop] {
        guard let selectedCategoryID else { return [] }
        let looks = lookBook.stops(inCategory: selectedCategoryID)
        guard !looks.isEmpty else { return [] }
        return [LookStop(lookID: nil, lookName: nil)] + looks.map { LookStop(lookID: $0.id, lookName: $0.name) }
    }

    /// Where the committed Look sits in the selected category; 0 (Auto)
    /// when there is no Look, it belongs to another category, or it is not
    /// rendered (unavailable or changed: the slider shows what the photo shows).
    var settledStopIndex: Int {
        guard let selectedCategoryID, case .available(let lookID) = lookResolution else { return 0 }
        return lookBook.stopIndex(of: lookID, inCategory: selectedCategoryID)
    }

    /// The slider's position: the dragged stop while moving, else settled.
    var displayedStopIndex: Int { previewedStopIndex ?? settledStopIndex }

    /// The committed Look while it renders, for labels and VoiceOver. nil for a Look that is
    /// unavailable or changed: naming it would claim the photo shows it.
    var committedLook: LUTLook? {
        guard case .available(let lookID) = lookResolution else { return nil }
        return lookBook.look(id: lookID)
    }

    /// How the committed Look resolves against this pack (spec §4.5).
    var lookResolution: LookResolution { session?.committedLookResolution ?? .noLook }

    /// Shown for as long as the committed edit carries a Look that is not rendered, so the
    /// screen (and Save copy, which matches it) is never mistaken for the saved Look.
    var lookNotice: LookNotice? {
        switch lookResolution {
        case .noLook, .available: return nil
        case .unavailable: return .unavailable
        case .changed(let lookID, _, _): return .changed(lookName: lookBook.look(id: lookID)?.name ?? lookID)
        }
    }

    var canUseCurrentLookVersion: Bool {
        guard isReady, case .changed = lookResolution else { return false }
        return true
    }

    /// "Use current version": a new undoable step; the Look renders from then on.
    func useCurrentLookVersion() {
        guard canUseCurrentLookVersion, let session else { return }
        abandonStopPreview()
        session.useCurrentLookVersion()
        editDidChange()
    }

    /// True only while an Auto correction is actually applied: Auto is
    /// available and the committed edit uses it at a strength above 0.
    var isAutoApplied: Bool {
        autoAvailability == .available && (session?.committedState.autoStrength ?? 0) > 0
    }

    /// Stop 0 ("no Look") names what it shows: "Auto" only while an Auto
    /// correction is applied, otherwise "Original" — with no Auto model,
    /// Auto unavailable or at strength 0, calling it "Auto" would claim an
    /// enhancement that is not there.
    var noLookStopLabel: String {
        isAutoApplied ? String(localized: "editor.stop.auto") : String(localized: "editor.stop.original")
    }

    /// The visible name of a stop: the preset's name verbatim from the pack,
    /// or `noLookStopLabel` for stop 0.
    func stopLabel(at index: Int) -> String {
        guard stops.indices.contains(index) else { return "" }
        return stops[index].lookName ?? noLookStopLabel
    }

    /// The selected category's label from the pack (never a built-in name).
    var selectedCategoryLabel: String {
        categories.first { $0.id == selectedCategoryID }?.label ?? ""
    }

    /// The visible name and position of the displayed stop, e.g. "3 of 5".
    var stopPositionText: String {
        guard !stops.isEmpty else { return "" }
        return String(format: String(localized: "editor.lookSlider.position"), displayedStopIndex + 1, stops.count)
    }

    /// VoiceOver value of the slider, e.g. "Warm, Nordic Tone (10), 3 of 5".
    var sliderAccessibilityValue: String {
        let index = displayedStopIndex
        return String(
            format: String(localized: "editor.lookSlider.value"),
            selectedCategoryLabel, stopLabel(at: index), index + 1, stops.count
        )
    }

    /// Spec §4.5: Looks that are model approximations or not yet checked
    /// against Lightroom must be labelled as such on screen.
    var showsApproximateLooksNotice: Bool { lookBook.offersApproximateLooks }

    var canUndo: Bool { isReady && (session?.canUndo ?? false) }

    var canRedo: Bool { isReady && (session?.canRedo ?? false) }

    /// Reset to Auto has something to do while the edit carries a Look, rendered or not (a
    /// stale reference can be cleared this way too).
    var canResetToAuto: Bool { isReady && session?.committedState.lookID != nil }

    // MARK: - Strength

    /// Strength belongs to a rendered Look; with none there is no control (Android parity).
    var showsStrengthControl: Bool { isReady && committedLook != nil && previewedStopIndex == nil }

    /// The Strength shown: the dragged value while moving, else the committed one.
    var displayedLookStrength: Float {
        previewedLookStrength ?? session?.committedState.lookStrength ?? LUTEditState.original.lookStrength
    }

    /// The Strength control moved: transient preview, not a step.
    func previewLookStrength(_ strength: Float) {
        guard showsStrengthControl, let session else { return }
        let clamped = min(max(strength, 0), 1)
        previewedLookStrength = clamped
        session.previewLookStrength(clamped)
    }

    /// The Strength control was released (or adjusted by VoiceOver): one undo step.
    func commitLookStrength(_ strength: Float) {
        guard showsStrengthControl, let session else { return }
        previewedLookStrength = nil
        session.setLookStrength(min(max(strength, 0), 1))
        editDidChange()
    }

    var canSaveCopy: Bool { isReady && saveStatus != .saving }

    // MARK: - Looks

    /// Changing category alone does not change the Look (spec §2 step 4).
    func selectCategory(_ categoryID: String) {
        guard categories.contains(where: { $0.id == categoryID }) else { return }
        abandonStopPreview()
        selectedCategoryID = categoryID
    }

    /// The slider moved onto `index`: transient preview, not in history.
    func previewStop(_ index: Int) {
        guard isReady, let session, let stop = stop(at: index), index != previewedStopIndex else { return }
        previewedStopIndex = index
        if let lookID = stop.lookID {
            session.previewLook(id: lookID)
        } else {
            session.previewAutoStop()
        }
    }

    /// The slider settled on `index` (finger up, or an accessibility
    /// increment): one undo step, replacing any previous Look. Settling on
    /// the already committed stop adds no step but still clears the preview.
    func settleStop(_ index: Int) {
        guard isReady, let session, let stop = stop(at: index) else { return }
        previewedStopIndex = nil
        if let lookID = stop.lookID {
            session.applyLook(id: lookID)
        } else {
            // The Auto stop is "no Look": the same state change as Reset to
            // Auto (Android maps both to `selectLook(null)`).
            session.resetToAuto()
        }
        editDidChange()
    }

    /// Accessibility increment/decrement: settle the next or previous stop,
    /// clamped to the ends. One preset per step; nothing in between.
    func adjustStop(by offset: Int) {
        guard !stops.isEmpty else { return }
        settleStop(min(max(displayedStopIndex + offset, 0), stops.count - 1))
    }

    private func stop(at index: Int) -> LookStop? {
        stops.indices.contains(index) ? stops[index] : nil
    }

    private func abandonStopPreview() {
        guard previewedStopIndex != nil else { return }
        previewedStopIndex = nil
        session?.endLookPreview()
    }

    // MARK: - History

    func undo() {
        guard canUndo, let session else { return }
        abandonStopPreview()
        session.undo()
        editDidChange()
    }

    func redo() {
        guard canRedo, let session else { return }
        abandonStopPreview()
        session.redo()
        editDidChange()
    }

    func resetToAuto() {
        guard canResetToAuto, let session else { return }
        abandonStopPreview()
        session.resetToAuto()
        editDidChange()
    }

    /// A "Saved" confirmation describes an earlier edit once the edit
    /// changes, so it is cleared rather than left to mislead.
    private func editDidChange() {
        if saveStatus == .saved { saveStatus = .idle }
        previewedLookStrength = nil
    }

    // MARK: - Compare (spec D10: hold and toggle)

    func beginCompareHold() {
        guard isReady else { return }
        isCompareHeld = true
        applyCompare()
    }

    func endCompareHold() {
        isCompareHeld = false
        applyCompare()
    }

    /// The accessible, non-hold alternative.
    func toggleCompare() {
        guard isReady else { return }
        isCompareToggledOn.toggle()
        applyCompare()
    }

    /// Either input shows the original; releasing a hold must not switch
    /// off a toggle the user turned on, and vice versa.
    private func applyCompare() {
        guard let session else { return }
        if isCompareHeld || isCompareToggledOn {
            session.beginCompare()
        } else {
            session.endCompare()
        }
    }

    // MARK: - Save copy

    /// Renders the committed edit at full resolution and adds it as a new
    /// photo (tiled export, `LUTEditSession+Export`). A transient preview is
    /// never what gets saved.
    func saveCopy() {
        guard canSaveCopy, let session else { return }
        saveStatus = .saving
        let writer = libraryWriter
        saveTask = Task { [weak self] in
            do {
                try await session.saveCopy(to: writer)
                self?.finishSave(.saved)
            } catch let error as LightlyError {
                // Declining is not a failure to report (spec §28).
                self?.finishSave(error.isFault ? .failed(error) : .idle)
            } catch {
                self?.finishSave(.failed(.exportFailed))
            }
        }
    }

    private func finishSave(_ status: SaveCopyStatus) {
        guard !isClosed else { return }
        saveStatus = status
    }

    // MARK: - Lifecycle

    /// Ends the editing session when the photo is closed or replaced:
    /// nothing that finishes later changes this (discarded) screen state.
    // DEFERRED: an in-flight Save copy is allowed to finish writing (the
    // export runs detached and has no cancellation point yet); only its
    // status update is dropped.
    func close() {
        isClosed = true
        developTask?.cancel()
    }

    /// Waits for issued renders. For tests; the app never waits on renders.
    func settleRendering() async {
        await session?.settleRendering()
    }
}
