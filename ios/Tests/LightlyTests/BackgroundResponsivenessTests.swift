import CoreGraphics
import XCTest
@testable import Lightly

/// A scene analyser whose matte and depth can each stall (until cancelled), fail or succeed, to check
/// that Background waits only for what an operation needs and that leaving, closing and Cancel stay
/// responsive while analysis is pending.
private struct ScriptedSceneAnalyser: SceneAnalysing {
    enum Outcome: Sendable { case succeed, fail, stall, lateSucceed, noSubject }
    var matte: Outcome
    var depth: Outcome

    private static func run<T>(_ outcome: Outcome, _ value: @autoclosure () -> T) async throws -> T {
        switch outcome {
        case .succeed: return value()
        case .fail: throw SceneAnalysisError.depthUnavailable("scripted failure")
        case .noSubject: return value()
        case .stall:
            // Stands in for a model that never returns; only cancellation ends it.
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        case .lateSucceed:
            // A model that ignores cancellation and returns anyway, a little later.
            try? await Task.sleep(for: .milliseconds(300))
            return value()
        }
    }

    func subjectMatte(for image: CGImage) async throws -> SubjectMatte? {
        if matte == .noSubject { return nil }
        return try await Self.run(matte, SubjectMatte(matte: FloatImage(width: 8, height: 8, channels: 1, repeating: 1), model: SubjectMatte.visionModel))
    }
    func people(in image: CGImage) async -> PeopleAnalysis { PeopleAnalysis(faces: [], people: []) }
    func disparity(for image: CGImage, originalData: Data) async throws -> DisparityMap {
        try await Self.run(depth, DisparityMap(disparity: FloatImage(width: 8, height: 8, channels: 1, repeating: 0.5),
                                               source: .estimated, model: SubjectMatte.visionModel))
    }
    func personMatte(for image: CGImage) async -> FloatImage? { nil }
}

/// Depth call 1 returns after 300 ms whatever happens; every later call stalls until cancelled.
private final class SequencedDepthAnalyser: SceneAnalysing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func subjectMatte(for image: CGImage) async throws -> SubjectMatte? {
        SubjectMatte(matte: FloatImage(width: 8, height: 8, channels: 1, repeating: 1), model: SubjectMatte.visionModel)
    }
    func people(in image: CGImage) async -> PeopleAnalysis { PeopleAnalysis(faces: [], people: []) }
    func disparity(for image: CGImage, originalData: Data) async throws -> DisparityMap {
        let call = lock.withLock { calls += 1; return calls }
        if call == 1 { try? await Task.sleep(for: .milliseconds(300)) } else {
            try await Task.sleep(for: .seconds(3600)); throw CancellationError()
        }
        return DisparityMap(disparity: FloatImage(width: 8, height: 8, channels: 1, repeating: 0.5), source: .estimated, model: SubjectMatte.visionModel)
    }
    func personMatte(for image: CGImage) async -> FloatImage? { nil }
}

@MainActor
final class BackgroundResponsivenessTests: XCTestCase {

    private func session(matte: ScriptedSceneAnalyser.Outcome, depth: ScriptedSceneAnalyser.Outcome) async throws -> EditorSession {
        let session = EditorSession(photo: try await EditorTestSupport.photo(), library: try EditorTestSupport.library(),
                                    personDetector: FixedPersonDetector(result: false),
                                    sceneAnalyser: ScriptedSceneAnalyser(matte: matte, depth: depth),
                                    previewLongEdge: 640, inpainterLoader: { nil })
        session.start()
        await session.waitUntilReady()
        return session
    }

    /// Waits for `condition`, failing instead of hanging when it never holds.
    private func wait(_ session: EditorSession, seconds: Double = 10, until condition: @escaping () -> Bool) async {
        let waiter = Task { await session.debugWait(until: condition) }
        let timeout = Task { try? await Task.sleep(for: .seconds(seconds)); waiter.cancel() }
        await waiter.value
        timeout.cancel()
        XCTAssertTrue(condition(), "timed out")
    }

    func testChangeBackgroundDoesNotWaitForStalledDepth() async throws {
        let session = try await session(matte: .succeed, depth: .stall)
        session.analyseSubjectIfNeeded(needsDepth: true)
        await wait(session) { session.subjectState == .ready }
        XCTAssertEqual(session.backgroundContent(needsDepth: false), .controls, "Change background is usable with the matte alone")
        XCTAssertEqual(session.backgroundContent(needsDepth: true), .estimatingDepth, "Focus & Blur shows depth's own progress, not the subject's")
        XCTAssertTrue(session.depthProgressVisible(needsDepth: true))
        XCTAssertFalse(session.depthProgressVisible(needsDepth: false), "Change background shows no depth progress")
        session.commitBackground { $0.replacement = .colour("#1F2328") }
        XCTAssertEqual(session.recipe.tools.background.replacement, .colour("#1F2328"))

        // Cancel from Focus & Blur stops the pending depth only; the matte and the edit stay.
        session.cancelSubjectSeparation()
        XCTAssertEqual(session.depthState, .cancelled)
        XCTAssertEqual(session.subjectState, .ready)
        XCTAssertEqual(session.backgroundContent(needsDepth: true), .controls, "Cancel returns to the panel")
        XCTAssertEqual(session.toast, "Cancelled · nothing changed")
        session.close()
        await session.debugAwaitQuiescence()
    }

    /// Change background never starts the depth model; switching to Focus & Blur does.
    func testChangeBackgroundDoesNotStartDepth() async throws {
        let session = try await session(matte: .succeed, depth: .stall)
        session.analyseSubjectIfNeeded(needsDepth: false)
        await wait(session) { session.subjectState == .ready }
        XCTAssertEqual(session.depthState, .notStarted, "no depth for Change background")
        XCTAssertEqual(session.backgroundContent(needsDepth: false), .controls)
        session.analyseSubjectIfNeeded(needsDepth: true)
        XCTAssertEqual(session.depthState, .estimating, "Focus & Blur starts depth")
        session.close()
        await session.debugAwaitQuiescence()
    }

    /// No clear subject: the approved notice at once in either mode, never waiting for depth; depth starts only
    /// when Blur is used, and its progress is shown as depth's.
    func testNoSubjectShowsTheNoticeWithoutWaitingForDepth() async throws {
        let session = try await session(matte: .noSubject, depth: .stall)
        session.analyseSubjectIfNeeded(needsDepth: false)
        await wait(session) { session.subjectState == .noSubject }
        XCTAssertEqual(session.depthState, .notStarted)
        XCTAssertEqual(session.backgroundContent(needsDepth: false), .noSubject, "Change background: the notice, not Finding the subject…")
        XCTAssertEqual(session.backgroundContent(needsDepth: true), .noSubject)
        XCTAssertFalse(session.depthProgressVisible(needsDepth: false))
        session.previewBackground { $0.focus.blur = 30 }
        XCTAssertEqual(session.depthState, .estimating, "Blur asks for depth")
        XCTAssertEqual(session.backgroundContent(needsDepth: false), .noSubject, "the notice and slider stay")
        session.commitBackground { $0.focus.blur = 30 }
        XCTAssertTrue(session.depthProgressVisible(needsDepth: false), "depth progress while the blur waits")
        session.cancelSubjectSeparation()
        XCTAssertEqual(session.depthState, .cancelled)
        XCTAssertFalse(session.depthProgressVisible(needsDepth: false))
        session.close()
        await session.debugAwaitQuiescence()
    }

    /// A cancelled depth run that returns late (the model load cannot be interrupted) must not complete the newer
    /// run started after it.
    func testALateResultCannotOverwriteANewerRun() async throws {
        let analyser = SequencedDepthAnalyser()
        let session = EditorSession(photo: try await EditorTestSupport.photo(), library: try EditorTestSupport.library(),
                                    personDetector: FixedPersonDetector(result: false), sceneAnalyser: analyser,
                                    previewLongEdge: 640, inpainterLoader: { nil })
        session.start()
        await session.waitUntilReady()
        session.analyseSubjectIfNeeded(needsDepth: true) // depth call 1: returns late, ignoring cancellation
        await wait(session) { session.subjectState == .ready }
        session.cancelSubjectSeparation()
        session.commitBackground { $0.focus.blur = 40 } // depth call 2: stalls
        XCTAssertEqual(session.depthState, .estimating)
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(session.depthState, .estimating, "call 1's late result did not complete call 2")
        session.close()
        await session.debugAwaitQuiescence()
    }

    func testDepthFailureLeavesChangeBackgroundWorkingAndFocusRecoverable() async throws {
        let session = try await session(matte: .succeed, depth: .fail)
        session.analyseSubjectIfNeeded(needsDepth: true)
        await wait(session) { session.subjectState == .ready && session.depthState == .failed }
        XCTAssertEqual(session.backgroundContent(needsDepth: false), .controls)
        XCTAssertEqual(session.backgroundContent(needsDepth: true), .depthFailed, "a depth failure, not a subject failure")
        session.retrySubjectSeparation()
        XCTAssertEqual(session.subjectState, .ready, "Try again reruns only what failed")
        await wait(session) { session.depthState == .failed }
        session.close()
        await session.debugAwaitQuiescence()
    }

    func testMatteFailureIsRecoverable() async throws {
        let session = try await session(matte: .fail, depth: .succeed)
        session.analyseSubjectIfNeeded(needsDepth: true)
        await wait(session) { session.subjectState == .failed && session.depthState == .ready }
        XCTAssertEqual(session.backgroundContent(needsDepth: false), .subjectFailed)
        XCTAssertEqual(session.backgroundContent(needsDepth: true), .subjectFailed)
        session.retrySubjectSeparation()
        XCTAssertEqual(session.subjectState, .separating)
        XCTAssertEqual(session.depthState, .ready, "depth is not run again")
        await wait(session) { session.subjectState == .failed }
        session.close()
        await session.debugAwaitQuiescence()
    }

    func testCancelWhileBothPendingReturnsAtOnce() async throws {
        let session = try await session(matte: .stall, depth: .stall)
        session.analyseSubjectIfNeeded(needsDepth: true)
        XCTAssertEqual(session.backgroundContent(needsDepth: false), .finding)
        session.cancelSubjectSeparation()
        XCTAssertEqual(session.subjectState, .cancelled)
        XCTAssertEqual(session.depthState, .cancelled)
        XCTAssertEqual(session.backgroundContent(needsDepth: false), .controls)
        // Nothing left running: quiescence returns although both analyses would never finish.
        let started = ContinuousClock.now
        await session.debugAwaitQuiescence()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    /// Leaving the photo (Choose another photo, Back) closes the session: stalled analysis is
    /// cancelled and never touches the closed session.
    func testClosingWithStalledAnalysisIsPrompt() async throws {
        let session = try await session(matte: .stall, depth: .stall)
        session.analyseSubjectIfNeeded(needsDepth: true)
        session.close()
        let started = ContinuousClock.now
        await session.debugAwaitQuiescence()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertEqual(session.subjectState, .separating, "a closed session's state is left as it was, not marked failed")
    }

    /// Cancel → leave the tool → reopen → retry (owner check 2026-10-05): Cancel returns to the panel, keeps the
    /// committed edit, drops the cancelled work's late result, is not undone by reopening the panel, and the next
    /// Background edit starts the analysis again.
    func testCancelLeaveReopenRetry() async throws {
        let session = try await session(matte: .lateSucceed, depth: .lateSucceed)
        session.commitEdit { $0.adjust.exposure = 20 }
        let committed = session.recipe
        session.analyseSubjectIfNeeded(needsDepth: true)
        XCTAssertEqual(session.backgroundContent(needsDepth: true), .finding)
        session.cancelSubjectSeparation()
        XCTAssertEqual(session.backgroundContent(needsDepth: true), .controls, "back to the panel, no indicator")
        XCTAssertEqual(session.recipe, committed, "the committed edit is kept")
        XCTAssertEqual(session.toast, "Cancelled · nothing changed")

        // The cancelled analyses return anyway (they ignore cancellation): their results are dropped.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(session.subjectState, .cancelled, "a late result of cancelled work is ignored")
        XCTAssertEqual(session.depthState, .cancelled)

        // Leaving the tool and reopening it runs the panel's .task again: it does not restart cancelled work.
        session.analyseSubjectIfNeeded(needsDepth: true)
        XCTAssertEqual(session.subjectState, .cancelled)

        // The next Background edit retries.
        session.commitBackground { $0.focus.blur = 40 }
        XCTAssertEqual(session.subjectState, .separating)
        XCTAssertEqual(session.depthState, .estimating)
        await wait(session) { session.subjectState == .ready && session.depthState == .ready }
        XCTAssertEqual(session.backgroundContent(needsDepth: true), .controls)
        XCTAssertEqual(session.recipe.tools.background.focus.blur, 40)
        session.close()
        await session.debugAwaitQuiescence()
    }
}
