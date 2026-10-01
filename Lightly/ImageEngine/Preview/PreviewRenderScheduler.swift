import CoreGraphics
import Foundation

/// Renders a recipe at preview resolution. Abstracted so tests can inject a
/// slow renderer and observe scheduling.
protocol PreviewRendering: Sendable {
    func renderPreview(
        _ source: CGImage,
        identity: PhotoFingerprint,
        with recipe: DevelopRecipe
    ) async throws -> CGImage
}

extension PreviewRenderer: PreviewRendering {}

/// What became of one render request.
enum PreviewRenderOutcome: Sendable {
    case rendered(CGImage)
    /// A newer request replaced this one before it started, or this one
    /// arrived after a newer request had already been accepted.
    case superseded
    /// Cancelled by Reset, close, or an explicit cancel.
    case cancelled
    case failed(any Error)
}

/// Bounded, latest-request-wins scheduling of preview renders for one photo.
///
/// At most one render runs and at most one waits. A new request replaces the
/// waiting one, so a slider drag that fires sixty requests costs two renders,
/// not sixty queued ones, and the last value the user chose is always the one
/// that runs. A "revision" here is a *request* ID (spec §5.2), issued per
/// render request and only ever increasing — never an edit-state revision,
/// because after Undo an older edit is the newest request. A
/// request older than one already accepted is refused, so tasks that reach
/// this actor out of order cannot reinstate a stale recipe.
///
/// The scheduler only bounds and orders work. Whether a finished render may
/// be *shown* is still the caller's decision (it alone knows the latest
/// revision and whether the session has closed).
actor PreviewRenderScheduler {

    private struct Job {
        let revision: UInt64
        let recipe: DevelopRecipe
        let continuation: CheckedContinuation<PreviewRenderOutcome, Never>
    }

    private let renderer: any PreviewRendering
    private let source: CGImage
    private let identity: PhotoFingerprint

    private var inFlight: (revision: UInt64, task: Task<Void, Never>)?
    private var pending: Job?
    private var newestAcceptedRevision: UInt64 = 0
    private var isClosed = false

    /// Highest observed in-flight + pending count. Never exceeds 2 by design;
    /// exposed so tests can assert that rather than trust it.
    private(set) var peakOutstandingRequests = 0
    /// Renders actually started, as opposed to requests received.
    private(set) var startedRenderCount = 0

    init(renderer: any PreviewRendering, source: CGImage, identity: PhotoFingerprint) {
        self.renderer = renderer
        self.source = source
        self.identity = identity
    }

    /// Requests a render and waits for its outcome.
    ///
    /// Never throws: every request resolves to exactly one outcome, so a
    /// caller cannot be left suspended by a replaced or cancelled request.
    func render(_ recipe: DevelopRecipe, revision: UInt64) async -> PreviewRenderOutcome {
        await withCheckedContinuation { continuation in
            accept(Job(revision: revision, recipe: recipe, continuation: continuation))
        }
    }

    /// Abandons every request at or below `revision`: cancels the running
    /// render, resolves the waiting one, and refuses late arrivals.
    ///
    /// Requests newer than `revision` are left alone: cancel messages travel
    /// in their own tasks and can arrive after the caller has already issued
    /// a newer request, which must not be killed by the older intent.
    func cancel(through revision: UInt64) {
        newestAcceptedRevision = max(newestAcceptedRevision, revision)
        if let running = inFlight, running.revision <= revision {
            running.task.cancel()
        }
        if let waiting = pending, waiting.revision <= revision {
            waiting.continuation.resume(returning: .cancelled)
            pending = nil
        }
    }

    /// Permanently stops the scheduler; later requests resolve as cancelled.
    func close() {
        isClosed = true
        cancel(through: .max)
    }

    /// Returns once nothing is running or waiting. For tests and teardown.
    func waitUntilIdle() async {
        while let running = inFlight?.task {
            await running.value
        }
    }

    // MARK: - Queue

    private func accept(_ job: Job) {
        guard !isClosed else {
            return job.continuation.resume(returning: .cancelled)
        }
        guard job.revision > newestAcceptedRevision else {
            return job.continuation.resume(returning: .superseded)
        }
        newestAcceptedRevision = job.revision

        if inFlight == nil {
            start(job)
        } else {
            pending?.continuation.resume(returning: .superseded)
            pending = job
        }
        recordOutstandingCount()
    }

    private func start(_ job: Job) {
        startedRenderCount += 1
        inFlight = (job.revision, Task { await self.execute(job) })
    }

    private func execute(_ job: Job) async {
        let outcome = await outcome(rendering: job.recipe)
        job.continuation.resume(returning: outcome)
        inFlight = nil
        startPendingIfAny()
    }

    private func startPendingIfAny() {
        guard let next = pending else { return }
        pending = nil
        start(next)
        recordOutstandingCount()
    }

    private func outcome(rendering recipe: DevelopRecipe) async -> PreviewRenderOutcome {
        do {
            let image = try await renderer.renderPreview(source, identity: identity, with: recipe)
            // Core Image renders do not observe cancellation, so a render
            // cancelled mid-way still completes; it must not report success.
            return Task.isCancelled ? .cancelled : .rendered(image)
        } catch {
            return Task.isCancelled || error is CancellationError ? .cancelled : .failed(error)
        }
    }

    private func recordOutstandingCount() {
        let outstanding = (inFlight == nil ? 0 : 1) + (pending == nil ? 0 : 1)
        peakOutstandingRequests = max(peakOutstandingRequests, outstanding)
    }
}
