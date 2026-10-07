import XCTest
@testable import Lightly

/// Save copy releases the Remove model (2026-10-07: 956 MB peak footprint at 48 MP with it loaded); the completed fill
/// stays and the next stroke loads the model again. Long operations hold the phone awake only while they run.
@MainActor
final class RemoveModelReleaseTests: XCTestCase {
    private final class CountingLoader: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var loads: Int { lock.withLock { count } }
        func load() -> (any Inpainting)? { lock.withLock { count += 1 }; return FlatInpainter() }
    }

    func testSaveCopyReleasesTheRemoveModelKeepsTheFillAndTheNextStrokeReloadsIt() async throws {
        let loader = CountingLoader()
        let session = EditorSession(photo: try await EditorTestSupport.photo(), library: try EditorTestSupport.library(),
                                    personDetector: FixedPersonDetector(result: false), libraryWriter: SpyLibraryWriter(),
                                    previewLongEdge: 640, inpainterLoader: { loader.load() })
        session.start()
        await session.waitUntilReady()
        await session.debugRemove(points: [.init(x: 0.5, y: 0.5)], radius: 0.03)
        XCTAssertEqual(session.recipe.tools.edit.remove.strokes.count, 1)
        XCTAssertEqual(loader.loads, 1)
        let afterStroke = session.recipe

        XCTAssertEqual(KeepAwake.activeReasons, [], "nothing holds the phone awake once the stroke is done")
        session.saveCopy()
        XCTAssertEqual(KeepAwake.activeReasons, ["save copy"])
        await EditorTestSupport.waitForSave(session)
        guard case .saved = session.saveState else { return XCTFail("save did not finish: \(session.saveState)") }
        XCTAssertEqual(KeepAwake.activeReasons, [], "released when the save completes")
        XCTAssertEqual(session.recipe, afterStroke, "the fill is kept")

        await session.debugRemove(points: [.init(x: 0.3, y: 0.3)], radius: 0.03)
        XCTAssertEqual(session.removeState, .idle)
        XCTAssertEqual(session.recipe.tools.edit.remove.strokes.count, 2, "another stroke works after the release")
        XCTAssertEqual(loader.loads, 2, "the model was loaded again")
        await session.settleRendering()
    }

    /// Save copy composites the fills into its own source buffer (no extra frame); the bytes it writes are exactly the
    /// reference export's, which composites them inside the render.
    func testSaveCopyWithFillsWritesTheReferenceBytes() async throws {
        let writer = SpyLibraryWriter()
        let session = try await EditorTestSupport.readySession(writer: writer, inpainter: FlatInpainter())
        await session.debugRemove(points: [.init(x: 0.5, y: 0.5), .init(x: 0.6, y: 0.55)], radius: 0.04)
        await session.debugRemove(points: [.init(x: 0.2, y: 0.3)], radius: 0.03)
        XCTAssertEqual(session.recipe.tools.edit.remove.strokes.count, 2)
        let reference = try await session.exportedData()
        session.saveCopy()
        await EditorTestSupport.waitForSave(session)
        let saved = await writer.savedData
        XCTAssertNotNil(saved)
        XCTAssertTrue(saved == reference, "Save copy with fills matches the reference export byte for byte")
        await session.settleRendering()
    }
}
