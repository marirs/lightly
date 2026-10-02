import CoreGraphics
import XCTest
@testable import Lightly

/// A deliberately slow renderer that encodes the recipe's exposure in the red
/// channel, so tests can tell from pixels *which* request reached the screen.
/// Being an actor that suspends mid-render, it also measures real concurrency.
actor SlowEncodingRenderer: PreviewRendering {
    private let delay: Duration
    /// Core Image renders run to completion even when cancelled; this mode
    /// reproduces that so tests cannot pass merely because a sleep threw.
    private let ignoresCancellation: Bool
    private(set) var callCount = 0
    private(set) var completedCount = 0
    private(set) var peakConcurrentRenders = 0
    private var activeRenders = 0

    init(delay: Duration = .milliseconds(40), ignoresCancellation: Bool = false) {
        self.delay = delay
        self.ignoresCancellation = ignoresCancellation
    }

    private func pause() async throws {
        guard ignoresCancellation else {
            return try await Task.sleep(for: delay)
        }
        let nanoseconds = UInt64(delay.components.attoseconds / 1_000_000_000)
            + UInt64(delay.components.seconds) * 1_000_000_000
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                continuation.resume()
            }
        }
    }

    func renderPreview(
        _ source: CGImage,
        identity: PhotoFingerprint,
        with recipe: DevelopRecipe
    ) async throws -> CGImage {
        callCount += 1
        activeRenders += 1
        peakConcurrentRenders = max(peakConcurrentRenders, activeRenders)
        defer { activeRenders -= 1 }

        try await pause()
        completedCount += 1
        return TestFixtures.makeSolidImage(
            width: 8, height: 8,
            red: Self.encodedRed(for: recipe), green: 0, blue: 0
        )
    }

    static func encodedRed(for recipe: DevelopRecipe) -> Double {
        max(0, min(1, recipe.exposure))
    }
}

@MainActor
final class RenderSchedulingTests: XCTestCase {

    // The editor-level latest-wins tests moved with the editor: see
    // LUTEditSessionTests (rapid Look changes, settling a stale preview)
    // and LUTEditorViewModelTests. These cover the shared scheduler.

    // MARK: - Scheduler in isolation

    func testSchedulerResolvesReplacedRequestsAsSupersededAndRefusesStaleOnes() async {
        let renderer = SlowEncodingRenderer()
        let photo = TestFixtures.makePhoto()
        let scheduler = PreviewRenderScheduler(renderer: renderer, source: photo.image, identity: photo.fingerprint)
        func recipe(exposure: Double) -> DevelopRecipe {
            var recipe = DevelopRecipe.unmodified
            recipe.exposure = exposure
            return recipe
        }

        // Short sleeps fix arrival order; the 40 ms render keeps the first
        // request in flight while the others arrive.
        async let first = scheduler.render(recipe(exposure: 0.1), revision: 1)
        try? await Task.sleep(for: .milliseconds(5))
        async let replaced = scheduler.render(recipe(exposure: 0.2), revision: 2)
        try? await Task.sleep(for: .milliseconds(5))
        async let newest = scheduler.render(recipe(exposure: 0.3), revision: 3)
        try? await Task.sleep(for: .milliseconds(5))
        async let stale = scheduler.render(recipe(exposure: 0.2), revision: 2)

        let outcomes = await [first, replaced, newest, stale]
        XCTAssertEqual(outcomes.map(Self.label), ["rendered", "superseded", "rendered", "superseded"])
        if case .rendered(let image) = outcomes[2] {
            XCTAssertEqual(TestFixtures.meanColour(of: image).red, 0.3, accuracy: 0.01)
        }
        let peak = await scheduler.peakOutstandingRequests
        XCTAssertEqual(peak, 2)
    }

    // MARK: - Cancellation is bounded by revision

    private func makeScheduler() -> PreviewRenderScheduler {
        let photo = TestFixtures.makePhoto()
        return PreviewRenderScheduler(
            renderer: SlowEncodingRenderer(), source: photo.image, identity: photo.fingerprint
        )
    }

    private static func recipe(exposure: Double) -> DevelopRecipe {
        var recipe = DevelopRecipe.unmodified
        recipe.exposure = exposure
        return recipe
    }

    /// Codex finding: `cancel(through: 1)` also cancelled revision 2.
    func testOlderCancellationSparesANewerPendingRequest() async {
        let scheduler = makeScheduler()

        async let first = scheduler.render(Self.recipe(exposure: 0.1), revision: 1)
        try? await Task.sleep(for: .milliseconds(5))
        async let second = scheduler.render(Self.recipe(exposure: 0.2), revision: 2)
        try? await Task.sleep(for: .milliseconds(5))
        await scheduler.cancel(through: 1)

        let outcomes = await [first, second]
        XCTAssertEqual(outcomes.map(Self.label), ["cancelled", "rendered"])
        if case .rendered(let image) = outcomes[1] {
            XCTAssertEqual(TestFixtures.meanColour(of: image).red, 0.2, accuracy: 0.01)
        }
    }

    func testOlderCancellationSparesANewerRunningRequest() async {
        let scheduler = makeScheduler()
        _ = await scheduler.render(Self.recipe(exposure: 0.1), revision: 1)

        async let second = scheduler.render(Self.recipe(exposure: 0.2), revision: 2)
        try? await Task.sleep(for: .milliseconds(5))
        await scheduler.cancel(through: 1)

        let outcome = await second
        XCTAssertEqual(Self.label(outcome), "rendered")
    }

    func testCancellationThroughTheNewestRevisionCancelsRunningAndPending() async {
        let scheduler = makeScheduler()

        async let first = scheduler.render(Self.recipe(exposure: 0.1), revision: 1)
        try? await Task.sleep(for: .milliseconds(5))
        async let second = scheduler.render(Self.recipe(exposure: 0.2), revision: 2)
        try? await Task.sleep(for: .milliseconds(5))
        await scheduler.cancel(through: 2)

        let outcomes = await [first, second]
        XCTAssertEqual(outcomes.map(Self.label), ["cancelled", "cancelled"])
    }

    private static func label(_ outcome: PreviewRenderOutcome) -> String {
        switch outcome {
        case .rendered: return "rendered"
        case .superseded: return "superseded"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        }
    }
}
