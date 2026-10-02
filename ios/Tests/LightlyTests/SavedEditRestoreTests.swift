import XCTest
@testable import Lightly

/// Restoring a saved session and resolving its Look against the installed pack
/// (shared/fixtures/edit-state/README.md, "Resolving a saved Look"):
/// - lookId missing from the pack → unavailable: renders without the Look, keeps the LookRef, notice;
/// - lookId present, version differs (incl. migrated `legacy-v1-*`) → changed: renders without the
///   Look until "Use current version", which is a new undoable step;
/// - both match → renders the Look.
/// No other Look is ever substituted, and Save copy writes what is displayed.
@MainActor
final class SavedEditRestoreTests: XCTestCase {

    private var metal: MetalLUTRenderer!
    private let book = LookPackFixture.editorBook
    private let warmID = "fixture-warm-000002"
    private let coolID = "fixture-cool-000003"

    override func setUpWithError() throws {
        metal = try MetalLUTRenderer()
    }

    /// The source block of the shared fixtures; the session never interprets it.
    private var source: SavedSourceRef {
        get throws { try SavedEditCodec.decodeState(try SavedEditFormatTests.fixture("v2-no-look.json")).source }
    }

    private func editor(
        restoring session: SavedEditSession? = nil, auto: any AutoEnhancing = ModelNotBundledAutoEnhancer()
    ) async -> LUTEditorViewModel {
        let viewModel = LUTEditorViewModel(
            photo: LUTEditSessionTests.makePhoto(), autoEnhancer: auto,
            lookBook: book, renderer: metal, libraryWriter: SpyLibraryWriter(),
            previewLongEdge: 400, restoringSession: session
        )
        await viewModel.developTask?.value
        await viewModel.settleRendering()
        return viewModel
    }

    /// A one-entry session whose Look is `look`.
    private func session(look: SavedLookRef?, auto: SavedAutoResult = .noModelInBuild) throws -> SavedEditSession {
        let state = SavedEditState(source: try source, auto: auto, look: look, revision: 0)
        return SavedEditSession(entries: [state], cursor: 0, capacity: LUTEditSession.historyCapacity, lastIssuedRevision: 0)
    }

    private func pixels(_ viewModel: LUTEditorViewModel) throws -> [UInt8] {
        try MetalLUTRenderer.rgba8Bytes(of: viewModel.displayedImage)
    }

    private func originalPixels(_ viewModel: LUTEditorViewModel) throws -> [UInt8] {
        try XCTUnwrap(viewModel.session).previewBase.pixels
    }

    // MARK: - Whole-session round trip

    func testAWholeSessionRoundTripsWithHistoryAndCursor() async throws {
        let first = await editor()
        first.settleStop(1)
        first.selectCategory("cat-beta")
        first.settleStop(2)
        first.commitLookStrength(0.4)
        first.undo()
        await first.settleRendering()
        let firstSession = try XCTUnwrap(first.session)
        let saved = firstSession.savedSession(source: try source, auto: .noModelInBuild)

        let bytes = SavedEditCodec.encode(saved)
        let decoded = try SavedEditCodec.decodeSession(bytes)
        XCTAssertEqual(decoded, saved)
        XCTAssertEqual(SavedEditCodec.encode(decoded), bytes, "Encoding is deterministic")
        XCTAssertEqual(decoded.entries.count, 4)
        XCTAssertEqual(decoded.cursor, 2)
        XCTAssertEqual(decoded.lastIssuedRevision, 3)

        let restored = await editor(restoring: decoded)
        let restoredSession = try XCTUnwrap(restored.session)
        XCTAssertEqual(restoredSession.history, firstSession.history)
        XCTAssertEqual(restoredSession.historyIndex, firstSession.historyIndex)
        XCTAssertEqual(restoredSession.savedSession(source: try source, auto: .noModelInBuild), saved)
        XCTAssertTrue(restored.canRedo, "The redo entry survives the round trip")
        XCTAssertEqual(try pixels(restored), try pixels(first), "Same edit, same pixels")

        restored.redo()
        XCTAssertEqual(restoredSession.committedState.lookStrength, 0.4, accuracy: 1e-6)
    }

    // MARK: - Resolution

    func testAMatchingLookRenders() async throws {
        let current = try XCTUnwrap(book.look(id: warmID))
        let restored = await editor(restoring: try session(look: SavedLookRef(lookId: warmID, lookVersion: current.version, strength: 1)))
        let fresh = await editor()
        fresh.settleStop(2)
        await fresh.settleRendering()

        XCTAssertEqual(restored.lookResolution, .available(lookID: warmID))
        XCTAssertNil(restored.lookNotice)
        XCTAssertEqual(restored.committedLook?.id, warmID)
        XCTAssertEqual(try pixels(restored), try pixels(fresh))
    }

    func testAMissingLookIsUnavailableKeepsTheRefAndRendersWithoutIt() async throws {
        let missing = SavedLookRef(lookId: "no-such-look-000000", lookVersion: "000000000000", strength: 0.7)
        let restored = await editor(restoring: try session(look: missing))
        let state = try XCTUnwrap(restored.session).committedState

        XCTAssertEqual(restored.lookResolution, .unavailable(lookID: missing.lookId))
        XCTAssertEqual(restored.lookNotice, .unavailable)
        XCTAssertEqual(state.lookID, missing.lookId, "The saved LookRef is kept, not dropped")
        XCTAssertEqual(state.lookVersion, missing.lookVersion)
        XCTAssertEqual(state.lookStrength, 0.7)
        XCTAssertNil(restored.committedLook, "Nothing is substituted")
        XCTAssertEqual(restored.settledStopIndex, 0)
        XCTAssertEqual(try pixels(restored), try originalPixels(restored))
        XCTAssertTrue(try XCTUnwrap(restored.session).passes(for: state).isEmpty, "Save copy writes what is shown")
        XCTAssertFalse(restored.canUseCurrentLookVersion)
    }

    func testAChangedVersionRendersWithoutTheLookUntilTheUserAccepts() async throws {
        let stale = SavedLookRef(lookId: warmID, lookVersion: "000000000000", strength: 1)
        let restored = await editor(restoring: try session(look: stale))
        let current = try XCTUnwrap(book.look(id: warmID))

        XCTAssertEqual(restored.lookResolution, .changed(lookID: warmID, savedVersion: "000000000000", currentVersion: current.version))
        XCTAssertEqual(restored.lookNotice, .changed(lookName: current.name))
        XCTAssertNil(restored.committedLook)
        XCTAssertEqual(try pixels(restored), try originalPixels(restored), "Not rendered before the user accepts")
        XCTAssertTrue(try XCTUnwrap(restored.session).passes(for: try XCTUnwrap(restored.session).committedState).isEmpty)
        XCTAssertTrue(restored.canUseCurrentLookVersion)

        restored.useCurrentLookVersion()
        await restored.settleRendering()
        let session = try XCTUnwrap(restored.session)
        XCTAssertEqual(session.history.count, 2, "Accepting is a new step")
        XCTAssertEqual(session.committedState.lookVersion, current.version)
        XCTAssertEqual(restored.lookResolution, .available(lookID: warmID))
        XCTAssertNil(restored.lookNotice)
        XCTAssertNotEqual(try pixels(restored), try originalPixels(restored))

        restored.undo()
        await restored.settleRendering()
        XCTAssertEqual(restored.lookNotice, .changed(lookName: current.name), "Undo brings back the saved (changed) state")
        XCTAssertEqual(try pixels(restored), try originalPixels(restored))
    }

    func testAMigratedLegacyVersionIsChanged() async throws {
        let migrated = try SavedEditCodec.decodeState(try SavedEditFormatTests.fixture("v1-numeric-look-version.json"))
        var look = try XCTUnwrap(migrated.look)
        look.lookId = coolID  // a Look the fixture pack has, under its migrated legacy version
        let restored = await editor(restoring: try session(look: look))

        guard case .changed(let id, let saved, _) = restored.lookResolution else {
            return XCTFail("legacy-v1 versions must resolve as changed, got \(restored.lookResolution)")
        }
        XCTAssertEqual(id, coolID)
        XCTAssertEqual(saved, "legacy-v1-2")
        XCTAssertEqual(try pixels(restored), try originalPixels(restored))
    }

    // MARK: - Auto is never re-developed (Codex review d5690dd finding 2)

    /// Restoring replays the saved edit: the model is not run (even when this build could run
    /// one), and a "no model" edit keeps Auto off and reads "Original".
    func testRestoringNeverRunsAutoAndKeepsANoModelEditOff() async throws {
        let enhancer = ScriptedAutoEnhancer(results: [.lut(try XCTUnwrap(book.look(id: warmID)).lut)])
        let saved = try session(look: nil)
        let restored = await editor(restoring: saved, auto: enhancer)
        let restoredSession = try XCTUnwrap(restored.session)

        let calls = await enhancer.callCount
        XCTAssertEqual(calls, 0, "A saved edit is not re-developed")
        XCTAssertEqual(restored.phase, .ready)
        XCTAssertEqual(restoredSession.committedState.autoStrength, 0)
        XCTAssertEqual(restored.noLookStopLabel, "Original")
        XCTAssertEqual(try pixels(restored), try originalPixels(restored))
        XCTAssertEqual(restoredSession.restoredAuto, .noModelInBuild)
        XCTAssertEqual(restoredSession.savedSession(source: try source, auto: try XCTUnwrap(restoredSession.restoredAuto)), saved)
    }

    /// A saved Auto block from a model is kept exactly (model, version, weights, strength), and the
    /// session is not overwritten with a fresh Auto baseline. iOS cannot replay it yet (no basis
    /// ships), so it is reported unavailable rather than claimed as applied.
    func testRestoringKeepsASavedAutoBlockAndStrengthUntouched() async throws {
        let modelAuto = SavedAutoResult(
            modelId: SavedAutoResult.ia3dlutModelID, modelVersion: "2026.09.1",
            weights: [0.25, -0.5, 1.25], guardrail: nil, strength: 0.7
        )
        let saved = try session(look: SavedLookRef(lookId: warmID, lookVersion: try XCTUnwrap(book.look(id: warmID)).version, strength: 0.5),
                                auto: modelAuto)
        let enhancer = ScriptedAutoEnhancer(results: [.lut(try XCTUnwrap(book.look(id: coolID)).lut)])
        let restored = await editor(restoring: saved, auto: enhancer)
        let restoredSession = try XCTUnwrap(restored.session)

        let calls = await enhancer.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(restoredSession.history.count, 1)
        XCTAssertEqual(restoredSession.committedState.autoStrength, 0.7, accuracy: 1e-6, "Saved strength, not 1")
        XCTAssertEqual(restoredSession.committedState.lookStrength, 0.5, accuracy: 1e-6)
        XCTAssertFalse(restored.isAutoApplied, "Not rendered, so not claimed")
        XCTAssertEqual(restoredSession.restoredAuto, modelAuto)
        let resaved = restoredSession.savedSession(source: try source, auto: try XCTUnwrap(restoredSession.restoredAuto))
        XCTAssertEqual(SavedEditCodec.encode(resaved), SavedEditCodec.encode(saved), "Written back byte for byte")
    }

    // MARK: - The edit is preserved

    /// Re-saving a restored session writes the unavailable / changed LookRef back exactly as it
    /// was read: it is never dropped, nulled or rewritten to the pack's version.
    func testResavingKeepsAnUnavailableOrChangedLookRefUnchanged() async throws {
        let refs = [
            SavedLookRef(lookId: "no-such-look-000000", lookVersion: "000000000000", strength: 0.7),
            SavedLookRef(lookId: warmID, lookVersion: "000000000000", strength: 0.6),
            SavedLookRef(lookId: coolID, lookVersion: "legacy-v1-2", strength: 0.8)
        ]
        for ref in refs {
            let saved = try session(look: ref)
            let restored = await editor(restoring: saved)
            let resaved = try XCTUnwrap(restored.session).savedSession(source: try source, auto: .noModelInBuild)

            XCTAssertEqual(resaved, saved, "\(ref.lookId)")
            XCTAssertEqual(SavedEditCodec.encode(resaved), SavedEditCodec.encode(saved), "\(ref.lookId)")
            XCTAssertNotNil(restored.lookNotice, "Reported, not silently gone: \(ref.lookId)")
        }
    }

    /// The stale ref also survives in history: edits on top of it and undoing back keep it.
    func testAStaleLookRefStaysInHistoryUnderLaterEdits() async throws {
        let stale = SavedLookRef(lookId: warmID, lookVersion: "000000000000", strength: 1)
        let restored = await editor(restoring: try session(look: stale))
        restored.settleStop(1)
        restored.undo()

        let resaved = try XCTUnwrap(restored.session).savedSession(source: try source, auto: .noModelInBuild)
        XCTAssertEqual(resaved.entries.first?.look, stale)
        XCTAssertEqual(resaved.current.look, stale)
        XCTAssertTrue(restored.canRedo)
    }

    /// "Use current version" is never applied by itself, and undoing it returns to the changed
    /// (unrendered) state with the original version recorded.
    func testUseCurrentVersionIsExplicitAndUndoRestoresTheSavedVersion() async throws {
        let stale = SavedLookRef(lookId: warmID, lookVersion: "000000000000", strength: 1)
        let restored = await editor(restoring: try session(look: stale))
        let session = try XCTUnwrap(restored.session)
        restored.selectCategory("cat-beta")
        restored.selectCategory("cat-alpha")
        restored.redo()
        restored.toggleCompare()
        restored.toggleCompare()
        XCTAssertEqual(session.history.count, 1, "Nothing applies the current version on its own")
        XCTAssertEqual(session.committedState.lookVersion, "000000000000")

        restored.useCurrentLookVersion()
        restored.undo()
        await restored.settleRendering()

        XCTAssertEqual(session.committedState.lookVersion, "000000000000")
        XCTAssertEqual(session.committedState.lookID, warmID)
        guard case .changed = restored.lookResolution else { return XCTFail("\(restored.lookResolution)") }
        XCTAssertEqual(try pixels(restored), try originalPixels(restored), "Unrendered again")
        XCTAssertEqual(session.savedSession(source: try source, auto: .noModelInBuild).current.look, stale)
    }

    /// A changed Look's own stop is not "the committed stop" (the slider shows stop 0 for it), so
    /// settling there applies the pack's version at 100% as a new step rather than being a no-op.
    func testSettlingOnAChangedLooksStopAppliesTheCurrentVersionAsAStep() async throws {
        let stale = SavedLookRef(lookId: warmID, lookVersion: "000000000000", strength: 0.3)
        let restored = await editor(restoring: try session(look: stale))
        let warmStop = try XCTUnwrap(restored.stops.firstIndex { $0.lookID == warmID })

        restored.settleStop(warmStop)

        let session = try XCTUnwrap(restored.session)
        XCTAssertEqual(session.history.count, 2)
        XCTAssertEqual(restored.lookResolution, .available(lookID: warmID))
        XCTAssertEqual(session.committedState.lookStrength, 1)
    }

    /// Choosing another Look answers the notice the ordinary way: a new step replacing the stale ref.
    func testChoosingAnotherLookReplacesAStaleRef() async throws {
        let restored = await editor(restoring: try session(look: SavedLookRef(lookId: "gone-000000", lookVersion: "x", strength: 1)))
        restored.settleStop(1)

        XCTAssertNil(restored.lookNotice)
        XCTAssertEqual(try XCTUnwrap(restored.session).history.count, 2)
    }
}
