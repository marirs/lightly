import CoreGraphics
import XCTest
@testable import Lightly

/// A scene analyser whose matte and depth can each stall (until cancelled), fail or succeed, to check
/// that Background waits only for what an operation needs and that leaving, closing and Cancel stay
/// responsive while analysis is pending.
private struct ScriptedSceneAnalyser: SceneAnalysing {
    enum Outcome: Sendable { case succeed, fail, stall }
    var matte: Outcome
    var depth: Outcome

    private static func run<T>(_ outcome: Outcome, _ value: @autoclosure () -> T) async throws -> T {
        switch outcome {
        case .succeed: return value()
        case .fail: throw SceneAnalysisError.depthUnavailable("scripted failure")
        case .stall:
            // Stands in for a model that never returns; only cancellation ends it.
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
    }

    func subjectMatte(for image: CGImage) async throws -> SubjectMatte? {
        try await Self.run(matte, SubjectMatte(matte: FloatImage(width: 8, height: 8, channels: 1, repeating: 1), model: SubjectMatte.visionModel))
    }
    func people(in image: CGImage) async -> PeopleAnalysis { PeopleAnalysis(faces: [], people: []) }
    func disparity(for image: CGImage, originalData: Data) async throws -> DisparityMap {
        try await Self.run(depth, DisparityMap(disparity: FloatImage(width: 8, height: 8, channels: 1, repeating: 0.5),
                                               source: .estimated, model: SubjectMatte.visionModel))
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
        session.analyseSubjectIfNeeded()
        await wait(session) { session.subjectState == .ready }
        XCTAssertEqual(session.backgroundState(needsDepth: false), .ready, "Change background is usable with the matte alone")
        XCTAssertEqual(session.backgroundState(needsDepth: true), .separating, "Focus & Blur still shows Finding the subject…")
        session.commitBackground { $0.replacement = .colour("#1F2328") }
        XCTAssertEqual(session.recipe.tools.background.replacement, .colour("#1F2328"))

        // Cancel from Focus & Blur stops the pending depth only; the matte and the edit stay.
        session.cancelSubjectSeparation()
        XCTAssertEqual(session.depthState, .notStarted)
        XCTAssertEqual(session.subjectState, .ready)
        XCTAssertEqual(session.toast, "Cancelled · nothing changed")
        session.close()
        await session.debugAwaitQuiescence()
    }

    func testDepthFailureLeavesChangeBackgroundWorkingAndFocusRecoverable() async throws {
        let session = try await session(matte: .succeed, depth: .fail)
        session.analyseSubjectIfNeeded()
        await wait(session) { session.subjectState == .ready && session.depthState == .failed }
        XCTAssertEqual(session.backgroundState(needsDepth: false), .ready)
        XCTAssertEqual(session.backgroundState(needsDepth: true), .failed, "\"Couldn't separate the subject.\" with Try again")
        session.retrySubjectSeparation()
        XCTAssertEqual(session.subjectState, .ready, "Try again reruns only what failed")
        await wait(session) { session.depthState == .failed }
        session.close()
        await session.debugAwaitQuiescence()
    }

    func testMatteFailureIsRecoverable() async throws {
        let session = try await session(matte: .fail, depth: .succeed)
        session.analyseSubjectIfNeeded()
        await wait(session) { session.subjectState == .failed && session.depthState == .ready }
        XCTAssertEqual(session.backgroundState(needsDepth: false), .failed)
        XCTAssertEqual(session.backgroundState(needsDepth: true), .failed)
        session.retrySubjectSeparation()
        XCTAssertEqual(session.subjectState, .separating)
        XCTAssertEqual(session.depthState, .ready, "depth is not run again")
        await wait(session) { session.subjectState == .failed }
        session.close()
        await session.debugAwaitQuiescence()
    }

    func testCancelWhileBothPendingReturnsAtOnce() async throws {
        let session = try await session(matte: .stall, depth: .stall)
        session.analyseSubjectIfNeeded()
        XCTAssertEqual(session.backgroundState(needsDepth: false), .separating)
        session.cancelSubjectSeparation()
        XCTAssertEqual(session.subjectState, .notStarted)
        XCTAssertEqual(session.depthState, .notStarted)
        // Nothing left running: quiescence returns although both analyses would never finish.
        let started = ContinuousClock.now
        await session.debugAwaitQuiescence()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    /// Leaving the photo (Choose another photo, Back) closes the session: stalled analysis is
    /// cancelled and never touches the closed session.
    func testClosingWithStalledAnalysisIsPrompt() async throws {
        let session = try await session(matte: .stall, depth: .stall)
        session.analyseSubjectIfNeeded()
        session.close()
        let started = ContinuousClock.now
        await session.debugAwaitQuiescence()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
        XCTAssertEqual(session.subjectState, .separating, "a closed session's state is left as it was, not marked failed")
    }
}
