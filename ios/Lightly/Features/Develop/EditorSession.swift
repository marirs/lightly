import CoreGraphics
import CryptoKit
import Foundation
import Observation

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
    enum AutoState: Equatable {
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
    private(set) var historyIndex = 0
    private(set) var displayedImage: CGImage
    private(set) var isShowingOriginal = false
    private(set) var saveState: SaveState = .idle
    /// Edits made since the last saved copy (the approved `dirty`).
    private(set) var hasUnsavedEdits = false

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
    private let libraryWriter: any PhotoLibraryWriting
    private let exporter: any PhotoExporting
    private let saveSettings: @MainActor () -> ExportSettings
    private let previewLongEdge: Int

    @ObservationIgnored private var previewBase: (pixels: [UInt8], width: Int, height: Int)?
    @ObservationIgnored private var originalPreview: CGImage
    @ObservationIgnored private var scheduler: LatestWinsRenderScheduler<RenderJob>?
    @ObservationIgnored private var autoLUT: LUT3D?
    /// Per-preset Amount the person chose in this session, so re-selecting a preset restores it.
    @ObservationIgnored private var amountMemory: [String: Double] = [:]
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
         libraryWriter: any PhotoLibraryWriting = PhotoKitLibraryWriter(),
         exporter: any PhotoExporting = ImageIOPhotoExporter(),
         saveSettings: @escaping @MainActor () -> ExportSettings = { .default },
         previewLongEdge: Int = 1_600) {
        self.photo = photo
        self.library = library
        self.autoEnhancer = autoEnhancer
        self.personDetector = personDetector
        self.libraryWriter = libraryWriter
        self.exporter = exporter
        self.saveSettings = saveSettings
        self.previewLongEdge = previewLongEdge
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
        let image = photo.image
        let longEdge = previewLongEdge
        let prepared = await Task.detached(priority: .userInitiated) { () -> (pixels: [UInt8], width: Int, height: Int, image: CGImage)? in
            guard let preview = AnalysisProxy.downscaled(image, maximumLongEdge: longEdge),
                  let pixels = try? MetalLUTRenderer.rgba8Bytes(of: preview),
                  let rebuilt = try? MetalLUTRenderer.makeImage(rgba8: pixels, width: preview.width, height: preview.height)
            else { return nil }
            return (pixels, preview.width, preview.height, rebuilt)
        }.value
        guard !isClosed else { return }
        if let prepared {
            previewBase = (prepared.pixels, prepared.width, prepared.height)
            originalPreview = prepared.image
            displayedImage = prepared.image
            makeScheduler()
        }
        async let person = personDetector.containsPerson(prepared?.image ?? image)
        await library.waitUntilLoaded()
        hasPerson = await person
        guard !isClosed else { return }
        #if DEBUG
        // Design captures of the loading screen (`--hold-phase`): stay in that phase.
        if let held = DebugScenario.heldPhase {
            phase = held
            return
        }
        #endif
        await develop()
    }

    /// Runs automatic Develop. With no model in the build this resolves at once to the approved
    /// unavailable state; nothing is ever presented as Auto unless a model produced it.
    private func develop() async {
        phase = .developing
        let proxy = try? AnalysisProxy.make(from: photo)
        let result: AutoResult = if let proxy { await autoEnhancer.autoLUT(forAnalysisProxy: proxy) } else { .unavailable(.analysisFailed) }
        guard !isClosed else { return }
        switch result {
        case .lut(let lut):
            autoLUT = lut
            autoState = .applied
            // DEFERRED(D1): the real model id, version and weights belong in `auto` once a model
            // ships; no code path reaches this branch in this build.
            var start = recipe
            start.auto.strength = 1
            if history.count == 1 {
                // Auto is the starting point, not an edit: it replaces the untouched initial entry.
                history = [start]
                historyIndex = 0
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
        case .unavailable, .failed:
            return
        }
    }

    // MARK: - Develop Look

    /// Shows a preset (or none) without committing it: the ruler while dragging.
    func previewLook(_ preset: PresetPack.Preset?) {
        render(recipeWithLook(preset), final: false)
    }

    /// Abandons a preview and shows the committed recipe again.
    func endPreview() { renderCommitted() }

    /// Applies a preset, replacing only the Develop Look (one undo step). nil removes the Look.
    /// Re-selecting the applied preset changes nothing, so its Amount is kept.
    func applyLook(_ preset: PresetPack.Preset?) {
        guard preset?.id != recipe.look?.lookId else { return renderCommitted() }
        commit(recipeWithLook(preset))
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

    // MARK: - History

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
        // The Auto switch follows the recipe it belongs to.
        if autoState == .applied || autoState == .off { autoState = recipe.auto.strength > 0 ? .applied : .off }
        hasUnsavedEdits = true
        if case .saved = saveState { saveState = .idle }
        renderCommitted()
    }

    /// Records `next` as one undo step (nothing when it equals the committed recipe).
    private func commit(_ next: EditRecipe) {
        guard next != recipe else { return renderCommitted() }
        var entry = next
        entry.revision = (history.map(\.revision).max() ?? 0) + 1
        history.removeSubrange((historyIndex + 1)...)
        history.append(entry)
        if history.count > Self.historyCapacity { history.removeFirst(history.count - Self.historyCapacity) }
        historyIndex = history.count - 1
        hasUnsavedEdits = true
        if case .saved = saveState { saveState = .idle }
        renderCommitted()
    }

    // MARK: - Compare

    func beginCompare() { isShowingOriginal = true }
    func endCompare() { isShowingOriginal = false }
    func toggleCompare() { isShowingOriginal.toggle() }

    var originalImage: CGImage { originalPreview }

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
        var followUpWithFullFrame = false
    }

    private func makeScheduler() {
        guard let base = previewBase, let renderer = library.renderer, let cache = library.cache else { return }
        scheduler = LatestWinsRenderScheduler { job in
            let pixels = try Self.renderPixels(job, base: base.pixels, width: base.width, height: base.height,
                                               renderer: renderer, cache: cache)
            return try MetalLUTRenderer.makeImage(rgba8: pixels, width: base.width, height: base.height)
        }
    }

    /// The Develop stages for a job, on any thread. Auto (stage 1) then the Look (stages 2, 3, 10).
    nonisolated private static func renderPixels(_ job: RenderJob, base: [UInt8], width: Int, height: Int,
                                                 renderer: DevelopFrameRenderer, cache: DevelopLUTCache) throws -> [UInt8] {
        var pixels = base
        if let autoLUT = job.autoLUT, job.autoStrength > 0 {
            pixels = try renderer.lutApplier.apply([autoLUT.blendedTowardIdentity(strength: Float(job.autoStrength))],
                                                   toRGBA8: pixels, width: width, height: height,
                                                   maximumTileSide: MetalLUTRenderer.defaultMaximumTileSide)
        }
        guard let look = job.look else { return pixels }
        let plan = DevelopRenderPlan.look(look, strength: job.strength, cache: cache)
        return try renderer.render(plan, pixels: pixels, width: width, height: height, includePixelStages: job.includePixelStages)
    }

    private func renderCommitted() { render(recipe, final: true) }

    /// Requests a preview of `target`. A final render shows the global stage first, then the full
    /// Develop (spatial and finishing) when the preset has them; an interactive one (dragging)
    /// shows the global stage only, so the photo keeps up with the finger.
    private func render(_ target: EditRecipe, final: Bool) {
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
        let hasPixelStages = look.map { !$0.recipe.spatial.isEmpty || !$0.recipe.finishing.isEmpty } ?? false
        var job = RenderJob(look: look, strength: strength, autoLUT: auto, autoStrength: target.auto.strength,
                            includePixelStages: !hasPixelStages, generation: current)
        job.followUpWithFullFrame = final && hasPixelStages
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
        guard phase == .ready, saveState != .saving, let renderer = library.renderer, let cache = library.cache else { return }
        saveState = .saving
        let job = committedJob()
        let image = photo.image
        let originalData = photo.originalData
        let settings = saveSettings()
        let exporter = exporter
        let writer = libraryWriter
        saveTask = Task { [weak self] in
            do {
                let work = Task.detached(priority: .userInitiated) { () -> Data in
                    let pixels = try MetalLUTRenderer.rgba8Bytes(of: image)
                    let rendered = try Self.renderPixels(job, base: pixels, width: image.width, height: image.height,
                                                         renderer: renderer, cache: cache)
                    try Task.checkCancellation()
                    let output = try MetalLUTRenderer.makeImage(rgba8: rendered, width: image.width, height: image.height)
                    return try exporter.encode(output, originalData: originalData, settings: settings)
                }
                // The render runs detached (seconds at 48 MP); Cancel stops it between tiles.
                let data = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                // Cancelled before writing: nothing is written, so there is never a duplicate.
                try Task.checkCancellation()
                try await writer.save(data, fileExtension: settings.format.fileExtension)
                self?.finishSave(.saved(data))
            } catch is CancellationError {
                self?.finishSave(.idle)
            } catch LightlyError.permissionDenied {
                self?.finishSave(.permissionDenied)
            } catch LightlyError.storageFull {
                self?.finishSave(.storageFull)
            } catch {
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
        return RenderJob(look: look, strength: strength, autoLUT: autoState == .applied ? autoLUT : nil,
                         autoStrength: recipe.auto.strength, includePixelStages: true, generation: 0)
    }

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
        if case .saved = state { hasUnsavedEdits = false }
    }

    /// The full-resolution bytes Save copy would write for the committed recipe (tests).
    func exportedData() async throws -> Data {
        guard let renderer = library.renderer, let cache = library.cache else { throw LightlyError.exportFailed }
        let job = committedJob()
        let image = photo.image
        let pixels = try MetalLUTRenderer.rgba8Bytes(of: image)
        let rendered = try Self.renderPixels(job, base: pixels, width: image.width, height: image.height, renderer: renderer, cache: cache)
        let output = try MetalLUTRenderer.makeImage(rgba8: rendered, width: image.width, height: image.height)
        return try exporter.encode(output, originalData: photo.originalData, settings: saveSettings())
    }

    // MARK: - Lifecycle

    /// Ends the session when the photo is closed or replaced: in-flight renders are dropped and
    /// nothing that finishes later changes this screen.
    func close() {
        isClosed = true
        startTask?.cancel()
        saveTask?.cancel()
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
    /// Design captures and UI tests: put the session in an approved state directly.
    func debugSetAutoState(_ state: AutoState) { autoState = state }
    func debugApply(_ preset: PresetPack.Preset, amount: Double) {
        amountMemory[preset.id] = Self.strength(forAmount: amount)
        var next = recipe
        next.look = .init(lookId: preset.id, lookVersion: preset.lookVersion, strength: Self.strength(forAmount: amount))
        commit(next)
    }
    #endif
}
