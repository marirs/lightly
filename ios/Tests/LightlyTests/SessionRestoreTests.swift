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

        // A force-quit: scene storage is gone, so the stored session is discarded.
        let quit = AppState(photoLoader: ImageIOPhotoLoader(), removePatches: RemovePatchStore(directory: patchDirectory), sessionStore: store)
        await quit.restoreInterruptedSession(sceneWasEditing: false)
        store.flush()
        XCTAssertEqual(quit.route, .welcome)
        XCTAssertNil(store.load())

        let again = try await editedSession(store: store)
        let history = again.history
        again.close()
        let state = AppState(photoLoader: ImageIOPhotoLoader(), developLibrary: library,
                             removePatches: RemovePatchStore(directory: patchDirectory), sessionStore: store)
        await state.restoreInterruptedSession(sceneWasEditing: true)
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
}
