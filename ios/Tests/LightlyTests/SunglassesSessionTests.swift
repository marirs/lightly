import CoreGraphics
import XCTest
@testable import Lightly

/// Portrait › Sunglasses in the editing session (rendering-v2 §7.5): the analysis runs on demand and is kept with the
/// session; choosing a pair for a face wearing glasses paints them out first and commits one undo step; None keeps the
/// fill; Undo takes the pair off. Real models (Vision, the two Sunglasses models, LaMa) on a licensed test photo.
@MainActor
final class SunglassesSessionTests: XCTestCase {

    private var sessionDirectory: URL!

    override func setUp() async throws {
        sessionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("sunglasses-session-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: sessionDirectory)
    }

    private func session(store: EditSessionStore) async throws -> EditorSession {
        let data = try Data(contentsOf: DevelopParityTests.fixture("experiments/test-photos/glasses_side_angle_01.jpg"))
        let photo = try await ImageIOPhotoLoader().loadPhoto(from: data, source: .photoLibrary)
        let session = EditorSession(photo: photo, library: try EditorTestSupport.library(), personDetector: FixedPersonDetector(result: true),
                                    sceneAnalyser: OnDeviceSceneAnalyser(depthEstimators: DepthEstimatorProvider()), previewLongEdge: 1_024,
                                    inpainterLoader: { LamaInpainter.loadBundled() }, sessionStore: store)
        session.start()
        await session.waitUntilReady()
        await session.settleRendering()
        return session
    }

    func testChoosingAPairPaintsTheOwnGlassesOutAndNoneKeepsTheFill() async throws {
        let store = EditSessionStore(directory: sessionDirectory)
        let session = try await session(store: store)
        let face = try XCTUnwrap(session.people?.usableFaces.first, "Vision finds the face")
        XCTAssertFalse(session.sunglassesAnalysed)

        session.ensureSunglassesAnalysis()
        XCTAssertTrue(session.sunglassesAnalysing)
        await session.debugAwaitPendingAnalysis()
        XCTAssertFalse(session.sunglassesAnalysing)
        let analysis = try XCTUnwrap(session.sunglassesAnalysis(for: face))
        XCTAssertTrue(analysis.isReadable)
        XCTAssertNotNil(analysis.glassesMask(), "he is wearing glasses")

        let wayfarer = try XCTUnwrap(SunglassesPack.bundled?.pairs.first { $0.name == "Wayfarer" })
        let before = session.recipe
        session.setSunglassesPair(wayfarer.id, forFace: face)
        XCTAssertTrue(session.sunglassesRemoving)
        XCTAssertEqual(session.recipe, before, "nothing is committed until the fill lands")
        await session.debugAwaitPendingAnalysis()
        await session.settleRendering()
        XCTAssertFalse(session.sunglassesRemoving)
        let worn = try XCTUnwrap(session.recipe.tools.portrait.faces.first { $0.face.box == face.box }?.sunglasses)
        XCTAssertEqual(worn.pair, wayfarer.id)
        let removed = try XCTUnwrap(worn.removed, "his own glasses are painted out")
        XCTAssertNotNil(session.removePatches.patch(removed.patch.sha256))
        XCTAssertEqual(removed.patch.model, LamaInpainter.modelRef)

        // None keeps the fill (choosing a pair again does not recompute it); the renderer skips it without a pair.
        session.setSunglassesPair(nil, forFace: face)
        let none = try XCTUnwrap(session.recipe.tools.portrait.faces.first { $0.face.box == face.box }?.sunglasses)
        XCTAssertNil(none.pair)
        XCTAssertEqual(none.removed, removed)
        session.setSunglassesPair(wayfarer.id, forFace: face)
        XCTAssertFalse(session.sunglassesRemoving, "the stored fill is reused")
        XCTAssertEqual(session.recipe.tools.portrait.faces.first { $0.face.box == face.box }?.sunglasses?.removed, removed)

        // Undo steps back through: pair again → None → the pair → no sunglasses.
        session.undo(); session.undo(); session.undo()
        XCTAssertNil(session.recipe.tools.portrait.faces.first { $0.face.box == face.box }?.sunglasses?.pair)
        await session.settleRendering()

        // The analysis is stored with the session and reads back unchanged.
        store.flush()
        let saved = try XCTUnwrap(EditSessionStore(directory: sessionDirectory).load())
        let restored = try XCTUnwrap(saved.analysis.sunglasses?.first { $0.faceBox == face.box })
        XCTAssertEqual(restored, analysis)
        session.close()
        await session.debugAwaitQuiescence()
    }
}
