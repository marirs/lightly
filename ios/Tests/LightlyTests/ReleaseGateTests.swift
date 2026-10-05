import CoreGraphics
import XCTest
@testable import Lightly

/// The release gates closed (no depth model, no LaMa, legal sign-off pending): Focus & Blur and
/// Remove show their approved failure states and change nothing; nothing crashes.
private struct NoDepthSceneAnalyser: SceneAnalysing {
    func subjectMatte(for image: CGImage) async throws -> SubjectMatte? {
        SubjectMatte(matte: FloatImage(width: 8, height: 8, channels: 1, repeating: 1), model: SubjectMatte.visionModel)
    }
    func people(in image: CGImage) async -> PeopleAnalysis { PeopleAnalysis(faces: [], people: []) }
    func disparity(for image: CGImage, originalData: Data) async throws -> DisparityMap {
        // What OnDeviceSceneAnalyser throws when the depth model's release gate is closed.
        throw SceneAnalysisError.depthUnavailable("no depth model in this build")
    }
    func personMatte(for image: CGImage) async -> FloatImage? { nil }
}

@MainActor
final class ReleaseGateTests: XCTestCase {

    func testFocusAndBlurWithoutDepthShowsTheApprovedFailureAndChangesNothing() async throws {
        let photo = try await EditorTestSupport.photo()
        let session = EditorSession(photo: photo, library: try EditorTestSupport.library(), personDetector: FixedPersonDetector(result: false),
                                    sceneAnalyser: NoDepthSceneAnalyser(), previewLongEdge: 640, inpainterLoader: { nil })
        session.start()
        await session.waitUntilReady()
        let before = session.recipe
        session.analyseSubjectIfNeeded()
        await session.debugWaitForSubject()
        XCTAssertEqual(session.backgroundContent(needsDepth: true), .depthFailed, "the depth failure — never a matte-only blur")
        XCTAssertEqual(session.backgroundContent(needsDepth: false), .controls, "Change background needs only the matte")
        XCTAssertEqual(session.recipe, before)
        await session.settleRendering()
    }

    func testRemoveWithoutTheModelFailsAndChangesNothing() async throws {
        let session = try await EditorTestSupport.readySession(inpainter: nil)
        let before = session.recipe
        session.removeStroke(points: [.init(x: 0.5, y: 0.5)], radius: 0.03)
        await session.debugAwaitQuiescence()
        XCTAssertEqual(session.removeState, .failed)
        XCTAssertEqual(session.recipe, before)
    }
}
