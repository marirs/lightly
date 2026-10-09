import CoreGraphics
import CryptoKit
import Foundation
import Observation
import UIKit
import OSLog

/// One continuous editing session for one photo (approved prototype `newSession` / `Prototype`).
///
/// - The session state is an `EditRecipe` (EditState schema 3). Undo and Redo walk a stack of whole
///   recipes, so every tool's edit is restored together.
/// - Preview and Save copy evaluate the same committed recipe through the same Develop renderer;
///   only the resolution differs.
/// - Previews are latest-request-wins: at most one render runs and one waits, and a result is shown
///   only if it belongs to the newest request.
/// - Switching photos ends the session (`close()`): nothing that finishes later is shown or saved.
@MainActor
@Observable
final class EditorSession {

    // MARK: - Phases (approved `loading` → `developing` → editor)

    enum Phase: Equatable {
        /// "Opening photo…" over the photo: preview prepared, person detection, pack loaded.
        case opening
        /// "Developing…": automatic Develop is running.
        case developing
        case ready
    }

    /// The approved Auto states (`s.auto`).
    enum AutoState: String, Equatable {
        /// Correction applied (stop zero reads "Auto").
        case applied
        /// Correction available but switched off (stop zero reads "Original").
        case off
        /// No model on this device: "Automatic correction isn't available on this device."
        case unavailable
        /// The model ran and failed: "Automatic correction didn't finish." with Retry and
        /// Continue with original.
        case failed
    }

    enum SaveState: Equatable {
        case idle
        case saving
        /// The written JPEG, kept for Share.
        case saved(Data)
        /// Photos add permission declined (iOS): "Can’t save to Photos".
        case permissionDenied
        case storageFull
        case failed
    }

    let photo: SelectedPhoto
    private(set) var phase: Phase = .opening
    private(set) var autoState: AutoState = .unavailable
    /// nil until Vision has answered; Portrait is offered only when true.
    private(set) var hasPerson: Bool?
    private(set) var history: [EditRecipe]
    private(set) var historyIndex = 0 { didSet { historyRevision &+= 1 } }
    /// Increases on every change of the history position (commit, Undo, Redo, restore), even when Undo returns to an
    /// earlier index; the Develop panel uses it to stop browsing once the history moves.
    private(set) var historyRevision = 0
    private(set) var displayedImage: CGImage
    /// Where the photo sits inside the displayed canvas (fractions; the whole canvas without a
    /// border): the prototype's `.imgbox` inside `.frame`, which marks and touches use.
    private(set) var displayedImageBox = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The photo (inside any border) as the editor displays it, in points. The watermark's size
    /// and Focus & Blur's strength are defined on screen (PROVISIONAL coordinator approach to defect W1, pending the owner),
    /// so preview renders use the current layout and Save copy / Share the layout when saving.
    private(set) var displayedPhotoSize: CGSize?
    @ObservationIgnored private var renderReferencePhotoSize: CGSize?
    @ObservationIgnored private var activePreviewRecipe: EditRecipe?

    /// The editor's stage reports the displayed photo's size; a change re-renders what depends on it.
    func setDisplayedPhotoSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if let current = displayedPhotoSize, abs(current.width - size.width) < 0.5, abs(current.height - size.height) < 0.5 { return }
        displayedPhotoSize = size
        // Panel height is navigation, not an edit to blur or watermark size.
        guard renderReferencePhotoSize == nil else { return }
        renderReferencePhotoSize = size
        let tools = recipe.tools
        if tools.watermark.type != .none || tools.background.focus.blur > 0 {
            if let activePreviewRecipe { render(activePreviewRecipe, final: false) }
            else { renderCommitted() }
        }
    }
    private(set) var isShowingOriginal = false
    private(set) var saveState: SaveState = .idle
    /// Edits made since the last saved copy (the approved `dirty`).
    private(set) var hasUnsavedEdits = false

    /// Subject separation for Background (approved `bg-separating`, `bg-failed`, `bg-no-subject`).
    enum SubjectState: Equatable {
        case notStarted
        /// "Finding the subject…", cancellable.
        case separating
        case ready
        /// No clear subject; depth-only blur is still offered.
        case noSubject
        /// "Couldn't separate the subject."
        case failed
        /// Cancel (prototype `cancelOp`): back to the panel with nothing changed; the next Background edit starts
        /// the analysis again, never a view refresh.
        case cancelled
    }

    /// The subject matte only: Change background and Refine edges need nothing else.
    private(set) var subjectState: SubjectState = .notStarted

    /// Depth, estimated alongside the matte but independently: only Focus & Blur (and the no-subject
    /// blur) waits for it, so a slow or failed depth model never holds up Change background.
    enum DepthState: Equatable { case notStarted, estimating, ready, failed, cancelled }
    private(set) var depthState: DepthState = .notStarted

    /// What the Background panel (and the stage) shows.
    enum BackgroundContent: Equatable {
        /// "Finding the subject…" with Cancel.
        case finding
        /// "Couldn't separate the subject." with Try again (approved `bg-failed`).
        case subjectFailed
        /// Depth failed while the subject outline is fine: only blurring is unavailable. The copy is a proposal
        /// awaiting owner approval (no approved depth-specific message exists; the subject message would be wrong).
        case depthFailed
        /// The subject outline is ready and the operation needs depth, which is still being estimated (Focus & Blur
        /// only). PROPOSED copy "Estimating depth…" (owner approval pending, 2026-10-07): the approved screens have no
        /// depth-specific progress, and "Finding the subject…" would be untrue once the outline is done.
        case estimatingDepth
        /// "No clear subject found." with the Blur slider (approved `bg-no-subject`).
        case noSubject
        /// The mode's controls: analysis done, or cancelled (prototype `cancelOp` returns to the panel).
        case controls
    }

    /// Operations that blur need depth as well as the matte (never a matte-only blur, §R8); Change background and
    /// Refine edges need only the matte.
    func backgroundContent(needsDepth: Bool) -> BackgroundContent {
        switch subjectState {
        case .notStarted, .separating: return .finding
        case .failed: return .subjectFailed
        case .cancelled: return .controls
        // No subject: the approved notice and Blur slider at once, in either mode (prototype `backgroundPanel`
        // returns them before anything else). It never waits for depth: depth only matters once Blur is used, and
        // its progress is then shown on its own (`depthProgressVisible`). v3 differs (2026-10-07): it used to wait
        // for depth here, so Change background showed "Finding the subject…" for the whole depth-model load.
        case .noSubject: return depthState == .failed ? .depthFailed : .noSubject
        case .ready: break
        }
        guard needsDepth else { return .controls }
        switch depthState {
        case .notStarted, .estimating: return .estimatingDepth
        case .failed: return .depthFailed
        case .ready, .cancelled: return .controls
        }
    }

    /// The stage shows depth progress (not "Finding the subject…") while depth is estimated for an operation that
    /// needs it: Focus & Blur after the outline, or Blur on a photo with no clear subject.
    func depthProgressVisible(needsDepth: Bool) -> Bool {
        guard depthState == .estimating else { return false }
        switch subjectState {
        case .ready: return needsDepth
        case .noSubject: return needsDepth || recipe.tools.background.focus.blur > 0
        default: return false
        }
    }

    /// Faces and people (Portrait), once analysed.
    private(set) var people: PeopleAnalysis?
    /// The subject matte as an image, for the refine-edges tint.
    private(set) var matteImage: CGImage?
    /// Where focus sits until the person taps: the subject's centroid (§R3), source coordinates.
    private(set) var defaultFocusTarget: (x: Double, y: Double)?

    static let historyCapacity = 50

    var recipe: EditRecipe { history[historyIndex] }
    var canUndo: Bool { historyIndex > 0 }
    var canRedo: Bool { historyIndex < history.count - 1 }

    /// The Develop Look the committed recipe holds, resolved against the pack (never substituted).
    var appliedPreset: PresetPack.Preset? {
        guard let look = recipe.look, case .available(let preset) = library.pack.resolve(lookID: look.lookId, version: look.lookVersion)
        else { return nil }
        return preset
    }

    /// The applied Look's Amount, 0…100.
    var appliedAmount: Double { (recipe.look?.strength ?? 1) * 100 }

    // MARK: - Dependencies

    let library: DevelopLibrary
    private let autoEnhancer: any AutoEnhancing
    private let personDetector: any PersonDetecting
    /// Vision and the depth model (slice 3). nil in tests that do not exercise them.
    private let sceneAnalyser: (any SceneAnalysing)?
    private let libraryWriter: any PhotoLibraryWriting
    private let exporter: any PhotoExporting
    private let saveSettings: @MainActor () -> ExportSettings
    private let previewLongEdge: Int
    /// Loads the Remove model on first use (LaMa; nil = not in this build or gated off).
    private let inpainterLoader: @Sendable () -> (any Inpainting)?
    /// Saved signatures and chosen logos the watermark resolves against (stage 12).
    let signatures: SignatureStore
    /// Where the session is kept while it has unsaved edits (restored after the system ends the app).
    private let sessionStore: EditSessionStore?
    /// A session read back from `sessionStore`: opened as it was, without running any model.
    private let restoring: PersistedEditSession?
    /// The original's bytes are on disk for this session.
    @ObservationIgnored private var sessionPersisted = false
    /// Bumped whenever a model result arrives; the analysis is written when it differs.
    @ObservationIgnored private var analysisRevision = 0
    @ObservationIgnored private var analysisPersistedRevision = -1

    @ObservationIgnored private var previewBase: (pixels: [UInt8], width: Int, height: Int)?
    /// The preview base at a quarter of the pixels (half the long edge: 800 on a phone), for ruler-drag frames only.
    @ObservationIgnored private var dragBase: (pixels: [UInt8], width: Int, height: Int)?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    /// When the current ruler drag first asked for a frame (time to the first visible drag frame, traced).
    @ObservationIgnored private var dragStartedAt: ContinuousClock.Instant? { didSet { if dragStartedAt == nil { firstDragFrameTraced = false } } }
    @ObservationIgnored private var firstDragFrameTraced = false
    #if DEBUG
    /// Every frame put on screen, in order: (request generation, preset id, drag frame). Tests of the live ruler.
    @ObservationIgnored private(set) var debugPublished: [(generation: UInt64, lookID: String?, dragFrame: Bool)] = []
    #endif
    @ObservationIgnored private var originalPreview: CGImage
    @ObservationIgnored private var scheduler: LatestWinsRenderScheduler<RenderJob>?
    @ObservationIgnored private var autoLUT: LUT3D?
    /// The Core Image Auto correction behind `autoLUT` (stored with the session; a restore rebuilds the LUT from it).
    @ObservationIgnored private var autoCorrection: CoreImageAutoCorrection?
    /// Per-preset Amount the person chose in this session, so re-selecting a preset restores it.
    @ObservationIgnored private var amountMemory: [String: Double] = [:]
    /// Model results for Background and Portrait, at the preview resolution.
    @ObservationIgnored private var sceneCache = SceneCache() { didSet { sceneGeneration &+= 1 } }
    @ObservationIgnored private var sceneGeneration: UInt64 = 0
    @ObservationIgnored private var subjectTask: Task<Void, Never>?
    @ObservationIgnored private var depthTask: Task<Void, Never>?
    /// Each start of the matte or depth bumps its generation; a result is accepted only by the generation that
    /// started it, so a cancelled run that finishes late (the depth model load cannot be interrupted) never
    /// overwrites a newer run's state.
    @ObservationIgnored private var subjectGeneration = 0
    @ObservationIgnored private var depthGeneration = 0
    /// Resolving a tap's focal plane (setFocusTarget).
    @ObservationIgnored private var focusTask: Task<Void, Never>?
    /// Person segmentation for the hair operators (ensurePersonMatte).
    @ObservationIgnored private var personMatteTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    // Latest-request-wins bookkeeping.
    @ObservationIgnored private var nextJobRevision: UInt64 = 0
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var publishedGeneration: UInt64 = 0
    @ObservationIgnored private var publishedWasFull = false
    @ObservationIgnored private var outstanding: [UInt64: Task<Void, Never>] = [:]

    /// For each preview request: the time from the request until a frame of it (or of a newer
    /// request) reached the screen. Performance evidence for "no stale preview older than 100 ms".
    @ObservationIgnored private(set) var previewStaleness: [Duration] = []
    @ObservationIgnored private var pendingRequests: [(generation: UInt64, at: ContinuousClock.Instant)] = []
    /// Renders that reached the screen (diagnostic for tests).
    @ObservationIgnored private(set) var publishedRenderCount = 0

    init(photo: SelectedPhoto,
         library: DevelopLibrary,
         autoEnhancer: any AutoEnhancing = ModelNotBundledAutoEnhancer(),
         personDetector: any PersonDetecting = VisionPersonDetector(),
         sceneAnalyser: (any SceneAnalysing)? = nil,
         libraryWriter: any PhotoLibraryWriting = PhotoKitLibraryWriter(),
         exporter: any PhotoExporting = ImageIOPhotoExporter(),
         saveSettings: @escaping @MainActor () -> ExportSettings = { .default },
         previewLongEdge: Int = 1_600,
         inpainterLoader: @escaping @Sendable () -> (any Inpainting)? = { LamaInpainter.loadBundled() },
         signatures: SignatureStore? = nil,
         removePatches: RemovePatchStore = RemovePatchStore(),
         sessionStore: EditSessionStore? = nil,
         restoring: PersistedEditSession? = nil) {
        self.photo = photo
        self.library = library
        self.autoEnhancer = autoEnhancer
        self.personDetector = personDetector
        self.sceneAnalyser = sceneAnalyser
        self.libraryWriter = libraryWriter
        self.exporter = exporter
        self.saveSettings = saveSettings
        self.previewLongEdge = previewLongEdge
        self.inpainterLoader = inpainterLoader
        // Built here, not as a default argument: the store is main-actor isolated. Without one
        // (tests) signatures live in memory only.
        self.signatures = signatures ?? SignatureStore(directory: nil)
        self.removePatches = removePatches
        self.sessionStore = sessionStore
        self.restoring = restoring
        let source = Self.sourceReference(for: photo)
        history = [.neutral(source: source, grainSeed: EditRecipe.grainSeed(fromHeadSha256: source.fingerprint.headSha256))]
        // Until the preview copy exists the photo itself is shown (the approved loading screen keeps
        // the photo visible).
        displayedImage = photo.image
        originalPreview = photo.image
    }

    // MARK: - Opening and automatic Develop

    /// Opening → (Developing) → editor. Safe to call once; later calls do nothing.
    func start() {
        guard startTask == nil else { return }
        startTask = Task { [weak self] in await self?.open() }
    }

    private func open() async {
        let openStarted = ContinuousClock.now
        let image = photo.image
        let longEdge = previewLongEdge
        // The source as the app received it (the picker's bytes): the baseline an "original unchanged" check compares.
        let original = photo.originalData
        Task.detached(priority: .utility) {
            DiagnosticTrace.note("source: \(image.width)x\(image.height), \(original.count) bytes sha256 \(EditorSession.sha256(original))")
        }
        let prepared = await Task.detached(priority: .userInitiated) { () -> (pixels: [UInt8], width: Int, height: Int, image: CGImage)? in
            guard let preview = AnalysisProxy.downscaled(image, maximumLongEdge: longEdge),
                  let pixels = try? MetalLUTRenderer.rgba8Bytes(of: preview),
                  let rebuilt = try? MetalLUTRenderer.makeImage(rgba8: pixels, width: preview.width, height: preview.height)
            else { return nil }
            return (pixels, preview.width, preview.height, rebuilt)
        }.value
        let dragSource = prepared?.image
        let drag = await Task.detached(priority: .userInitiated) { () -> (pixels: [UInt8], width: Int, height: Int)? in
            guard let dragSource, let small = AnalysisProxy.downscaled(dragSource, maximumLongEdge: max(longEdge / 2, 1)),
                  let pixels = try? MetalLUTRenderer.rgba8Bytes(of: small) else { return nil }
            return (pixels, small.width, small.height)
        }.value
        dragBase = drag
        guard !isClosed else { return }
        if let prepared {
            previewBase = (prepared.pixels, prepared.width, prepared.height)
            originalPreview = prepared.image
            displayedImage = prepared.image
        }
        if let restoring {
            // Restore: no model runs again (Auto, Vision, depth). Every result comes from storage.
            await library.waitUntilLoaded()
            if prepared != nil { makeScheduler() }
            guard !isClosed else { return }
            applyRestored(restoring)
            return
        }
        DiagnosticTrace.note("open: preview prepared at \(DebugModelLoad.ms(since: openStarted)) ms")
        async let person = personDetector.containsPerson(prepared?.image ?? image)
        if let sceneAnalyser {
            let analysed = await sceneAnalyser.people(in: prepared?.image ?? image)
            people = analysed
            sceneCache.people = analysed
            #if DEBUG
            // Capture sessions record what the face analysis found, so a screen showing
            // "No face can be edited" can be traced to its cause.
            for face in analysed.faces {
                DebugCaptureTiming.mark(String(format: "face box=%.3f,%.3f,%.3f,%.3f quality=%.2f eyes=%d,%d lips=%d usable=%@",
                                               face.box.x, face.box.y, face.box.width, face.box.height, face.quality ?? -1,
                                               face.leftEye.count, face.rightEye.count, face.outerLips.count,
                                               face.isUsable ? "yes" : "no").replacingOccurrences(of: " ", with: "_"))
            }
            #endif
        }
        // The renderer and bake cache exist only once the library has loaded (it loads in the
        // background from launch), so the preview scheduler is made after that.
        await library.waitUntilLoaded()
        if prepared != nil { makeScheduler() }
        hasPerson = await person
        analysisRevision += 1
        DiagnosticTrace.note("open: people and library at \(DebugModelLoad.ms(since: openStarted)) ms")
        guard !isClosed else { return }
        #if DEBUG
        // Design captures of the loading screen (`--hold-phase`): stay in that phase.
        if let held = DebugScenario.heldPhase {
            phase = held
            return
        }
        #endif
        await develop()
        DiagnosticTrace.note("open: ready at \(DebugModelLoad.ms(since: openStarted)) ms, phase \(phase)")
    }

    /// Runs automatic Develop. With no model in the build this resolves at once to the approved
    /// unavailable state; nothing is ever presented as Auto unless a model produced it.
    private func develop() async {
        phase = .developing
        let proxy = try? AnalysisProxy.make(from: photo)
        let result: AutoResult = if let proxy { await autoEnhancer.autoLUT(forAnalysisProxy: proxy) } else { .unavailable(.analysisFailed) }
        guard !isClosed else { return }
        switch result {
        case .lut, .coreImage:
            var start = recipe
            if case .coreImage(let correction, let lut) = result {
                autoLUT = lut
                autoCorrection = correction
                start.auto = EditRecipe.Auto(modelId: CoreImageAutoCorrection.recipeModelID, modelVersion: CoreImageAutoCorrection.recipeModelVersion,
                                             weights: [0, 0, 0], guardrail: nil, strength: 1)
                DiagnosticTrace.note("auto: Core Image applied \(correction.filters.map(\.name)), omitted \(correction.omitted); \(correction.notes.joined(separator: "; "))")
            } else if case .lut(let lut) = result {
                // DEFERRED(D1): a trained model's id, version and weights belong in `auto` once one ships.
                autoLUT = lut
            }
            autoState = .applied
            start.auto.strength = 1
            if history.count == 1 {
                // Auto is the starting point, not an edit: it replaces the untouched initial entry.
                history = [start]
                historyIndex = 0
                editEpoch &+= 1
            } else {
                // Retry after edits: switching Auto on is one more step; the edits are kept.
                phase = .ready
                commit(start)
            }
        case .unavailable(let reason):
            autoLUT = nil
            autoState = reason.isRetryableFailure ? .failed : .unavailable
        }
        phase = .ready
        renderCommitted()
    }

    /// Develop failed › Retry.
    func retryAuto() {
        guard autoState == .failed, phase == .ready else { return }
        Task { [weak self] in await self?.develop() }
    }

    /// Develop failed › Continue with original: one step that records Auto off.
    func continueWithOriginal() {
        guard autoState == .failed else { return }
        autoState = .off
        renderCommitted()
        persistSession()
    }

    /// The Auto switch: only between applied and off (an unavailable or failed Auto cannot be
    /// switched on).
    func toggleAuto() {
        switch autoState {
        case .applied, .off:
            var next = recipe
            next.auto.strength = autoState == .applied ? 0 : 1
            autoState = autoState == .applied ? .off : .applied
            commit(next)
        case .unavailable:
            // No standing notice in the panel (owner amendment 2026-10-05): the explanation appears only when Auto is
            // tapped, and promises nothing.
            showToast("Automatic correction isn't available. Presets still work.")
        case .failed:
            return
        }
    }

    // MARK: - Develop Look

    /// Shows a preset (or none) without committing it: the ruler while dragging.
    func previewLook(_ preset: PresetPack.Preset?) {
        if dragStartedAt == nil { dragStartedAt = .now }
        render(recipeWithLook(preset), final: false, dragFrame: true)
    }

    /// The ruler drag ended or was cancelled: the next drag measures its first frame again.
    func endDragMeasurement() { dragStartedAt = nil }

    /// Bakes the drag LUTs of the stops next to the needle off the main actor, so the next crossed stop does not
    /// wait for its bake. Latest call wins; already-baked presets are skipped.
    func prefetchDragLooks(_ presets: [PresetPack.Preset]) {
        guard let cache = library.cache else { return }
        prefetchTask?.cancel()
        prefetchTask = Task.detached(priority: .utility) {
            for preset in presets where !cache.contains(lookVersion: preset.lookVersion) {
                if Task.isCancelled { return }
                _ = cache.lut(for: preset, dimension: LUT3D.contractDimension)
            }
        }
    }

    /// Abandons a preview and shows the committed recipe again.
    func endPreview() { renderCommitted() }

    /// Applies a preset, replacing only the Develop Look (one undo step). nil removes the Look.
    /// Re-selecting the applied preset changes nothing, so its Amount is kept.
    /// A ruler drag released where it started: back to the committed photo, nothing recorded.
    func cancelLookPreview() { renderCommitted() }

    func applyLook(_ preset: PresetPack.Preset?) {
        guard preset?.id != recipe.look?.lookId else { return renderCommitted() }
        if let preset { Self.logRenderingCoverage(of: preset) }
        commit(recipeWithLook(preset))
    }

    private static let coverageLogger = Logger(subsystem: "com.lightlylabs.lightly", category: "DevelopCoverage")

    /// Review evidence, not UI: what the applied preset renders, what the pack records as
    /// approximated or not rendered, and this port's own approximations of its operators.
    static func logRenderingCoverage(of preset: PresetPack.Preset) {
        let notes = DevelopCoverage.portApproximations(for: preset.recipe)
        coverageLogger.info("""
            \(preset.id, privacy: .public) "\(preset.displayName, privacy: .public)": operators \(preset.operators, privacy: .public); \
            completeness \(preset.completeness, privacy: .public); approximated \(preset.approximated, privacy: .public); \
            unsupported \(preset.unsupported, privacy: .public); notApplied \(preset.notApplied, privacy: .public); \
            iOS port \(notes, privacy: .public)
            """)
    }

    private func recipeWithLook(_ preset: PresetPack.Preset?) -> EditRecipe {
        var next = recipe
        if let preset {
            if preset.id == recipe.look?.lookId { return recipe }
            next.look = EditRecipe.LookRef(lookId: preset.id, lookVersion: preset.lookVersion,
                                           strength: amountMemory[preset.id] ?? 1)
        } else {
            next.look = nil
        }
        return next
    }

    /// Amount while the slider is dragged (preview, not a step).
    func previewAmount(_ amount: Double) {
        guard var look = recipe.look else { return }
        look.strength = Self.strength(forAmount: amount)
        var next = recipe
        next.look = look
        render(next, final: false)
    }

    /// Amount on release: one undo step.
    func commitAmount(_ amount: Double) {
        guard var look = recipe.look else { return }
        look.strength = Self.strength(forAmount: amount)
        amountMemory[look.lookId] = look.strength
        var next = recipe
        next.look = look
        commit(next)
    }

    static func strength(forAmount amount: Double) -> Double { min(max(amount.rounded(), 0), 100) / 100 }

    // MARK: - Background (slice 3)

    /// Starts subject separation for this photo ("Finding the subject…") once, and depth only when the operation
    /// shown needs it (Focus & Blur). Change background and Refine edges never start the depth model.
    func analyseSubjectIfNeeded(needsDepth: Bool) {
        DiagnosticTrace.note("background: opened, subject \(subjectState), depth \(depthState), needs depth \(needsDepth)")
        if subjectState == .notStarted { startSubjectMatte() }
        // Never restarts a cancelled run: reopening the panel must not undo Cancel; the next Background edit does.
        if needsDepth, depthState == .notStarted { startDepth() }
    }

    /// Starts depth if nothing has started it (or a Cancel stopped it): Focus & Blur, or Blur with no clear subject.
    func ensureDepth() {
        if depthState == .notStarted || depthState == .cancelled { startDepth() }
    }

    /// Try again: reruns only what failed.
    func retrySubjectSeparation() {
        if subjectState == .failed { startSubjectMatte() }
        if depthState == .failed { startDepth() }
    }

    /// Cancel (prototype `cancelOp`): the panel returns with nothing changed ("Cancelled · nothing changed"); the
    /// committed edit and its preview stay. Whatever already finished (e.g. the subject outline) is kept. Results of
    /// the cancelled work that arrive later are dropped (finish* only accept a pending state).
    func cancelSubjectSeparation() {
        var cancelled = false
        if subjectState == .separating {
            subjectTask?.cancel()
            subjectTask = nil
            subjectState = .cancelled
            cancelled = true
        }
        if depthState == .estimating {
            depthTask?.cancel()
            depthTask = nil
            depthState = .cancelled
            cancelled = true
        }
        guard cancelled else { return }
        DiagnosticTrace.note("subject: cancelled by the person")
        renderCommitted()
        showToast("Cancelled · nothing changed")
    }

    /// After Cancel, the next Background edit starts the cancelled analysis again (prototype: the operation runs
    /// when the person asks for an effect), never a view refresh or re-entering the tool.
    private func resumeCancelledAnalysis() {
        if subjectState == .cancelled { startSubjectMatte() }
        // Depth only when the edit now blurs; Focus & Blur's panel asks for it itself (ensureDepth).
        if recipe.tools.background.focus.blur > 0 { ensureDepth() }
    }

    // Previously the matte, depth and the person matte were awaited together, so one slow
    // analysis (e.g. the depth model compiling on first use) held the whole Background tool on
    // "Finding the subject…". Each now finishes on its own; the person matte is Portrait's
    // (ensurePersonMatte) and is no longer computed here.
    private func startSubjectMatte() {
        guard let sceneAnalyser else { subjectState = .failed; return }
        subjectState = .separating
        subjectGeneration += 1
        let generation = subjectGeneration
        let image = originalPreview
        let detectedFaces = people?.faces ?? []
        let faces = detectedFaces.map(\.box)
        let hairSource = photo.image
        DiagnosticTrace.note("subject: matte started \(image.width)x\(image.height), faces \(faces.count)")
        let awake = KeepAwake.begin("subject separation")
        subjectTask = Task { [weak self] in
            defer { KeepAwake.end(awake) }
            let started = ContinuousClock.now
            do {
                var matte = try await Self.traced("subject matte", started) { try await sceneAnalyser.subjectMatte(for: image) }
                try Task.checkCancellation()
                // Hair detail: only for a photo with faces (see SubjectMatte.refinedAtHair).
                if let instance = matte, !faces.isEmpty,
                   let person = try await Self.traced("hair detail matte", started, { await sceneAnalyser.hairDetailMatte(for: image) }) {
                    try Task.checkCancellation()
                    let initialHair = await Task.detached(priority: .userInitiated) {
                        SubjectMatte.refinedAtHair(instance: instance.matte, person: person, faces: faces)
                    }.value
                    let refined = try await Self.traced("local hair coverage", started) {
                        try await sceneAnalyser.refineHairCoverage(for: hairSource, prior: initialHair, faces: detectedFaces)
                    }
                    #if DEBUG
                    // Device check of the hair refinement: the three mattes behind this Change background.
                    let stamp = DiagnosticTrace.stamp
                    DiagnosticTrace.evidence(matte: instance.matte, named: "matte-\(stamp)-instance.png")
                    DiagnosticTrace.evidence(matte: person, named: "matte-\(stamp)-person.png")
                    DiagnosticTrace.evidence(matte: refined, named: "matte-\(stamp)-refined.png")
                    #endif
                    matte = SubjectMatte(matte: refined, model: SubjectMatte.hairRefinedModel)
                }
                try Task.checkCancellation()
                self?.finishSubjectMatte(matte, generation: generation)
            } catch {
                guard !Task.isCancelled, let self, !self.isClosed, self.subjectState == .separating,
                      self.subjectGeneration == generation else { return }
                self.subjectState = .failed
            }
        }
    }

    private func startDepth() {
        guard let sceneAnalyser else { depthState = .failed; return }
        depthState = .estimating
        depthGeneration += 1
        let generation = depthGeneration
        let image = originalPreview
        let data = photo.originalData
        DiagnosticTrace.note("subject: depth started")
        let awake = KeepAwake.begin("depth")
        depthTask = Task { [weak self] in
            defer { KeepAwake.end(awake) }
            let started = ContinuousClock.now
            do {
                let disparity = try await Self.traced("depth", started) { try await sceneAnalyser.disparity(for: image, originalData: data) }
                try Task.checkCancellation()
                self?.finishDepth(disparity, generation: generation)
            } catch {
                guard !Task.isCancelled, let self, !self.isClosed, self.depthState == .estimating,
                      self.depthGeneration == generation else { return }
                self.depthState = .failed
            }
        }
    }

    /// Runs one stage of subject separation and logs when it ends and how (DiagnosticTrace).
    private static func traced<T: Sendable>(_ stage: String, _ started: ContinuousClock.Instant, _ work: @Sendable () async throws -> T) async throws -> T {
        do {
            let value = try await work()
            DiagnosticTrace.note("subject: \(stage) done at \((ContinuousClock.now - started).components.seconds) s")
            return value
        } catch {
            DiagnosticTrace.note("subject: \(stage) failed at \((ContinuousClock.now - started).components.seconds) s: \(String(describing: error))")
            throw error
        }
    }

    private func finishSubjectMatte(_ matte: SubjectMatte?, generation: Int) {
        // Only the pending separation that started this work accepts its result: a cancelled one's late result
        // is dropped, also after a newer run has started.
        guard !isClosed, subjectState == .separating, generation == subjectGeneration else { return }
        sceneCache.subject = matte
        sceneCache.subjectAnalysed = true
        for name in BackgroundPanelModel.bundledImages where sceneCache.replacementImages[name] == nil {
            sceneCache.replacementImages[name] = BundledBackgrounds.image(name)
        }
        matteImage = matte.flatMap { Self.maskImage($0.matte) }
        if let matte {
            let centroid = RefocusRenderer.defaultTarget(matte: matte.matte, faces: people?.faces ?? [])
            defaultFocusTarget = (Double(centroid.x), Double(centroid.y))
        }
        subjectState = matte == nil ? .noSubject : .ready
        analysisRevision += 1
        persistSession()
        refreshCurrentPreview()
    }

    private func finishDepth(_ disparity: DisparityMap, generation: Int) {
        guard !isClosed, depthState == .estimating, generation == depthGeneration else { return }
        sceneCache.disparity = disparity
        depthState = .ready
        analysisRevision += 1
        persistSession()
        refreshCurrentPreview()
    }

    /// A slider moving: preview only.
    func previewBackground(_ change: (inout EditRecipe.Background) -> Void) {
        var next = recipe
        change(&next.tools.background)
        if next.tools.background.focus.blur > 0 { ensureDepth() }
        render(next, final: false)
    }

    /// One undo step. The first Background edit records which model results it was made with.
    func commitBackground(_ change: (inout EditRecipe.Background) -> Void) {
        var next = recipe
        change(&next.tools.background)
        recordDerivedResults(in: &next.tools.background)
        commit(next)
        resumeCancelledAnalysis()
        if recipe.tools.background.focus.blur > 0 { ensureDepth() }
    }

    /// Tap the photo to set focus (source coordinates).
    /// Tap the photo to set focus (source coordinates). The focal plane the tap resolves to is
    /// stored as `depth.focusDepth = 1 − d_f` (rendering-v2 revision 1, G4), so preview and export
    /// render the same plane; it is resolved off the main actor, then committed as one step.
    func setFocusTarget(x: Double, y: Double) {
        let point = EditRecipe.Point(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        guard let disparity = sceneCache.disparity?.disparity else {
            commitBackground { $0.focus.target = point }
            return
        }
        var matte = sceneCache.subject?.matte
        if var m = matte {
            BackgroundStage.applyRefinements(recipe.tools.background.subject.refinements, to: &m)
            matte = m
        }
        let resolvedMatte = matte
        focusTask?.cancel()
        focusTask = Task { [weak self] in
            let focal = await Task.detached(priority: .userInitiated) {
                RefocusRenderer.focalDisparityAtTap(disparity: disparity, matte: resolvedMatte, x: Float(point.x), y: Float(point.y))
            }.value
            guard let self, !Task.isCancelled, !self.isClosed else { return }
            self.commitBackground {
                $0.focus.target = point
                $0.focus.depth.focusDepth = Double(min(max(1 - focal, 0), 1))
            }
        }
    }

    /// Refine edges: one brush stroke, one undo step.
    func addRefinement(_ stroke: EditRecipe.RefineStroke) {
        commitBackground { $0.subject.refinements.append(stroke) }
    }

    private func recordDerivedResults(in background: inout EditRecipe.Background) {
        if background.subject.matte == nil, let matte = sceneCache.subject {
            background.subject.matte = Self.derivedRef(matte.matte, model: matte.model)
        }
        if let disparity = sceneCache.disparity, background.focus.depth.map == nil {
            background.focus.depth.source = disparity.source
            background.focus.depth.map = Self.derivedRef(disparity.disparity, model: disparity.model)
        }
    }

    /// Hex SHA-256 (trace identities of the source and saved bytes; never their content).
    nonisolated static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func derivedRef(_ image: FloatImage, model: EditRecipe.ModelRef) -> EditRecipe.DerivedRef {
        let bytes = image.data.withUnsafeBufferPointer { Data(buffer: $0) }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return EditRecipe.DerivedRef(sha256: digest, model: model, width: image.width, height: image.height)
    }

    /// The refine-edges tint's matte on the displayed frame: through Edit's geometry when there is any.
    var displayMatteImage: CGImage? {
        guard let matte = sceneCache.subject?.matte else { return matteImage }
        let geometry = recipe.tools.edit.geometry
        guard geometry != GeometryTransform.neutralGeometry else { return matteImage }
        if let cached = warpedMatte, cached.geometry == geometry { return cached.image }
        let transform = GeometryTransform(geometry, sourceWidth: matte.width, sourceHeight: matte.height)
        let warped = transform.render(Self.maskBytes(matte), width: matte.width, height: matte.height)
        let image = Self.alphaImage(warped.pixels, width: warped.width, height: warped.height)
        warpedMatte = (geometry, image)
        return image
    }
    @ObservationIgnored private var warpedMatte: (geometry: EditRecipe.Geometry, image: CGImage?)?

    /// A matte as an alpha image (for SwiftUI masking).
    static func maskImage(_ matte: FloatImage) -> CGImage? {
        alphaImage(maskBytes(matte), width: matte.width, height: matte.height)
    }

    private static func maskBytes(_ matte: FloatImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: matte.pixelCount * 4)
        for i in 0..<matte.pixelCount {
            let a = UInt8(min(max(matte.data[i], 0), 1) * 255)
            bytes[i * 4] = a; bytes[i * 4 + 1] = a; bytes[i * 4 + 2] = a; bytes[i * 4 + 3] = a
        }
        return bytes
    }

    private static func alphaImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: ColorPipeline.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - Portrait (slice 3)

    func previewPortrait(_ change: (inout EditRecipe.Portrait) -> Void) {
        var next = recipe
        change(&next.tools.portrait)
        ensurePersonMatte()
        render(next, final: false)
    }

    func commitPortrait(_ change: (inout EditRecipe.Portrait) -> Void) {
        var next = recipe
        change(&next.tools.portrait)
        ensurePersonMatte()
        commit(next)
    }

    /// Hair edits use the person matte; computed once when Portrait is first used.
    private func ensurePersonMatte() {
        guard sceneCache.personMatte == nil, let sceneAnalyser else { return }
        let image = originalPreview
        guard personMatteTask == nil else { return }
        // Tracked so a closed session's segmentation is awaited (capture sessions) and not left
        // running on the CPU behind the next screen.
        personMatteTask = Task { [weak self] in
            let matte = await sceneAnalyser.personMatte(for: image)
            guard let self, !self.isClosed, self.sceneCache.personMatte == nil else { return }
            self.sceneCache.personMatte = matte
            self.analysisRevision += 1
            self.persistSession()
            self.renderCommitted()
        }
    }

    // MARK: - Edit and Effects (slice 4)

    /// Edit › Remove's operation (approved `ed-removing`, `ed-remove-failed`).
    enum RemoveState: Equatable {
        case idle
        /// "Removing…", cancellable.
        case removing
        /// "Couldn't remove that area." with Try again (also when the model is missing: never a
        /// substitute fill).
        case failed
    }

    private(set) var removeState: RemoveState = .idle
    /// The stroke being removed, or the one that failed (drawn on the photo until it is applied,
    /// retried or replaced).
    private(set) var pendingRemoveStroke: EditRecipe.RemoveStroke?
    /// Remove patches by digest; written beside the edit when the app gives a directory.
    @ObservationIgnored let removePatches: RemovePatchStore
    @ObservationIgnored private var removeTask: Task<Void, Never>?
    @ObservationIgnored private var inpainter: (any Inpainting)?
    @ObservationIgnored private var inpainterLoaded = false

    /// The geometry of the committed recipe for the photo (marks and touches map through it); uncropped while Crop is
    /// being edited, as the stage then shows.
    var geometryTransform: GeometryTransform {
        let geometry = isCropEditing ? Self.uncropped(recipe).tools.edit.geometry : recipe.tools.edit.geometry
        return GeometryTransform(geometry, sourceWidth: photo.image.width, sourceHeight: photo.image.height)
    }

    /// Edit › Crop is open (owner amendment 2026-10-05, free crop): previews show the straightened frame uncropped, and the
    /// crop rectangle is drawn over it in that frame's fractions; Border and Watermark are left out of those previews so
    /// the rectangle sits on the photo. Save copy and every other tool use the committed, cropped recipe.
    var isCropEditing = false {
        didSet { if oldValue != isCropEditing { renderCommitted() } }
    }

    /// `recipe` as the crop editor shows it: no crop, no border, no watermark.
    nonisolated static func uncropped(_ recipe: EditRecipe) -> EditRecipe {
        var shown = recipe
        shown.tools.edit.geometry.cropRect = .init(x: 0, y: 0, width: 1, height: 1)
        shown.tools.border.type = .none
        shown.tools.watermark.type = .none
        return shown
    }

    /// A slider or drag moving: preview only.
    func previewEdit(_ change: (inout EditRecipe.Edit) -> Void) {
        var next = recipe
        change(&next.tools.edit)
        render(next, final: false)
    }

    /// One undo step.
    func commitEdit(_ change: (inout EditRecipe.Edit) -> Void) {
        var next = recipe
        change(&next.tools.edit)
        commit(next)
    }

    func previewEffects(_ change: (inout EditRecipe.Effects) -> Void) {
        var next = recipe
        change(&next.tools.effects)
        render(next, final: false)
    }

    func commitEffects(_ change: (inout EditRecipe.Effects) -> Void) {
        var next = recipe
        change(&next.tools.effects)
        commit(next)
    }

    // MARK: - Selective Colour

    /// Keeps the colour under a tap at (`frameX`, `frameY`), fractions of the displayed frame. The colour is
    /// sampled from Selective Colour's own input (the frame before it, at the preview size), not from the
    /// photo on screen, which may already be black and white there. One undo step.
    ///
    /// Sampling is asynchronous, so a result can land after the person has moved on. It is kept only if
    /// nothing but picks changed the edit since the tap (`editEpoch`: Clear, a removal, a slider, Undo, Redo
    /// or any other edit discards it) and this session is still open; picks land in tap order, and the
    /// eight-colour limit counts picks still sampling.
    func pickSelectiveColour(frameX: Double, frameY: Double) {
        guard phase == .ready, let base = previewBase, let renderer = library.renderer, let cache = library.cache,
              recipe.tools.effects.selectiveColour.colours.count + pendingPicks < Self.maximumKeptColours else { return }
        var job = committedJob()
        job.layeredCap = LayeredStages.previewCap
        job.stopBeforeSelectiveColour = true
        let source = geometryTransform.isIdentity ? CGPoint(x: frameX, y: frameY)
            : geometryTransform.source(fromFrame: CGPoint(x: frameX, y: frameY))
        let x = min(max(Double(source.x), 0), 1), y = min(max(Double(source.y), 0), 1)
        let epoch = editEpoch
        let previous = pickTask
        pendingPicks += 1
        let gate = pickSamplingGate
        pickTask = Task { [weak self] in
            await gate?()
            let lab = try? await Task.detached(priority: .userInitiated) {
                // Stages up to Selective Colour only: no border, no watermark.
                let frame = try Self.renderFrameBeforeBorder(job, base: base.pixels, width: base.width, height: base.height,
                                                             renderer: renderer, cache: cache)
                return SelectiveColourEvaluator.sample(frame.pixels, width: frame.width, height: frame.height,
                                                       xFraction: frameX, yFraction: frameY)
            }.value
            await previous?.value   // land in tap order
            guard let self else { return }
            self.pendingPicks -= 1
            guard let lab, !self.isClosed, self.editEpoch == epoch,
                  self.recipe.tools.effects.selectiveColour.colours.count < Self.maximumKeptColours else { return }
            self.commitPick { $0.selectiveColour.colours.append(.init(oklab: lab, x: x, y: y)) }
        }
    }

    /// A pick's result: one undo step that, unlike every other edit, leaves `editEpoch` alone, so picks
    /// still sampling are kept.
    private func commitPick(_ change: (inout EditRecipe.Effects) -> Void) {
        var next = recipe
        change(&next.tools.effects)
        committingPick = true
        commit(next)
        committingPick = false
    }

    /// Removes one kept colour (the × on its dot). One undo step.
    func removeSelectiveColour(at index: Int) {
        editEpoch &+= 1   // a pick still sampling no longer applies
        guard recipe.tools.effects.selectiveColour.colours.indices.contains(index) else { return }
        commitEffects { $0.selectiveColour.colours.remove(at: index) }
    }

    /// Clear: no kept colours, Range and Strength back to their defaults. One undo step.
    func clearSelectiveColour() {
        editEpoch &+= 1   // even with nothing kept yet, a pick still sampling no longer applies
        guard recipe.tools.effects.selectiveColour != .none else { return }
        commitEffects { $0.selectiveColour = .none }
    }

    /// The sampling render of the latest pick (awaited by `settleRendering`).
    @ObservationIgnored private var pickTask: Task<Void, Never>?
    /// Tests only: awaited before a pick samples, so a test can hold a pick "still sampling" while it acts.
    @ObservationIgnored var pickSamplingGate: (@Sendable () async -> Void)?
    /// Picks still sampling (they count towards the eight-colour limit).
    @ObservationIgnored private var pendingPicks = 0
    /// Advances on every change of the edit except a pick's own result: a pick sampled before it is stale.
    @ObservationIgnored private(set) var editEpoch: UInt64 = 0
    @ObservationIgnored private var committingPick = false

    /// edit-recipe-v1 `selectiveColour.colours` maxItems.
    static let maximumKeptColours = 8

    func previewBorder(_ change: (inout EditRecipe.Border) -> Void) {
        var next = recipe
        change(&next.tools.border)
        render(next, final: false)
    }

    /// One undo step.
    func commitBorder(_ change: (inout EditRecipe.Border) -> Void) {
        var next = recipe
        change(&next.tools.border)
        commit(next)
    }

    /// A slider or drag moving: preview only.
    func previewWatermark(_ change: (inout EditRecipe.Watermark) -> Void) {
        var next = recipe
        change(&next.tools.watermark)
        render(next, final: false)
    }

    /// One undo step.
    func commitWatermark(_ change: (inout EditRecipe.Watermark) -> Void) {
        var next = recipe
        change(&next.tools.watermark)
        commit(next)
    }

    /// Crop › an aspect: a fixed aspect takes the largest centred rect of that shape; Original
    /// resets the rect; Free keeps the current one (prototype `set:edit.aspect`).
    func setCropAspect(_ aspect: EditRecipe.Geometry.Aspect) {
        commitEdit { edit in
            edit.geometry.cropAspect = aspect
            edit.geometry.cropRect = Self.cropRect(for: aspect, geometry: edit.geometry, photo: photo)
        }
    }

    nonisolated static func cropRect(for aspect: EditRecipe.Geometry.Aspect, geometry: EditRecipe.Geometry,
                                     photo: SelectedPhoto) -> EditRecipe.Rect {
        switch aspect {
        case .original: return .init(x: 0, y: 0, width: 1, height: 1)
        case .free: return geometry.cropRect
        default:
            let turned = GeometryTransform.turnedSize(geometry, sourceWidth: photo.image.width, sourceHeight: photo.image.height)
            return GeometryTransform.centredRect(aspect: GeometryTransform.ratio(aspect) ?? 1, width: turned.width, height: turned.height)
        }
    }

    /// Rotate left (−1) or right (+1): one quarter turn. A fixed crop aspect keeps its shape in
    /// the turned frame, so its rect is laid out again.
    func rotate(quarterTurns delta: Int) {
        commitEdit { edit in
            edit.geometry.quarterTurns = ((edit.geometry.quarterTurns + delta) % 4 + 4) % 4
            if GeometryTransform.ratio(edit.geometry.cropAspect) != nil {
                edit.geometry.cropRect = Self.cropRect(for: edit.geometry.cropAspect, geometry: edit.geometry, photo: photo)
            } else if edit.geometry.cropAspect == .free {
                // A free rect turns with the photo.
                let r = edit.geometry.cropRect
                edit.geometry.cropRect = delta > 0 ? .init(x: 1 - r.y - r.height, y: r.x, width: r.height, height: r.width)
                                                   : .init(x: r.y, y: 1 - r.x - r.width, width: r.height, height: r.width)
            }
        }
    }

    /// Remove: brushing a stroke (source coordinates) starts removing it. It becomes one undo step
    /// once its patch exists; cancelled or failed, nothing changes.
    func removeStroke(points: [EditRecipe.Point], radius: Double) {
        guard removeState != .removing, !points.isEmpty else { return }
        let stroke = EditRecipe.RemoveStroke(radius: min(max(radius, 0.001), 0.5), points: points, status: .applied, patch: nil)
        pendingRemoveStroke = stroke
        runRemove(stroke)
    }

    /// Remove failed › Try again: the same stroke once more.
    func retryRemove() {
        guard removeState == .failed, let stroke = pendingRemoveStroke else { return }
        runRemove(stroke)
    }

    /// Removing › Cancel: nothing changes ("Cancelled · nothing changed"). A model call already
    /// running finishes in the background and is discarded (Core ML cannot interrupt it).
    func cancelRemove() {
        guard removeState == .removing else { return }
        removeTask?.cancel()
        removeTask = nil
        removeState = .idle
        pendingRemoveStroke = nil
        showToast("Cancelled · nothing changed")
    }

    /// Undo stroke: the last applied stroke goes (one undo step).
    func undoStroke() {
        guard !recipe.tools.edit.remove.strokes.isEmpty else { return }
        commitEdit { $0.remove.strokes.removeLast() }
    }

    private func runRemove(_ stroke: EditRecipe.RemoveStroke) {
        removeState = .removing
        let image = photo.image
        let earlier = removePatches.patches(for: recipe.tools.edit.remove.strokes)
        let loader = inpainterLoader
        let alreadyLoaded = inpainterLoaded ? inpainter : nil
        let needsLoad = !inpainterLoaded
        let awake = KeepAwake.begin("remove")
        removeTask = Task { [weak self] in
            defer { KeepAwake.end(awake) }
            do {
                let work = Task.detached(priority: .userInitiated) { () -> (patch: RemovePatch, engine: any Inpainting) in
                    // The model loads on first use (seconds for 103 MB), off the main actor.
                    guard let engine = needsLoad ? loader() : alreadyLoaded else { throw RemoveEngine.Failure.modelUnavailable }
                    // Only bands of the stroke's context window are drawn (no full-resolution copy of the
                    // photo per stroke: 192 MB at 48 MP); the same patch as the whole-buffer route.
                    let patch = try await RemoveEngine.patch(for: stroke, image: image, earlier: earlier, inpainter: engine)
                    return (patch, engine)
                }
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                self?.finishRemove(stroke, patch: result.patch, engine: result.engine)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, !self.isClosed else { return }
                if case RemoveEngine.Failure.modelUnavailable = error { self.inpainterLoaded = true; self.inpainter = nil }
                self.removeState = .failed
            }
        }
    }

    /// Save copy releases the Remove model when no stroke is being removed (2026-10-07, iPhone 11 Pro Max: Save copy
    /// of a 48 MP photo peaked at 956 MB with the model loaded, 694 MB without). The fills are kept (RemovePatchStore);
    /// the next stroke loads the model again (`inpainterLoaded` false).
    private func releaseRemoveModelIfIdle() {
        guard removeState != .removing, inpainterLoaded, inpainter != nil else { return }
        inpainter = nil
        inpainterLoaded = false
        DiagnosticTrace.note("remove: model released before save copy")
    }

    private func finishRemove(_ stroke: EditRecipe.RemoveStroke, patch: RemovePatch, engine: any Inpainting) {
        guard !isClosed, removeState == .removing else { return }
        inpainter = engine
        inpainterLoaded = true
        var applied = stroke
        let digest = removePatches.add(patch)
        applied.patch = EditRecipe.DerivedRef(sha256: digest, model: engine.model, width: patch.width, height: patch.height)
        removeState = .idle
        pendingRemoveStroke = nil
        commitEdit { $0.remove.strokes.append(applied) }
    }

    /// The preset's own finishing, for the Effects notice ("already includes its own grain").
    var appliedPresetFinishing: PresetRecipe.Finishing? {
        guard let preset = appliedPreset, (recipe.look?.strength ?? 0) > 0 else { return nil }
        return preset.recipe.finishing
    }

    // MARK: - History

    /// One undoable operation; cached assets stay available to Undo.
    func resetEdits(section: String = "all", adjustment: String? = nil) {
        if section == "all" || section == "edit" { cancelRemove() }
        let next = recipeAfterReset(section: section, adjustment: adjustment)
        if section == "all", autoState == .applied { autoState = .off }
        commit(next)
    }

    func canReset(section: String, adjustment: String? = nil) -> Bool {
        if section == "all" {
            return autoState == .applied || recipe.look != nil ||
                ["effects", "edit", "background", "portrait", "watermark", "border"].contains { canReset(section: $0) }
        }
        if section == "background", adjustment == nil {
            return recipe.tools.background.replacement != nil || recipe.tools.background.focus.blur > 0 || !recipe.tools.background.subject.refinements.isEmpty
        }
        if section == "portrait", adjustment == nil {
            return recipe.tools.portrait.faces.contains { PortraitPanelModel(session: self).changeCount(for: $0) > 0 }
        }
        if section == "watermark" { return recipe.tools.watermark.type != .none }
        if section == "border" { return recipe.tools.border.type != .none }
        return recipeAfterReset(section: section, adjustment: adjustment) != recipe
    }

    private func recipeAfterReset(section: String, adjustment: String?) -> EditRecipe {
        var next = recipe
        let neutral = EditRecipe.Tools.neutral(grainSeed: recipe.tools.effects.grain.seed)
        switch section {
        case "all":
            next.look = nil; next.auto.strength = 0; next.tools = neutral
        case "develop": next.look = nil
        case "effects":
            switch adjustment {
            case "leak": next.tools.effects.lightLeak = neutral.effects.lightLeak
            case "grain": next.tools.effects.grain = neutral.effects.grain
            case "vignette": next.tools.effects.vignette = neutral.effects.vignette
            case "selective": next.tools.effects.selectiveColour = .none
            default: next.tools.effects = neutral.effects
            }
        case "edit":
            switch adjustment {
            case "crop": next.tools.edit.geometry.cropRect = neutral.edit.geometry.cropRect; next.tools.edit.geometry.cropAspect = .original
            case "rotate": next.tools.edit.geometry.quarterTurns = 0; next.tools.edit.geometry.flipHorizontal = false; next.tools.edit.geometry.flipVertical = false
            case "straighten": next.tools.edit.geometry.straighten = 0
            case "perspective": next.tools.edit.geometry.perspectiveHorizontal = 0; next.tools.edit.geometry.perspectiveVertical = 0
            case "adjust": next.tools.edit.adjust = neutral.edit.adjust
            case "remove": next.tools.edit.remove = neutral.edit.remove
            default: next.tools.edit = neutral.edit
            }
        case "background":
            switch adjustment {
            case "focus": next.tools.background.focus = neutral.background.focus
            case "change": next.tools.background.replacement = nil
            case "refine": next.tools.background.subject.refinements = []
            default: next.tools.background = neutral.background
            }
        case "portrait":
            if let adjustment {
                let face = PortraitPanelModel.neutral(for: nil)
                for i in next.tools.portrait.faces.indices {
                    switch adjustment {
                    case "skin": next.tools.portrait.faces[i].skin = face.skin
                    case "under": next.tools.portrait.faces[i].underEye = face.underEye
                    case "eyes": next.tools.portrait.faces[i].eyes = face.eyes
                    case "teeth": next.tools.portrait.faces[i].teeth = face.teeth
                    case "hair": next.tools.portrait.faces[i].hair = face.hair
                    default: break
                    }
                }
            } else { next.tools.portrait = neutral.portrait }
        case "watermark": next.tools.watermark = neutral.watermark
        case "border": next.tools.border = neutral.border
        default: return recipe
        }
        return next
    }

    func undo() {
        guard canUndo else { return }
        historyIndex -= 1
        afterHistoryMove()
    }

    func redo() {
        guard canRedo else { return }
        historyIndex += 1
        afterHistoryMove()
    }

    private func afterHistoryMove() {
        editEpoch &+= 1   // Undo and Redo make any pick still sampling stale
        // The Auto switch follows the recipe it belongs to.
        if autoState == .applied || autoState == .off { autoState = recipe.auto.strength > 0 ? .applied : .off }
        hasUnsavedEdits = true
        if case .saved = saveState { saveState = .idle }
        renderCommitted()
        persistSession()
    }

    /// Records `next` as one undo step (nothing when it equals the committed recipe).
    private func commit(_ next: EditRecipe) {
        guard next != recipe else { return renderCommitted() }
        if !committingPick { editEpoch &+= 1 }
        var entry = next
        entry.revision = (history.map(\.revision).max() ?? 0) + 1
        history.removeSubrange((historyIndex + 1)...)
        history.append(entry)
        if history.count > Self.historyCapacity { history.removeFirst(history.count - Self.historyCapacity) }
        historyIndex = history.count - 1
        hasUnsavedEdits = true
        if case .saved = saveState { saveState = .idle }
        renderCommitted()
        persistSession()
    }

    // MARK: - Compare

    func beginCompare() { isShowingOriginal = true }
    func endCompare() { isShowingOriginal = false }
    func toggleCompare() { isShowingOriginal.toggle() }

    var originalImage: CGImage { originalPreview }

    @ObservationIgnored private var thumbnailImages: [String: CGImage] = [:]
    @ObservationIgnored private var thumbnailContext: Data?
    var thumbnailKey: Data {
        var r = recipe; r.look = nil; r.revision = 0
        return EditRecipeCodec.encode(r)
    }

    /// Visible tiles only; exact pipeline on a small source, with a bounded per-photo cache.
    func presetThumbnail(_ preset: PresetPack.Preset?) async -> CGImage? {
        let context = thumbnailKey, key = preset?.lookVersion ?? "original"
        if thumbnailContext != context { thumbnailImages.removeAll(); thumbnailContext = context }
        if let image = thumbnailImages[key] { return image }
        guard !isClosed, saveState == .idle, let renderer = library.renderer, let cache = library.cache,
              let small = PhotoColours.small(originalPreview, edge: 200), let pixels = try? MetalLUTRenderer.rgba8Bytes(of: small) else { return nil }
        var job = RenderJob(look: preset, strength: 1, autoLUT: autoState == .applied ? autoLUT : nil,
                            autoStrength: recipe.auto.strength, includePixelStages: true, generation: 0)
        job.layered = layeredInputs(for: recipe); job.layeredCap = 200
        attachEditAndEffects(recipe, to: &job)
        let snapshot = job
        let result = try? await PresetThumbnailWorker.shared.run {
            let frame = try Self.renderPixels(snapshot, base: pixels, width: small.width, height: small.height, renderer: renderer, cache: cache)
            return try MetalLUTRenderer.makeImage(rgba8: frame.pixels, width: frame.width, height: frame.height)
        }
        guard !Task.isCancelled, !isClosed, context == thumbnailKey else { return nil }
        if let result { if thumbnailImages.count >= 48 { thumbnailImages.removeAll() }; thumbnailImages[key] = result }
        return result
    }

    // MARK: - Rendering

    private struct RenderJob: Sendable {
        let look: PresetPack.Preset?
        let strength: Double
        let autoLUT: LUT3D?
        let autoStrength: Double
        var includePixelStages: Bool
        let generation: UInt64
        /// A final render's fast frame: when it lands (and nothing newer was asked for), the full
        /// frame is requested. Queuing both at once would let the full frame replace the waiting
        /// fast one, and the photo would lag the release by a whole spatial render.
        var prefixKey: PreviewPrefixKey?
        var followUpWithFullFrame = false
        /// A ruler drag's frame (2026-10-06): the reduced preview base and the coarse drag LUT, so every newly crossed
        /// stop renders while the finger moves. The settled selection renders at normal preview quality.
        var dragFrame = false
        var lutDimension: Int { LUT3D.contractDimension }
        /// Background and Portrait (stages 7–9), when the recipe uses them.
        var layered: LayeredStages.Inputs?
        /// Working-resolution cap for Focus & Blur (LayeredStages).
        var layeredCap = LayeredStages.previewCap
        /// Edit (geometry, Adjust, Remove) and Effects (slice 4).
        var edit: EditRecipe.Edit = EditRecipe.Tools.neutral(grainSeed: 0).edit
        var effects: EditRecipe.Effects = EditRecipe.Tools.neutral(grainSeed: 0).effects
        /// The applied Remove strokes' patches, in order (full-resolution source pixels).
        var removePatches: [RemovePatch] = []
        /// Save copy has already composited `removePatches` into the base it passes (its own buffer, in place), so the
        /// render must not composite them again. Previews leave this false: their base is shared and never mutated.
        var removePatchesInBase = false
        /// Border (stage 11) and watermark (stage 12), applied to every frame, preview and export alike.
        var border: EditRecipe.Border = EditRecipe.Tools.neutral(grainSeed: 0).border
        var watermark: EditRecipe.Watermark = EditRecipe.Tools.neutral(grainSeed: 0).watermark
        /// The watermark's resolved content; nil draws nothing (no watermark, or a saved signature
        /// that is missing or changed: rendered without it, never substituted).
        var watermarkContent: WatermarkStage.Content?
        /// The displayed photo's size in points when the job was made (nil: not laid out yet).
        var displayPhotoSize: CGSize?

        /// True when a slice-4 stage changes pixels; otherwise the slice-2/3 path runs unchanged.
        var usesEditOrEffects: Bool {
            edit.geometry != GeometryTransform.neutralGeometry || AdjustStage.hasColour(edit.adjust)
                || AdjustStage.hasDetail(edit.adjust) || !removePatches.isEmpty || Self.hasUserEffects(effects)
        }

        static func hasUserEffects(_ effects: EditRecipe.Effects) -> Bool {
            effects.lightLeak.enabled || effects.grain.enabled || effects.vignette.enabled || !effects.selectiveColour.colours.isEmpty
        }

        /// Stop at Selective Colour's input (the frame after geometry, with the light leak): what a pick samples
        /// (rendering-v2 §6 Selective colour). Never shown.
        var stopBeforeSelectiveColour = false
    }

    /// A rendered frame; geometry can change its size.
    private struct RenderedFrame: Sendable {
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    /// One bounded preview cache, before Effects. Slider changes reuse the exact completed
    /// upstream pixels; they never re-run subject compositing or substitute a cheaper image.
    private struct PreviewPrefixKey: Equatable, Sendable {
        var recipe: EditRecipe
        var sceneGeneration: UInt64
        var autoLUT: LUT3D?
        var displaySize: CGSize?
    }
    private final class PreviewPrefixCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entry: (PreviewPrefixKey, RenderedFrame)?
        func get(_ key: PreviewPrefixKey?) -> RenderedFrame? {
            lock.withLock { guard let key, let entry, entry.0 == key else { return nil }; return entry.1 }
        }
        func put(_ frame: RenderedFrame, key: PreviewPrefixKey?) {
            lock.withLock { if let key { entry = (key, frame) } }
        }
    }

    private func makeScheduler() {
        guard let base = previewBase, let renderer = library.renderer, let cache = library.cache else { return }
        let prefixCache = PreviewPrefixCache()
        scheduler = LatestWinsRenderScheduler(supersedesRunning: { new, running in new.dragFrame && !running.dragFrame }) { job in
            let source = base
            let frame = try Self.renderPixels(job, base: source.pixels, width: source.width, height: source.height,
                                              renderer: renderer, cache: cache, prefixCache: prefixCache)
            return try MetalLUTRenderer.makeImage(rgba8: frame.pixels, width: frame.width, height: frame.height)
        }
    }

    /// Every stage for a job, on any thread.
    ///
    /// Without Edit or Effects edits this is the slice-2/3 path, unchanged: Auto (1), the Look
    /// (2, 3), Background and Portrait (7–9), the preset's finishing (10). With them:
    /// Remove patches → Auto (1) → Look (2, 3) → Adjust (5) → Background and Portrait (7–9) →
    /// geometry (4) → Effects with the preset's finishing (10).
    // Stage order of rendering-v2 revision 2 (§1, C1 and C2, docs/v1/contract-fixes-2.md), which
    // adopted this port's order:
    // - Remove patches are replayed on the source before Auto, as remove-evaluation §7 specifies
    //   ("on the full-resolution source pixels, before tone and colour adjustments"), so a later
    //   tone or colour change never needs the model again;
    // - Adjust and stages 6–8 run in source coordinates, then geometry. Detail's and Focus &
    //   Blur's radii follow the uncropped source long edge.
    // Then border (11) and watermark (12) on the canvas.
    /// `base` is consumed: when the caller hands over its only reference (Save copy), the source frame is freed as soon as
    /// the first stage has produced its output, instead of staying alive through the whole render (2026-10-07: one full
    /// frame less at the peak, 192 MB at 48 MP). Previews pass a base they keep; for them nothing changes.
    /// Holds a frame until the render takes it, so the caller keeps no reference of its own.
    private final class SourceHandOff: @unchecked Sendable {
        private var pixels: [UInt8]
        init(_ pixels: [UInt8]) { self.pixels = pixels }
        func take() -> [UInt8] { defer { pixels = [] }; return pixels }
    }

    nonisolated private static func renderPixels(_ job: RenderJob, base: consuming [UInt8], width: Int, height: Int,
                                                 renderer: DevelopFrameRenderer, cache: DevelopLUTCache, prefixCache: PreviewPrefixCache? = nil) throws -> RenderedFrame {
        let frame = try renderFrameBeforeBorder(job, base: consume base, width: width, height: height, renderer: renderer, cache: cache, prefixCache: prefixCache)
        var canvas = BorderStage.apply(job.border, pixels: frame.pixels, width: frame.width, height: frame.height)
        // Stage 12 on the canvas, after the border, so a watermark can sit in its margin.
        if job.watermark.type != .none, let content = job.watermarkContent {
            let imageRect = job.border.type == .none ? CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
                : BorderStage.placement(job.border, frameWidth: frame.width, frameHeight: frame.height).imageRect
            WatermarkStage.apply(job.watermark, content: content, pixels: &canvas.pixels, canvasWidth: canvas.width,
                                 canvasHeight: canvas.height, imageRect: imageRect, border: job.border.type,
                                 displayShortEdgePoints: job.displayPhotoSize.map { Double(min($0.width, $0.height)) })
        }
        return RenderedFrame(pixels: canvas.pixels, width: canvas.width, height: canvas.height)
    }

    /// Stages 1–10 (everything up to the border).
    nonisolated private static func renderFrameBeforeBorder(_ job: RenderJob, base: consuming [UInt8], width: Int, height: Int,
                                                            renderer: DevelopFrameRenderer, cache: DevelopLUTCache, prefixCache: PreviewPrefixCache? = nil) throws -> RenderedFrame {
        guard job.usesEditOrEffects || job.stopBeforeSelectiveColour else {
            return RenderedFrame(pixels: try renderDevelopAndLayered(job, base: consume base, width: width, height: height,
                                                                     renderer: renderer, cache: cache),
                                 width: width, height: height)
        }
        let plan = job.look.map { DevelopRenderPlan.look($0, strength: job.strength, cache: cache, lutDimension: job.lutDimension) }
        let frame: RenderedFrame
        if let cached = prefixCache?.get(job.prefixKey) {
            frame = cached
        } else {
        var pixels = consume base
        // Compositing here mutates a copy of `base` (the caller still holds it): a whole extra frame, 192 MB at 48 MP.
        // Save copy composites into its own buffer first instead (`removePatchesInBase`).
        if !job.removePatchesInBase { RemoveEngine.composite(job.removePatches, into: &pixels, width: width, height: height) }
        if let autoLUT = job.autoLUT, job.autoStrength > 0 {
            pixels = try renderer.lutApplier.apply([autoLUT.blendedTowardIdentity(strength: Float(job.autoStrength))],
                                                   toRGBA8: pixels, width: width, height: height,
                                                   maximumTileSide: MetalLUTRenderer.defaultMaximumTileSide)
        }
        if let plan {
            pixels = try renderer.render(plan, pixels: pixels, width: width, height: height,
                                         includePixelStages: job.includePixelStages, includeFinishing: false)
        }
        // Stage 5, Adjust: colour as a baked LUT, Detail as the Develop spatial operators.
        let adjustLUT = AdjustStage.colourLUT(job.edit.adjust, model: renderer.model)
        let detail = job.includePixelStages ? AdjustStage.detailSpatial(job.edit.adjust) : PresetRecipe.Spatial()
        if adjustLUT != nil || !detail.isEmpty {
            let adjustPlan = DevelopRenderPlan(lookLUT: adjustLUT, spatial: detail, finishing: .init(), presetID: nil)
            pixels = try renderer.render(adjustPlan, pixels: pixels, width: width, height: height, includePixelStages: true)
        }
        try Task.checkCancellation()
        if var layered = job.layered, LayeredStages.isActive(layered) {
            layered.maxBlurRadiusFraction = blurFraction(job, sourceWidth: width, sourceHeight: height)
            layered.developLUT = plan?.lookLUT
            layered.autoLUT = job.autoLUT.map { $0.blendedTowardIdentity(strength: Float(job.autoStrength)) }
            layered.adjustLUT = adjustLUT
            pixels = try LayeredStages.render(pixels, width: width, height: height, inputs: layered, cap: job.layeredCap,
                                              lutApplier: renderer.lutApplier)
        }
        try Task.checkCancellation()
        let transform = GeometryTransform(job.edit.geometry, sourceWidth: width, sourceHeight: height)
        let transformed = transform.render(pixels, width: width, height: height)
        frame = RenderedFrame(pixels: transformed.pixels, width: transformed.width, height: transformed.height)
        try Task.checkCancellation()
        prefixCache?.put(frame, key: job.prefixKey)
        }
        guard job.includePixelStages else { return RenderedFrame(pixels: frame.pixels, width: frame.width, height: frame.height) }
        if job.stopBeforeSelectiveColour {
            // Only the stage before Selective Colour, the light leak; no preset finishing (it comes after).
            var leakOnly = EditRecipe.Tools.neutral(grainSeed: 0).effects
            leakOnly.lightLeak = job.effects.lightLeak
            let leak = EffectsStage(effects: leakOnly, presetFinishing: .init(), presetStrength: 0,
                                    frameWidth: frame.width, frameHeight: frame.height, model: renderer.model)
            return RenderedFrame(pixels: leak.apply(frame.pixels, width: frame.width, height: frame.height),
                                 width: frame.width, height: frame.height)
        }
        let effects = EffectsStage(effects: job.effects, presetFinishing: plan?.finishing ?? .init(),
                                   presetStrength: plan?.finishingStrength ?? 0,
                                   frameWidth: frame.width, frameHeight: frame.height, model: renderer.model)
        return RenderedFrame(pixels: effects.apply(frame.pixels, width: frame.width, height: frame.height),
                             width: frame.width, height: frame.height)
    }

    /// The slice-2/3 stages: Auto (1) then the Look (2, 3, 10), with Background and Portrait (7–9)
    /// between the Look's spatial stage and its finishing.
    nonisolated private static func renderDevelopAndLayered(_ job: RenderJob, base: consuming [UInt8], width: Int, height: Int,
                                                            renderer: DevelopFrameRenderer, cache: DevelopLUTCache) throws -> [UInt8] {
        var pixels = consume base
        if let autoLUT = job.autoLUT, job.autoStrength > 0 {
            pixels = try renderer.lutApplier.apply([autoLUT.blendedTowardIdentity(strength: Float(job.autoStrength))],
                                                   toRGBA8: pixels, width: width, height: height,
                                                   maximumTileSide: MetalLUTRenderer.defaultMaximumTileSide)
        }
        let plan = job.look.map { DevelopRenderPlan.look($0, strength: job.strength, cache: cache, lutDimension: job.lutDimension) }
        guard var layered = job.layered, LayeredStages.isActive(layered) else {
            guard let plan else { return pixels }
            return try renderer.render(plan, pixels: pixels, width: width, height: height, includePixelStages: job.includePixelStages)
        }
        layered.maxBlurRadiusFraction = blurFraction(job, sourceWidth: width, sourceHeight: height)
        // Stages 2–3, then 7–9, then the preset's finishing in stage 10.
        if let plan {
            pixels = try renderer.render(plan, pixels: pixels, width: width, height: height,
                                         includePixelStages: job.includePixelStages, includeFinishing: false)
        }
        layered.developLUT = plan?.lookLUT
        layered.autoLUT = job.autoLUT.map { $0.blendedTowardIdentity(strength: Float(job.autoStrength)) }
        pixels = try LayeredStages.render(pixels, width: width, height: height, inputs: layered, cap: job.layeredCap,
                                          lutApplier: renderer.lutApplier)
        if let plan, job.includePixelStages { pixels = renderer.finish(plan, pixels: pixels, width: width, height: height) }
        return pixels
    }

    /// Focus & Blur's R_max from the displayed photo (nil before the editor has laid out: the
    /// contract's 0.06 of the long side).
    nonisolated private static func blurFraction(_ job: RenderJob, sourceWidth: Int, sourceHeight: Int) -> Float? {
        guard let display = job.displayPhotoSize else { return nil }
        let frame = GeometryTransform(job.edit.geometry, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        return RefocusRenderer.maxRadiusFraction(displayLongEdgePoints: Double(max(display.width, display.height)),
                                                 frameLongPixels: max(frame.frameWidth, frame.frameHeight),
                                                 sourceLongPixels: max(sourceWidth, sourceHeight))
    }

    private func layeredInputs(for target: EditRecipe) -> LayeredStages.Inputs? {
        let inputs = LayeredStages.Inputs(background: target.tools.background, portrait: target.tools.portrait,
                                          cache: sceneCache, developLUT: nil, autoLUT: nil)
        return LayeredStages.isActive(inputs) ? inputs : nil
    }

    private func renderCommitted() { render(recipe, final: true) }
    private func refreshCurrentPreview() {
        if let activePreviewRecipe { render(activePreviewRecipe, final: false) }
        else { renderCommitted() }
    }

    /// Requests the complete edit at one stable preview resolution and LUT precision.
    /// Interaction changes scheduling priority, never the image-processing recipe.
    private func render(_ requested: EditRecipe, final: Bool, dragFrame: Bool = false) {
        activePreviewRecipe = final ? nil : requested
        let target = isCropEditing ? Self.uncropped(requested) : requested
        // An interactive frame is a control moving (a slider, a drag) before it commits: a pick still sampling
        // is stale from this moment, or it would land mid-drag and replace the preview with committed values.
        if !final { editEpoch &+= 1 }
        guard !isClosed, scheduler != nil else { return }
        generation += 1
        let current = generation
        pendingRequests.append((current, ContinuousClock.now))
        var look: PresetPack.Preset?
        var strength = 0.0
        if let ref = target.look, case .available(let preset) = library.pack.resolve(lookID: ref.lookId, version: ref.lookVersion) {
            look = preset
            strength = ref.strength
        }
        let auto = autoState == .applied ? autoLUT : nil
        let layered = layeredInputs(for: target)
        var job = RenderJob(look: look, strength: strength, autoLUT: auto, autoStrength: target.auto.strength,
                            includePixelStages: true, generation: current)
        attachEditAndEffects(target, to: &job)
        var upstream = target
        upstream.revision = 0
        let neutral = EditRecipe.Tools.neutral(grainSeed: 0)
        upstream.tools.effects = neutral.effects
        upstream.tools.border = neutral.border
        upstream.tools.watermark = neutral.watermark
        job.prefixKey = PreviewPrefixKey(recipe: upstream, sceneGeneration: sceneGeneration,
                                         autoLUT: auto, displaySize: renderReferencePhotoSize ?? displayedPhotoSize)
        // Every published frame contains the complete edit. A fast frame that omits finishing
        // flashes the ungrained/unvignetted image before the full result on every release.
        job.includePixelStages = true
        job.followUpWithFullFrame = false
        if let layered {
            job.layered = layered
            // Effects sliders must not change the subject edge or blur resolution as they move.
            job.layeredCap = LayeredStages.previewCap
        }
        job.dragFrame = dragFrame && dragBase != nil
        submit(job)
    }

    private func submit(_ job: RenderJob) {
        guard let scheduler else { return }
        nextJobRevision += 1
        let revision = nextJobRevision
        outstanding[revision] = Task { [weak self] in
            let outcome = await scheduler.render(job, revision: revision)
            self?.handle(outcome, job: job, revision: revision)
        }
    }

    private func handle(_ outcome: PreviewRenderOutcome, job: RenderJob, revision: UInt64) {
        outstanding[revision] = nil
        guard !isClosed else { return }
        if job.followUpWithFullFrame, job.generation == generation {
            var full = job
            full.includePixelStages = true
            full.followUpWithFullFrame = false
            full.layeredCap = LayeredStages.previewCap
            submit(full)
        }
        guard case .rendered(let image) = outcome else { return }
        // Frames only ever move forward: a result older than what is on screen is dropped, and a
        // fast frame never replaces the full frame of the same request. A result that is not the
        // newest request but newer than the screen is shown — while the finger keeps moving, the
        // newest request is always younger than any finished render, and waiting for it would
        // leave the photo frozen until the drag stops.
        guard job.generation >= publishedGeneration else { return }
        if job.generation == publishedGeneration, publishedWasFull, !job.includePixelStages { return }
        displayedImage = image
        if job.dragFrame, let started = dragStartedAt, firstDragFrameTraced == false {
            firstDragFrameTraced = true
            DiagnosticTrace.note("ruler: first drag frame visible after \((ContinuousClock.now - started).components.attoseconds / 1_000_000_000_000_000 + (ContinuousClock.now - started).components.seconds * 1000) ms")
        }
        #if DEBUG
        debugPublished.append((job.generation, job.look?.id, job.dragFrame))
        #endif
        displayedImageBox = BorderStage.imageBox(job.border, canvasWidth: image.width, canvasHeight: image.height)
        publishedGeneration = job.generation
        publishedWasFull = job.includePixelStages
        publishedRenderCount += 1
        let now = ContinuousClock.now
        pendingRequests.removeAll { request in
            guard request.generation <= job.generation else { return false }
            previewStaleness.append(now - request.at)
            return true
        }
    }

    /// Waits for every issued render. For tests and measurements; the app never waits on renders.
    func settleRendering() async {
        await pickTask?.value
        await settleRenderingExceptPicks()
    }

    /// Waits for every issued render but not for picks still sampling. For tests.
    func settleRenderingExceptPicks() async {
        while let (revision, task) = outstanding.first {
            await task.value
            outstanding[revision] = nil
        }
        await scheduler?.waitUntilIdle()
    }

    /// Waits until opening and automatic Develop have finished. For tests.
    func waitUntilReady() async {
        await startTask?.value
    }

    // MARK: - Save copy

    /// Renders the committed recipe at full resolution (tiled) with the same Develop renderer as
    /// the preview, applies the metadata switches, and adds it as a new photo. A transient preview
    /// is never what gets saved.
    func saveCopy() {
        guard phase == .ready, saveState != .saving, let renderer = library.renderer, let cache = library.cache else {
            // Why a Save copy request did nothing (device diagnosis: a silent no-op looked like a hang).
            DiagnosticTrace.note("save ignored: phase=\(String(describing: self.phase)) saving=\(self.saveState == .saving) renderer=\(self.library.renderer != nil) cache=\(self.library.cache != nil)")
            return
        }
        saveState = .saving
        releaseRemoveModelIfIdle()
        DiagnosticTrace.note("save started \(self.photo.image.width)x\(self.photo.image.height)")
        let job = committedJob()
        let image = photo.image
        let originalData = photo.originalData
        let settings = saveSettings()
        let exporter = exporter
        let writer = libraryWriter
        let awake = KeepAwake.begin("save copy")
        saveTask = Task { [weak self] in
            defer { KeepAwake.end(awake) }
            do {
                let timing = SaveTiming(width: image.width, height: image.height)
                let work = Task.detached(priority: .userInitiated) { () -> Data in
                    var pixels = try timing.measure("bytes") { try MetalLUTRenderer.rgba8Bytes(of: image) }
                    // The fills go into this buffer in place (it is the only reference): the render then needs no
                    // copy of the frame to composite them (2026-10-07, iPhone 11 Pro Max, 48 MP: Save copy with fills
                    // peaked 147 MB above one without).
                    var job = job
                    if !job.removePatches.isEmpty {
                        RemoveEngine.composite(job.removePatches, into: &pixels, width: image.width, height: image.height)
                        job.removePatchesInBase = true
                    }
                    // Hand the only reference to the render (a closure cannot consume a captured variable): the source
                    // frame is freed after the first stage instead of at the end of this task.
                    let source = SourceHandOff(pixels)
                    pixels = []
                    let rendered = try timing.measure("render") {
                        try Self.renderPixels(job, base: source.take(), width: image.width, height: image.height, renderer: renderer, cache: cache)
                    }
                    try Task.checkCancellation()
                    DiagnosticTrace.note("save rendered \(rendered.width)x\(rendered.height)")
                    let output = try timing.measure("image") { try MetalLUTRenderer.makeImage(rgba8: rendered.pixels, width: rendered.width, height: rendered.height) }
                    let encoded = try timing.measure("encode") { try exporter.encode(output, originalData: originalData, settings: settings) }
                    DiagnosticTrace.note("save encoded \(encoded.count) bytes")
                    return encoded
                }
                // The render runs detached (seconds at 48 MP); Cancel stops it between tiles.
                let data = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                // Cancelled before writing: nothing is written, so there is never a duplicate.
                try Task.checkCancellation()
                let writeStart = ContinuousClock.now
                try await writer.save(data, fileExtension: settings.format.fileExtension)
                timing.record("write", since: writeStart)
                timing.report()
                DiagnosticTrace.note("save written: \(data.count) bytes sha256 \(Self.sha256(data))")
                #if DEBUG
                // The exact bytes handed to Photos, for the device check (Photos' own copy cannot be read from the Mac).
                DiagnosticTrace.evidence(data, named: "save-\(DiagnosticTrace.stamp).\(settings.format.fileExtension)")
                #endif
                self?.finishSave(.saved(data))
            } catch is CancellationError {
                DiagnosticTrace.note("save cancelled")
                self?.finishSave(.idle)
            } catch LightlyError.permissionDenied {
                DiagnosticTrace.note("save failed: Photos permission denied")
                self?.finishSave(.permissionDenied)
            } catch LightlyError.storageFull {
                DiagnosticTrace.note("save failed: storage full")
                self?.finishSave(.storageFull)
            } catch {
                DiagnosticTrace.note("save failed: \(String(describing: error))")
                self?.finishSave(.failed)
            }
        }
    }

    /// The render job for the committed recipe at full quality (export).
    private func committedJob() -> RenderJob {
        var look: PresetPack.Preset?
        var strength = 0.0
        if let ref = recipe.look, case .available(let preset) = library.pack.resolve(lookID: ref.lookId, version: ref.lookVersion) {
            look = preset
            strength = ref.strength
        }
        var job = RenderJob(look: look, strength: strength, autoLUT: autoState == .applied ? autoLUT : nil,
                            autoStrength: recipe.auto.strength, includePixelStages: true, generation: 0)
        job.layered = layeredInputs(for: recipe)
        job.layeredCap = LayeredStages.exportCap
        attachEditAndEffects(recipe, to: &job)
        return job
    }

    private func attachEditAndEffects(_ target: EditRecipe, to job: inout RenderJob) {
        job.edit = target.tools.edit
        job.effects = target.tools.effects
        job.border = target.tools.border
        job.watermark = target.tools.watermark
        job.watermarkContent = watermarkContent(for: target.tools.watermark)
        job.displayPhotoSize = renderReferencePhotoSize ?? displayedPhotoSize
        job.removePatches = removePatches.patches(for: target.tools.edit.remove.strokes)
    }

    /// Stage 12's content for a watermark, resolved against the saved signatures and logos.
    /// A missing or changed saved signature, or a logo file not on this device, resolves to nil:
    /// the photo renders without it (edit recipe `signatureRef` rule).
    // DEFERRED(owner question W2): there is no approved notice for a missing or changed saved
    // signature, so none is shown; the panel's chips still offer the current signatures.
    func watermarkContent(for watermark: EditRecipe.Watermark) -> WatermarkStage.Content? {
        switch watermark.type {
        case .none: return nil
        case .signature:
            guard let reference = watermark.signature, case .available(let saved) = signatures.resolve(reference) else { return nil }
            switch saved.kind {
            case .drawn: return saved.drawn.map { .drawnSignature($0) }
            case .imported: return .importedSignature(saved.data)
            }
        case .text:
            return watermark.text.map { .text($0.text, $0.font) }
        case .logo:
            switch watermark.logo {
            case .bundled(let id)? where id == WatermarkStage.sampleLogoID: return .sampleLogo
            case .file(let digest)?: return signatures.logo(sha256: digest).map { .logoImage($0) }
            default: return nil
            }
        }
    }

    /// Re-renders after the saved signatures changed (Preferences: drawn again, imported, deleted),
    /// so the photo shows what the recipe now resolves to.
    func signaturesChanged() { renderCommitted() }

    /// Saving › Cancel: nothing is written ("Save cancelled · nothing was written").
    func cancelSave() {
        guard saveState == .saving else { return }
        saveTask?.cancel()
        saveTask = nil
        saveState = .idle
        showToast("Save cancelled · nothing was written")
    }

    /// The stage's toast (`.toast`), shown for 1.4 s as in the prototype.
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// A tool's confirmation on the stage (`.toast`), e.g. "Signature saved for reuse".
    func showStageToast(_ text: String) { showToast(text) }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_400))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Dismisses the saved sheet or a save error ("Keep editing", "OK", "Not now").
    func dismissSaveState() {
        if saveState != .saving { saveState = .idle }
    }

    private func finishSave(_ state: SaveState) {
        // A cancelled save already returned to idle; a late result must not reopen a sheet.
        guard !isClosed, saveState == .saving else { return }
        saveState = state
        if case .saved = state {
            hasUnsavedEdits = false
            // Saved as a copy: there is nothing left to recover.
            persistSession()
        }
    }

    // MARK: - Session persistence (restore after the system ends the app)

    /// Keeps the stored session in step: written while there are unsaved edits, cleared once there
    /// are none. The original's bytes are written once; the history on every change; the model
    /// results when they changed.
    /// The scene session the editor is shown in (one scene: Lightly does not open extra windows).
    @ObservationIgnored var sceneSessionID: () -> String? = {
        UIApplication.shared.connectedScenes.first(where: { $0.activationState != .unattached })?.session.persistentIdentifier
            ?? UIApplication.shared.connectedScenes.first?.session.persistentIdentifier
    }

    private func persistSession() {
        guard let sessionStore, !isClosed else { return }
        guard hasUnsavedEdits else {
            if sessionPersisted { sessionStore.clear() }
            sessionPersisted = false
            analysisPersistedRevision = -1
            return
        }
        if !sessionPersisted {
            sessionStore.saveOriginal(photo.originalData)
            sessionPersisted = true
        }
        sessionStore.saveHistory(history, index: historyIndex, autoState: autoState.rawValue, sceneSessionID: sceneSessionID(),
                                 autoCorrection: autoCorrection?.json)
        if analysisPersistedRevision != analysisRevision {
            sessionStore.saveAnalysis(PersistedAnalysis(hasPerson: hasPerson, people: people, subjectAnalysed: sceneCache.subjectAnalysed,
                                                        subject: sceneCache.subject, disparity: sceneCache.disparity,
                                                        personMatte: sceneCache.personMatte))
            analysisPersistedRevision = analysisRevision
        }
    }

    /// Opens a stored session exactly as it was: its history and position, its Auto state and the
    /// model results it was edited with.
    // Auto: the Core Image correction (filters and parameters) is stored with the history; the LUT is rebuilt from it,
    // never by analysing the photo again. A stored applied/off Auto without its correction restores as unavailable,
    // never as a different result.
    private func applyRestored(_ saved: PersistedEditSession) {
        let analysis = saved.analysis
        hasPerson = analysis.hasPerson ?? false
        people = analysis.people
        sceneCache.people = analysis.people
        sceneCache.personMatte = analysis.personMatte
        if analysis.subjectAnalysed {
            sceneCache.subject = analysis.subject
            sceneCache.subjectAnalysed = true
            sceneCache.disparity = analysis.disparity
            for name in BackgroundPanelModel.bundledImages where sceneCache.replacementImages[name] == nil {
                sceneCache.replacementImages[name] = BundledBackgrounds.image(name)
            }
            matteImage = analysis.subject.flatMap { Self.maskImage($0.matte) }
            if let matte = analysis.subject {
                let centroid = RefocusRenderer.defaultTarget(matte: matte.matte, faces: people?.faces ?? [])
                defaultFocusTarget = (Double(centroid.x), Double(centroid.y))
            }
            subjectState = analysis.subject == nil ? .noSubject : .ready
            // Depth that was pending or failed when the session was stored runs again on next use.
            depthState = analysis.disparity == nil ? .notStarted : .ready
        }
        autoState = AutoState(rawValue: saved.autoState) ?? .unavailable
        if autoState == .applied || autoState == .off {
            if let correction = saved.autoCorrection, let lut = correction.lut() {
                autoCorrection = correction
                autoLUT = lut
            } else {
                DiagnosticTrace.note("restore: Auto \(saved.autoState) without its stored correction: shown as unavailable")
                autoState = .unavailable
            }
        }
        history = saved.history
        historyIndex = saved.index
        editEpoch &+= 1
        hasUnsavedEdits = true
        sessionPersisted = true
        analysisPersistedRevision = analysisRevision
        phase = .ready
        renderCommitted()
    }

    /// The full-resolution bytes Save copy would write for the committed recipe (tests).
    func exportedData() async throws -> Data {
        guard let renderer = library.renderer, let cache = library.cache else { throw LightlyError.exportFailed }
        let job = committedJob()
        let image = photo.image
        let pixels = try MetalLUTRenderer.rgba8Bytes(of: image)
        let rendered = try Self.renderPixels(job, base: pixels, width: image.width, height: image.height, renderer: renderer, cache: cache)
        let output = try MetalLUTRenderer.makeImage(rgba8: rendered.pixels, width: rendered.width, height: rendered.height)
        return try exporter.encode(output, originalData: photo.originalData, settings: saveSettings())
    }

    // MARK: - Lifecycle

    /// Ends the session when the photo is closed or replaced: in-flight renders are dropped and
    /// nothing that finishes later changes this screen.
    func close() {
        prefetchTask?.cancel()
        isClosed = true
        startTask?.cancel()
        saveTask?.cancel()
        // Subject separation and depth run for seconds on the CPU; a closed session's result
        // has nowhere to go.
        subjectTask?.cancel()
        depthTask?.cancel()
        removeTask?.cancel()
        let scheduler = scheduler
        Task { await scheduler?.close() }
    }

    var isSessionClosed: Bool { isClosed }

    // MARK: - Source reference

    /// EditState `source` for a decoded photo: sha256 of the first 64 KiB, byte size and pixel
    /// size. The decoded image is already upright, so its orientation is 1.
    static func sourceReference(for photo: SelectedPhoto) -> EditRecipe.Source {
        let head = photo.originalData.prefix(65_536)
        let digest = SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
        return EditRecipe.Source(
            assetId: photo.id.uuidString,
            fingerprint: .init(headSha256: digest, byteSize: Int64(photo.originalData.count),
                               pixelWidth: photo.image.width, pixelHeight: photo.image.height),
            orientation: 1)
    }

    #if DEBUG
    /// Holds an approved Remove state for a capture (`ed-removing`, `ed-remove-failed`) with the
    /// stroke the person drew, without running the model.
    func debugHoldRemoveState(_ state: RemoveState, stroke: EditRecipe.RemoveStroke) {
        removeTask?.cancel()
        pendingRemoveStroke = stroke
        removeState = state
    }

    /// Captures of `ed-remove`: removes the stroke with the real model and waits until it is
    /// applied (or failed), then makes the result the session's initial state, like `stateFor`.
    /// Device memory checks: one Remove stroke as the person makes it (an undo step), awaited.
    func debugRemove(points: [EditRecipe.Point], radius: Double) async {
        removeStroke(points: points, radius: radius)
        await removeTask?.value
    }

    func debugRemoveAsInitial(points: [EditRecipe.Point], radius: Double) async {
        removeStroke(points: points, radius: radius)
        await removeTask?.value
        if removeState == .idle, history.count > 1 {
            let last = recipe
            history = [last]
            historyIndex = 0
            editEpoch &+= 1
        }
    }

    /// A scenario's recipe as the session's initial state (not an undo step), like `stateFor`.
    func debugSetInitial(_ change: (inout EditRecipe) -> Void) {
        var next = recipe
        change(&next)
        recordDerivedResults(in: &next.tools.background)
        history = [next]
        historyIndex = 0
        renderCommitted()
    }

    /// Capture sessions: waits for analysis that will re-render the photo when it lands (person
    /// segmentation for the hair operators), so the captured frame is the final one.
    func debugAwaitPendingAnalysis() async {
        await personMatteTask?.value
    }

    /// Waits until `condition` holds (capture sessions; polled on the main actor).
    func debugWait(until condition: () -> Bool) async {
        while !condition(), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(30)) }
    }

    /// Capture sessions: after `close()`, waits until nothing this session started is still
    /// running (open, subject separation and depth, Save copy, renders), so its CPU work cannot
    /// slow or touch the next screen.
    func debugAwaitQuiescence() async {
        await startTask?.value
        await subjectTask?.value
        await depthTask?.value
        await focusTask?.value
        await personMatteTask?.value
        await removeTask?.value
        await saveTask?.value
        await settleRendering()
    }

    /// Holds an approved Background state for a capture (`bg-separating`, `bg-failed`).
    func debugHoldSubjectState(_ state: SubjectState) {
        subjectTask?.cancel()
        depthTask?.cancel()
        subjectState = state
        switch state {
        case .separating: depthState = .estimating
        case .failed: depthState = .failed
        default: break
        }
    }

    /// Waits until subject separation has finished (captures of Background screens).
    func debugWaitForSubject() async {
        // Depth is waited for only once something started it (Focus & Blur); Change background never starts it.
        while subjectState == .separating || subjectState == .notStarted || depthState == .estimating {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Design captures and UI tests: put the session in an approved state directly.
    func debugSetAutoState(_ state: AutoState) { autoState = state }
    /// Sets up a scenario's starting recipe the way the prototype's `stateFor` does: as the
    /// session's initial state, not as an undo step.
    func debugApply(_ preset: PresetPack.Preset, amount: Double) {
        amountMemory[preset.id] = Self.strength(forAmount: amount)
        var next = recipe
        next.look = .init(lookId: preset.id, lookVersion: preset.lookVersion, strength: Self.strength(forAmount: amount))
        history = [next]
        historyIndex = 0
        renderCommitted()
    }
    #endif
}


/**
 * Save copy's stage times (2026-10-07), logged in every build configuration (subsystem com.lightlylabs.lightly,
 * category SaveTiming) so Debug and Release are measured the same way; numbers only, nothing about the photo.
 */
final class SaveTiming: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.lightlylabs.lightly", category: "SaveTiming")
    private let width: Int
    private let height: Int
    private let lock = NSLock()
    private var stages: [(String, Double)] = []

    /// task_vm_info's ledger peak of the physical footprint (the figure jetsam limits apply to), or nil.
    static func peakFootprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.ledger_phys_footprint_peak / 1_048_576)
    }

    /// task_vm_info's current physical footprint (what the process holds now), or nil.
    static func currentFootprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }

    /** The last report, for the timing test. */
    nonisolated(unsafe) static var lastReport: String?

    init(width: Int, height: Int) { self.width = width; self.height = height }

    func measure<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        #if DEBUG
        // Each stage's own peak footprint (sampled every 10 ms), to locate where Save copy's peak comes from.
        let startMB = Self.currentFootprintMB() ?? -1
        let sampler = DebugFootprintSampler()
        defer {
            let peak = sampler.stop(), endMB = Self.currentFootprintMB() ?? -1
            lock.lock(); stagePeaks.append("\(stage)=\(startMB)/\(peak)/\(endMB)MB"); lock.unlock()
        }
        #endif
        defer { record(stage, since: start) }
        return try body()
    }

    #if DEBUG
    private var stagePeaks: [String] = []
    #endif

    func record(_ stage: String, since start: ContinuousClock.Instant) {
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        lock.lock(); stages.append((stage, ms)); lock.unlock()
    }

    func report() {
        lock.lock(); var line = stages.map { "\($0.0)=\(Int($0.1.rounded()))ms" }.joined(separator: " "); lock.unlock()
        // The process's peak physical footprint so far (what iOS counts against the app's memory limit), in MB.
        if let peak = Self.peakFootprintMB() { line += " peakFootprint=\(peak)MB" }
        #if DEBUG
        lock.lock(); if !stagePeaks.isEmpty { line += " " + stagePeaks.joined(separator: " ") }; lock.unlock()
        #endif
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        Self.log.notice("save \(self.width, privacy: .public)x\(self.height, privacy: .public) \(configuration, privacy: .public): \(line, privacy: .public)")
        Self.lastReport = "\(width)x\(height) \(configuration): \(line)"
        DiagnosticTrace.note("save timing \(configuration) \(line)")
    }
}

private actor PresetThumbnailWorker {
    static let shared = PresetThumbnailWorker()
    func run(_ work: @Sendable () throws -> CGImage) throws -> CGImage {
        try Task.checkCancellation()
        return try autoreleasepool { try work() }
    }
}
