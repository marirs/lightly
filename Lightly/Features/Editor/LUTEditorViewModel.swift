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

    /// nil only when the photo could not be prepared (`phase == .failed`).
    private(set) var session: LUTEditSession?

    /// A restored edit named a Look this pack does not have (spec §4.5,
    /// "Look unavailable"); cleared once the user changes the edit.
    private(set) var showsLookUnavailableNotice = false

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
        // DEFERRED: nothing passes a saved edit yet; the recovery snapshot
        // that would supply one is spec §5.5 (M4).
        restoring savedEdit: LUTEditState? = nil
    ) {
        self.photo = photo
        self.lookBook = lookBook
        self.libraryWriter = libraryWriter
        // The pack's first category, unless a restored Look lives elsewhere.
        // Never a named default: categories are pack data.
        let restoredLookCategory = savedEdit?.lookID.flatMap { lookID in
            lookBook.categories.first { $0.lookIDs.contains(lookID) }?.id
        }
        self.selectedCategoryID = restoredLookCategory ?? lookBook.categories.first?.id

        guard let renderer,
              let session = try? LUTEditSession(
                photo: photo, autoEnhancer: autoEnhancer, lookBook: lookBook,
                renderer: renderer, previewLongEdge: previewLongEdge, restoring: savedEdit
              ) else {
            self.phase = .failed(.developFailed)
            return
        }
        self.session = session
        self.showsLookUnavailableNotice = session.unavailableRestoredLookID != nil
        self.phase = .developing
        developTask = Task { [weak self] in
            await session.prepareAuto()
            self?.finishDeveloping()
        }
    }

    private func finishDeveloping() {
        guard !isClosed else { return }
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
    /// when there is no Look or it belongs to another category.
    var settledStopIndex: Int {
        guard let selectedCategoryID, let session else { return 0 }
        return lookBook.stopIndex(of: session.committedState.lookID, inCategory: selectedCategoryID)
    }

    /// The slider's position: the dragged stop while moving, else settled.
    var displayedStopIndex: Int { previewedStopIndex ?? settledStopIndex }

    /// The committed Look, for labels and VoiceOver.
    var committedLook: LUTLook? {
        session?.committedState.lookID.flatMap(lookBook.look(id:))
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

    /// Reset to Auto only has something to do while a Look is committed.
    var canResetToAuto: Bool { isReady && committedLook != nil }

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
        showsLookUnavailableNotice = false
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
