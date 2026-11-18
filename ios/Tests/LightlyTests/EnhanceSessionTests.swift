import CoreGraphics
import ImageIO
import XCTest
@testable import Lightly

/// Edit › Enhance in the editor (owner-approved design 2026-11-18, `ed-enhance*`; rendering-v2 §7.6): one undo step
/// holding a stored result that replaces the source under every other edit, Cancel and failure leaving the edit as it
/// was, and a saved copy at the result's size.
@MainActor
final class EnhanceSessionTests: XCTestCase {
    /// Stands in for the engine: the photo drawn at twice its size (or a failure, or a run that waits to be cancelled).
    private final class FakeEnhancer: Enhancing, @unchecked Sendable {
        enum Mode { case succeed(painting: Bool), fail, waitForCancel }
        private let lock = NSLock()
        private var runs = 0
        let mode: Mode
        init(_ mode: Mode) { self.mode = mode }
        var runCount: Int { lock.withLock { runs } }

        func enhance(_ photo: CGImage, isCancelled: () -> Bool, progress: (Double) -> Void) throws -> EnhanceEngine.Result {
            lock.withLock { runs += 1 }
            switch mode {
            case .fail:
                throw EnhanceEngine.Failure.modelFailed("test failure")
            case .waitForCancel:
                while !isCancelled() { Thread.sleep(forTimeInterval: 0.01) }
                throw EnhanceEngine.Failure.cancelled
            case .succeed(let painting):
                progress(0.5)
                let width = photo.width * 2, height = photo.height * 2
                let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: ColorPipeline.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.interpolationQuality = .high
                context.draw(photo, in: CGRect(x: 0, y: 0, width: width, height: height))
                progress(1)
                return .init(image: context.makeImage()!, isPainting: painting, faces: [])
            }
        }
    }

    private func waitWhileEnhancing(_ session: EditorSession, timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while session.enhanceState == .enhancing, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testEnhanceIsOneUndoStepWithTheStoredResultAndResetUndoesIt() async throws {
        let store = EnhanceResultStore()
        let session = try await EditorTestSupport.readySession(enhancer: FakeEnhancer(.succeed(painting: false)), enhanceResults: store)
        let before = session.recipe
        session.enhancePhoto()
        XCTAssertEqual(session.enhanceState, .enhancing)
        await waitWhileEnhancing(session)
        XCTAssertEqual(session.enhanceState, .idle)
        let enhance = try XCTUnwrap(session.recipe.tools.edit.enhance)
        XCTAssertEqual(enhance.result.width, session.photo.image.width * 2)
        XCTAssertEqual(enhance.result.height, session.photo.image.height * 2)
        XCTAssertEqual(enhance.result.model, EditorSession.enhanceModel)
        XCTAssertFalse(enhance.painting)
        XCTAssertNotNil(store.image(enhance.result.sha256), "the result is stored by its digest")
        XCTAssertEqual(session.toast, "Enhanced")
        XCTAssertTrue(session.canReset(section: "edit", adjustment: "enhance"))

        session.undo()
        XCTAssertNil(session.recipe.tools.edit.enhance, "Undo takes it back")
        session.redo()
        XCTAssertEqual(session.recipe.tools.edit.enhance, enhance, "Redo brings the same result back, not a new run")

        session.resetEdits(section: "edit", adjustment: "enhance")
        XCTAssertNil(session.recipe.tools.edit.enhance)
        XCTAssertEqual(session.recipe.tools, before.tools, "Reset leaves every other edit as it was")
        await session.settleRendering()
    }

    func testOtherEditsStayAdjustableOnTopOfTheEnhancedPhoto() async throws {
        let session = try await EditorTestSupport.readySession(enhancer: FakeEnhancer(.succeed(painting: false)))
        session.commitEdit { $0.adjust.exposure = 30 }
        session.enhancePhoto()
        await waitWhileEnhancing(session)
        XCTAssertEqual(session.recipe.tools.edit.adjust.exposure, 30, "an edit made before Enhance is kept")
        session.commitEdit { $0.adjust.exposure = -10 }
        XCTAssertNotNil(session.recipe.tools.edit.enhance, "a later edit keeps the result")
        XCTAssertEqual(session.recipe.tools.edit.adjust.exposure, -10)
        await session.settleRendering()
    }

    func testPaintingIsRecordedForThePanelNote() async throws {
        let session = try await EditorTestSupport.readySession(enhancer: FakeEnhancer(.succeed(painting: true)))
        session.enhancePhoto()
        await waitWhileEnhancing(session)
        XCTAssertEqual(session.recipe.tools.edit.enhance?.painting, true)
        await session.settleRendering()
    }

    func testFailureKeepsTheEditAndTryAgainRunsAgain() async throws {
        let engine = FakeEnhancer(.fail)
        let session = try await EditorTestSupport.readySession(enhancer: engine)
        session.commitEdit { $0.adjust.contrast = 20 }
        let before = session.recipe
        session.enhancePhoto()
        await waitWhileEnhancing(session)
        XCTAssertEqual(session.enhanceState, .failed)
        XCTAssertEqual(session.recipe, before, "Your other edits are kept")
        session.enhancePhoto()   // Try again
        await waitWhileEnhancing(session)
        XCTAssertEqual(engine.runCount, 2)
        XCTAssertEqual(session.enhanceState, .failed)
        session.resetEdits(section: "edit", adjustment: "enhance")
        XCTAssertEqual(session.enhanceState, .idle, "Reset clears the failure notice")
        await session.settleRendering()
    }

    func testCancelChangesNothing() async throws {
        let session = try await EditorTestSupport.readySession(enhancer: FakeEnhancer(.waitForCancel))
        let before = session.recipe
        session.enhancePhoto()
        try? await Task.sleep(for: .milliseconds(50))
        session.cancelEnhance()
        XCTAssertEqual(session.enhanceState, .idle)
        XCTAssertEqual(session.toast, "Cancelled · nothing changed")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.recipe, before)
        XCTAssertEqual(KeepAwake.activeReasons, [], "nothing holds the phone awake once cancelled")
        await session.settleRendering()
    }

    func testSavedCopyIsTheEnhancedSizeAndMatchesTheReferenceExport() async throws {
        let writer = SpyLibraryWriter()
        let session = try await EditorTestSupport.readySession(writer: writer, enhancer: FakeEnhancer(.succeed(painting: false)))
        session.enhancePhoto()
        await waitWhileEnhancing(session)
        let reference = try await session.exportedData()
        session.saveCopy()
        await EditorTestSupport.waitForSave(session)
        let savedData = await writer.savedData
        let saved = try XCTUnwrap(savedData)
        XCTAssertTrue(saved == reference, "Save copy matches the reference export byte for byte")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(saved as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, session.photo.image.width * 2, "the saved copy is twice the size")
        XCTAssertEqual(image.height, session.photo.image.height * 2)
        await session.settleRendering()
    }

    func testAMissingResultRendersWithoutItAndSavesAtTheOriginalSize() async throws {
        let session = try await EditorTestSupport.readySession(enhancer: FakeEnhancer(.succeed(painting: false)))
        let missing = EditRecipe.DerivedRef(sha256: String(repeating: "ab", count: 32), model: EditorSession.enhanceModel,
                                            width: session.photo.image.width * 2, height: session.photo.image.height * 2)
        session.commitEdit { $0.enhance = .init(result: missing, painting: false) }
        await session.settleRendering()
        let data = try await session.exportedData()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, session.photo.image.width, "never re-enhanced silently")
        await session.settleRendering()
    }

    func testTheEngineReportsProgressWithoutChangingTheRelayOrder() {
        final class Seen: @unchecked Sendable { let lock = NSLock(); var values: [Double] = [] }
        let seen = Seen()
        let relay = EnhanceProgressRelay { value in seen.lock.withLock { seen.values.append(value) } }
        for fraction in [0.0, 0.004, 0.06, 0.061, 0.5, 0.2, 1.0] { relay.report(fraction) }
        XCTAssertEqual(seen.values, [0, 0.06, 0.5, 1], "whole percents only, never backwards")
    }
}
