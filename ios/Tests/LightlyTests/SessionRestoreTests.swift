import CoreGraphics
import XCTest
@testable import Lightly

/// Counts calls; a restored session must never run a model.
final class CountingAutoEnhancer: AutoEnhancing, @unchecked Sendable {
    private(set) var calls = 0
    func autoLUT(forAnalysisProxy proxy: CGImage) async -> AutoResult {
        calls += 1
        return .unavailable(.modelNotBundled)
    }
}

final class CountingPersonDetector: PersonDetecting, @unchecked Sendable {
    private(set) var calls = 0
    func containsPerson(_ image: CGImage) async -> Bool { calls += 1; return false }
}

/// Restoring the working session after the system ended the app (spec §27: "Persist history with
/// the working session so a returning user can still step back"), from storage only.
@MainActor
final class SessionRestoreTests: XCTestCase {

    private var library: DevelopLibrary!
    private var sessionDirectory: URL!
    private var patchDirectory: URL!

    override func setUp() async throws {
        library = try EditorTestSupport.library()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString)")
        sessionDirectory = base.appendingPathComponent("EditSession")
        patchDirectory = base.appendingPathComponent("RemovePatches")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: sessionDirectory.deletingLastPathComponent())
    }

    /// A session with a Look, a Remove stroke, an effect, a border and a watermark, one step undone.
    private func editedSession(store: EditSessionStore) async throws -> EditorSession {
        let session = try await EditorTestSupport.readySession(library: library, inpainter: FlatInpainter(),
                                                               removePatches: RemovePatchStore(directory: patchDirectory),
                                                               sessionStore: store)
        session.sceneSessionID = { "scene-A" }
        session.applyLook(library.pack.categories[0].presets[0])
        session.removeStroke(points: [.init(x: 0.5, y: 0.5), .init(x: 0.55, y: 0.5)], radius: 0.03)
        await session.debugAwaitQuiescence()
        session.commitEffects { $0.vignette.enabled = true }
        session.commitBorder { $0.type = .solid; $0.width = 6 }
        session.commitWatermark { w in WatermarkPanelModel.setType(.text, on: &w); w.text = .init(text: "A. Rivera", font: .inter) }
        session.commitEdit { $0.adjust.exposure = 25 }
        session.undo()
        await session.settleRendering()
        store.flush()
        return session
    }

    func testKillAndRecoverRestoresTheExactSessionFromStorageOnly() async throws {
        let store = EditSessionStore(directory: sessionDirectory)
        let before = try await editedSession(store: store)
        let preview = try MetalLUTRenderer.rgba8Bytes(of: before.displayedImage)
        let export = try await before.exportedData()
        let history = before.history, index = before.historyIndex
        // The app is killed: nothing is cleared, every in-memory store is gone.
        before.close()

        let saved = try XCTUnwrap(EditSessionStore(directory: sessionDirectory).load())
        XCTAssertEqual(saved.history, history)
        XCTAssertEqual(saved.index, index)
        let photo = try await ImageIOPhotoLoader().loadPhoto(from: saved.original, source: .photoLibrary)
        let trap = TrapInpainter(), auto = CountingAutoEnhancer(), people = CountingPersonDetector()
        let after = try await EditorTestSupport.readySession(photo: photo, library: library, autoEnhancer: auto, personDetector: people,
                                                             inpainter: trap, removePatches: RemovePatchStore(directory: patchDirectory),
                                                             sessionStore: EditSessionStore(directory: sessionDirectory), restoring: saved)
        await after.settleRendering()
        XCTAssertEqual(after.history, history, "the whole undo history")
        XCTAssertEqual(after.historyIndex, index)
        XCTAssertTrue(after.canUndo); XCTAssertTrue(after.canRedo)
        XCTAssertTrue(after.hasUnsavedEdits)
        XCTAssertEqual(try MetalLUTRenderer.rgba8Bytes(of: after.displayedImage), preview, "the preview is identical")
        let restoredExport = try await after.exportedData()
        XCTAssertEqual(restoredExport, export)
        XCTAssertEqual(trap.calls, 0, "Remove is replayed from the stored patch")
        XCTAssertEqual(auto.calls, 0, "Auto is not run again")
        XCTAssertEqual(people.calls, 0, "no analysis model runs again")
        after.redo()
        XCTAssertEqual(after.recipe.tools.edit.adjust.exposure, 25, "a returning user can still step through the history")
    }

    /// Selective Colour evidence: four colours kept together, one removed, Undo, then a kill and restore that gives
    /// back the same four colours, the same preview and the same Save copy.
    func testFourKeptColoursRemoveUndoRestoreAndSaveCopy() async throws {
        let store = EditSessionStore(directory: sessionDirectory)
        // The prototype's street photo: blue sky, red door, orange sign, brick road.
        let street = try await ImageIOPhotoLoader().loadPhoto(from: try Data(contentsOf: DevelopParityTests.fixture("docs/ui/assets/photos/wellexposed_03.jpg")),
                                                              source: .photoLibrary)
        let session = try await EditorTestSupport.readySession(photo: street, library: library, sessionStore: store)
        session.sceneSessionID = { "scene-A" }
        let taps: [(Double, Double)] = [(0.62, 0.10), (0.15, 0.56), (0.72, 0.40), (0.50, 0.80)]
        for (x, y) in taps { session.pickSelectiveColour(frameX: x, frameY: y); await session.settleRendering() }
        var kept = session.recipe.tools.effects.selectiveColour.colours
        XCTAssertEqual(kept.count, 4, "four colours kept together")
        XCTAssertEqual(Set(kept.map { "\($0.oklab)" }).count, 4, "four different colours")
        let four = kept
        session.removeSelectiveColour(at: 1)
        kept = session.recipe.tools.effects.selectiveColour.colours
        XCTAssertEqual(kept, [four[0], four[2], four[3]], "the × removes just that colour")
        session.undo()
        XCTAssertEqual(session.recipe.tools.effects.selectiveColour.colours, four, "Undo brings it back in place")
        await session.settleRendering()
        store.flush()
        let preview = try MetalLUTRenderer.rgba8Bytes(of: session.displayedImage)
        let export = try await session.exportedData()
        let history = session.history, index = session.historyIndex
        session.close()   // killed

        let saved = try XCTUnwrap(EditSessionStore(directory: sessionDirectory).load())
        let photo = try await ImageIOPhotoLoader().loadPhoto(from: saved.original, source: .photoLibrary)
        let after = try await EditorTestSupport.readySession(photo: photo, library: library,
                                                             sessionStore: EditSessionStore(directory: sessionDirectory), restoring: saved)
        await after.settleRendering()
        XCTAssertEqual(after.history, history); XCTAssertEqual(after.historyIndex, index)
        XCTAssertEqual(after.recipe.tools.effects.selectiveColour.colours, four, "the four colours are restored")
        XCTAssertEqual(try MetalLUTRenderer.rgba8Bytes(of: after.displayedImage), preview, "the restored preview is identical")
        let restoredExport = try await after.exportedData()
        XCTAssertEqual(restoredExport, export, "the restored Save copy is identical")
        after.redo()
        XCTAssertEqual(after.recipe.tools.effects.selectiveColour.colours.count, 3, "the removal can be redone after restore")
    }

    func testSavingACopyClearsTheStoredSession() async throws {
        let store = EditSessionStore(directory: sessionDirectory)
        let writer = SpyLibraryWriter()
        let session = try await EditorTestSupport.readySession(library: library, writer: writer, sessionStore: store)
        session.commitEffects { $0.vignette.enabled = true }
        store.flush()
        XCTAssertNotNil(store.load())
        session.saveCopy()
        await EditorTestSupport.waitForSave(session)
        store.flush()
        XCTAssertNil(store.load(), "saved as a copy: nothing to recover")
        session.commitEffects { $0.grain.enabled = true }
        store.flush()
        XCTAssertNotNil(store.load(), "a later edit is kept again")
    }

    func testTheCopyIsExcludedFromBackupAndOnlyWrittenWithUnsavedEdits() async throws {
        let store = EditSessionStore(directory: sessionDirectory)
        let session = try await EditorTestSupport.readySession(library: library, sessionStore: store)
        store.flush()
        XCTAssertNil(store.load(), "no edits: nothing stored")
        session.commitEffects { $0.vignette.enabled = true }
        store.flush()
        for name in ["original.bin", "history.jsonl"] {
            let values = try sessionDirectory.appendingPathComponent(name).resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true, name)
        }
        XCTAssertEqual(try sessionDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try Data(contentsOf: sessionDirectory.appendingPathComponent("original.bin")), session.photo.originalData)
    }

    func testRelaunchRestoresOnlyWhenTheSceneWasEditing() async throws {
        let store = EditSessionStore(directory: sessionDirectory)
        let session = try await editedSession(store: store)
        session.close()

        // A force-quit: iOS discarded the scene session and the launch got a new one, so the stored session is discarded.
        let quit = AppState(photoLoader: ImageIOPhotoLoader(), removePatches: RemovePatchStore(directory: patchDirectory), sessionStore: store)
        await quit.restoreInterruptedSession(currentSceneSessionID: "scene-B")
        store.flush()
        XCTAssertEqual(quit.route, .welcome)
        XCTAssertNil(store.load())

        let again = try await editedSession(store: store)
        let history = again.history
        again.close()
        let state = AppState(photoLoader: ImageIOPhotoLoader(), developLibrary: library,
                             removePatches: RemovePatchStore(directory: patchDirectory), sessionStore: store)
        await state.restoreInterruptedSession(currentSceneSessionID: "scene-A")
        let photo = try XCTUnwrap(state.selectedPhoto)
        XCTAssertEqual(state.route, .editor(SelectedPhotoReference(id: photo.id)))
        let restored = state.editorSession(for: photo)
        restored.start()
        await restored.waitUntilReady()
        XCTAssertEqual(restored.history.map(\.tools), history.map(\.tools))
        // Leaving the photo clears it.
        state.returnToWelcome()
        store.flush()
        XCTAssertNil(store.load())
    }

    /// R2: Save copy, then more edits, then the system ends the app: the post-save edits come back.
    func testEditsAfterSaveCopyAreRestoredAfterAKill() async throws {
        let store = EditSessionStore(directory: sessionDirectory)
        let session = try await EditorTestSupport.readySession(library: library, writer: SpyLibraryWriter(), sessionStore: store)
        session.sceneSessionID = { "scene-A" }
        session.commitEffects { $0.vignette.enabled = true }
        session.saveCopy()
        await EditorTestSupport.waitForSave(session)
        store.flush()
        XCTAssertNil(store.load(), "saved: nothing to recover yet")
        session.commitEffects { $0.grain.enabled = true }
        session.commitBorder { $0.type = .solid }
        let after = session.recipe
        await session.settleRendering()
        store.flush()
        session.close()

        let state = AppState(photoLoader: ImageIOPhotoLoader(), developLibrary: library,
                             removePatches: RemovePatchStore(directory: patchDirectory), sessionStore: store)
        await state.restoreInterruptedSession(currentSceneSessionID: "scene-A")
        let photo = try XCTUnwrap(state.selectedPhoto, "restored after the system ended the app")
        let restored = state.editorSession(for: photo)
        restored.start()
        await restored.waitUntilReady()
        XCTAssertEqual(restored.recipe.tools, after.tools, "with the edits made after Save copy")
        XCTAssertTrue(restored.recipe.tools.effects.grain.enabled)
        XCTAssertTrue(restored.hasUnsavedEdits)
    }

    /// Core Image Auto: the stored filters rebuild the correction; nothing analyses the photo again.
    func testCoreImageAutoComesBackFromTheStoredCorrectionWithoutAnalysingAgain() async throws {
        let store = EditSessionStore(directory: sessionDirectory)
        let photo = try await EditorTestSupport.photo(width: 1_200, height: 800)
        let before = try await EditorTestSupport.readySession(photo: photo, library: library, autoEnhancer: CoreImageAutoEnhancer(), sessionStore: store)
        before.sceneSessionID = { "scene-A" }
        XCTAssertEqual(before.autoState, .applied)
        before.applyLook(library.pack.categories[0].presets[0])
        await before.settleRendering()
        store.flush()
        let export = try await before.exportedData()
        before.close()

        let saved = try XCTUnwrap(EditSessionStore(directory: sessionDirectory).load())
        XCTAssertNotNil(saved.autoCorrection, "the filters and parameters are stored with the session")
        let reopened = try await ImageIOPhotoLoader().loadPhoto(from: saved.original, source: .photoLibrary)
        let counting = CountingAutoEnhancer()
        let after = try await EditorTestSupport.readySession(photo: reopened, library: library, autoEnhancer: counting,
                                                             sessionStore: EditSessionStore(directory: sessionDirectory), restoring: saved)
        await after.settleRendering()
        XCTAssertEqual(counting.calls, 0, "Auto is not recomputed")
        XCTAssertEqual(after.autoState, .applied)
        let restoredExport = try await after.exportedData()
        XCTAssertEqual(restoredExport, export, "the same correction in Save copy")
    }
}
