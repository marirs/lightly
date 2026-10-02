import XCTest
@testable import Lightly

/// Editor behaviours added for the M2 UX: Redo, the optional Strength control, an undoable Reset,
/// the stop's name and position, and Retry / Continue for genuine Auto failures (never for
/// "no model in this build").
@MainActor
final class EditorBehaviourTests: XCTestCase {

    private var metal: MetalLUTRenderer!

    override func setUpWithError() throws {
        metal = try MetalLUTRenderer()
    }

    private func editor(auto: any AutoEnhancing = ModelNotBundledAutoEnhancer()) async -> LUTEditorViewModel {
        let viewModel = LUTEditorViewModel(
            photo: LUTEditSessionTests.makePhoto(), autoEnhancer: auto, lookBook: LookPackFixture.editorBook,
            renderer: metal, libraryWriter: SpyLibraryWriter(), previewLongEdge: 400
        )
        await viewModel.developTask?.value
        await viewModel.settleRendering()
        return viewModel
    }

    private func pixels(_ viewModel: LUTEditorViewModel) async throws -> [UInt8] {
        await viewModel.settleRendering()
        return try MetalLUTRenderer.rgba8Bytes(of: viewModel.displayedImage)
    }

    private func originalPixels(_ viewModel: LUTEditorViewModel) throws -> [UInt8] {
        try XCTUnwrap(viewModel.session).previewBase.pixels
    }

    /// A non-identity Auto result (the fixture's lift LUT stands in for a model's output).
    private var nonIdentityAutoLUT: LUT3D {
        LookPackFixture.editorBook.look(id: "fixture-lift-000001")!.lut
    }

    // MARK: - Auto applied (Codex review d5690dd finding 2)

    /// Successful Auto is the initial committed state: applied at full strength, rendered, stop 0
    /// reads "Auto", and it is not an undo step (Android `EditSession.start`).
    func testSuccessfulAutoIsAppliedAsTheStartingPoint() async throws {
        let viewModel = await editor(auto: ScriptedAutoEnhancer(results: [.lut(nonIdentityAutoLUT)]))
        let session = try XCTUnwrap(viewModel.session)

        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertEqual(session.committedState.autoStrength, 1)
        XCTAssertTrue(viewModel.isAutoApplied)
        XCTAssertEqual(viewModel.noLookStopLabel, "Auto")
        XCTAssertEqual(viewModel.stopLabel(at: 0), "Auto")
        XCTAssertNil(viewModel.autoNotice)
        XCTAssertEqual(session.history.count, 1, "The baseline, not an extra step")
        XCTAssertEqual(session.historyRevisions, [0])
        XCTAssertEqual(session.lastIssuedRevision, 0)
        XCTAssertFalse(viewModel.canUndo, "Undo cannot take Auto away: it is where the edit starts")
        let shown = try await pixels(viewModel)
        XCTAssertNotEqual(shown, try originalPixels(viewModel), "The Auto pass renders")
    }

    /// Looks go on top of Auto, and Reset to Auto / Undo come back to the Auto baseline.
    func testLooksStackOnTheAppliedAutoAndResetKeepsIt() async throws {
        let viewModel = await editor(auto: ScriptedAutoEnhancer(results: [.lut(nonIdentityAutoLUT)]))
        let autoOnly = try await pixels(viewModel)
        viewModel.settleStop(2)
        XCTAssertEqual(viewModel.session?.committedState.autoStrength, 1)
        viewModel.resetToAuto()
        XCTAssertEqual(viewModel.session?.committedState.autoStrength, 1)
        let afterReset = try await pixels(viewModel)
        XCTAssertEqual(afterReset, autoOnly)
        viewModel.undo()
        viewModel.undo()
        XCTAssertFalse(viewModel.canUndo)
        XCTAssertEqual(viewModel.noLookStopLabel, "Auto")
        let atStart = try await pixels(viewModel)
        XCTAssertEqual(atStart, autoOnly)
    }

    /// Retry semantics (decision): a successful Retry starts the session at the Auto baseline,
    /// exactly like a first-time success, not as an undoable step — Android's Retry re-runs
    /// `develop`, which calls `EditSession.start`. No edit can exist behind the failure row.
    func testASuccessfulRetryAppliesAutoAsTheStartingPoint() async throws {
        let auto = ScriptedAutoEnhancer(results: [.unavailable(.analysisFailed), .lut(nonIdentityAutoLUT)])
        let viewModel = await editor(auto: auto)
        XCTAssertEqual(viewModel.session?.committedState.autoStrength, 0)
        XCTAssertEqual(viewModel.noLookStopLabel, "Original")

        viewModel.retryAuto()
        await viewModel.developTask?.value
        let session = try XCTUnwrap(viewModel.session)

        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertEqual(session.committedState.autoStrength, 1)
        XCTAssertEqual(viewModel.noLookStopLabel, "Auto")
        XCTAssertEqual(session.history.count, 1)
        XCTAssertFalse(viewModel.canUndo)
        let shown = try await pixels(viewModel)
        XCTAssertNotEqual(shown, try originalPixels(viewModel))
    }

    /// The shipping "no model" enhancer and Continue-without-Auto never mark Auto applied.
    func testNoModelOrContinuingWithoutAutoStaysOriginal() async throws {
        let noModel = await editor()
        XCTAssertEqual(noModel.session?.committedState.autoStrength, 0)
        XCTAssertFalse(noModel.isAutoApplied)
        XCTAssertEqual(noModel.stopLabel(at: 0), "Original")
        let noModelShown = try await pixels(noModel)
        XCTAssertEqual(noModelShown, try originalPixels(noModel))

        let failed = await editor(auto: ScriptedAutoEnhancer(results: [.unavailable(.invalidBasis)]))
        failed.continueWithoutAuto()
        XCTAssertEqual(failed.session?.committedState.autoStrength, 0)
        XCTAssertEqual(failed.stopLabel(at: 0), "Original")
        let failedShown = try await pixels(failed)
        XCTAssertEqual(failedShown, try originalPixels(failed))
    }
    // MARK: - Redo

    func testRedoReappliesWhatUndoTookBack() async throws {
        let viewModel = await editor()
        XCTAssertFalse(viewModel.canRedo)
        viewModel.settleStop(1)
        viewModel.settleStop(2)
        let second = try await pixels(viewModel)

        viewModel.undo()
        XCTAssertTrue(viewModel.canRedo)
        XCTAssertEqual(viewModel.settledStopIndex, 1)

        viewModel.redo()
        XCTAssertEqual(viewModel.settledStopIndex, 2)
        XCTAssertFalse(viewModel.canRedo)
        let current1 = try await pixels(viewModel)
        XCTAssertEqual(current1, second)
    }

    func testANewEditAfterUndoClearsRedo() async {
        let viewModel = await editor()
        viewModel.settleStop(1)
        viewModel.settleStop(2)
        viewModel.undo()

        viewModel.selectCategory("cat-beta")
        viewModel.settleStop(1)

        XCTAssertFalse(viewModel.canRedo, "Committing forks history")
    }

    // MARK: - Reset

    func testResetIsOneUndoableAndRedoableStep() async throws {
        let viewModel = await editor()
        viewModel.settleStop(2)
        let withLook = try await pixels(viewModel)

        viewModel.resetToAuto()
        XCTAssertNil(viewModel.committedLook)
        XCTAssertFalse(viewModel.canResetToAuto)

        viewModel.undo()
        XCTAssertEqual(viewModel.committedLook?.id, "fixture-warm-000002")
        let current2 = try await pixels(viewModel)
        XCTAssertEqual(current2, withLook)

        viewModel.redo()
        XCTAssertNil(viewModel.committedLook)
    }

    // MARK: - Strength

    func testStrengthIsOfferedOnlyWhileALookIsApplied() async {
        let viewModel = await editor()
        XCTAssertFalse(viewModel.showsStrengthControl, "No Look, no Strength")

        viewModel.settleStop(1)
        XCTAssertTrue(viewModel.showsStrengthControl)
        XCTAssertEqual(viewModel.displayedLookStrength, 1)

        viewModel.previewStop(2)
        XCTAssertTrue(viewModel.showsStrengthControl, "Stays laid out while another preset is dragged in")
        XCTAssertFalse(viewModel.canAdjustStrength, "but cannot be used for the wrong Look")
        viewModel.commitLookStrength(0.2)
        XCTAssertEqual(viewModel.displayedLookStrength, 1)
        viewModel.settleStop(0)
        XCTAssertFalse(viewModel.showsStrengthControl)
    }

    func testDraggingStrengthPreviewsAndReleaseCommitsOneStep() async throws {
        let viewModel = await editor()
        viewModel.settleStop(1)
        let full = try await pixels(viewModel)
        let session = try XCTUnwrap(viewModel.session)
        let steps = session.history.count

        viewModel.previewLookStrength(0.5)
        viewModel.previewLookStrength(0.3)
        let previewed = try await pixels(viewModel)
        XCTAssertNotEqual(previewed, full)
        XCTAssertEqual(session.history.count, steps, "Dragging is not a step")
        XCTAssertEqual(viewModel.displayedLookStrength, 0.3, accuracy: 1e-6)
        XCTAssertEqual(session.committedState.lookStrength, 1)

        viewModel.commitLookStrength(0.3)
        XCTAssertEqual(session.history.count, steps + 1, "Release is one step")
        XCTAssertEqual(session.committedState.lookStrength, 0.3, accuracy: 1e-6)
        let current3 = try await pixels(viewModel)
        XCTAssertEqual(current3, previewed, "What was previewed is what is committed")

        viewModel.undo()
        XCTAssertEqual(session.committedState.lookStrength, 1)
        let current4 = try await pixels(viewModel)
        XCTAssertEqual(current4, full)
    }

    func testStrengthZeroShowsTheEditWithoutTheLookButKeepsIt() async throws {
        let viewModel = await editor()
        let original = try await pixels(viewModel)
        viewModel.settleStop(1)
        viewModel.commitLookStrength(0)

        let current5 = try await pixels(viewModel)
        XCTAssertEqual(current5, original)
        XCTAssertEqual(viewModel.committedLook?.id, "fixture-lift-000001")
        XCTAssertTrue(viewModel.showsStrengthControl, "Still adjustable back up")
    }

    func testChoosingAnotherPresetStartsAtFullStrength() async throws {
        let viewModel = await editor()
        viewModel.settleStop(1)
        viewModel.commitLookStrength(0.4)
        viewModel.settleStop(2)

        XCTAssertEqual(viewModel.displayedLookStrength, 1)
    }

    // MARK: - Name and position

    func testStopNameAndPositionAreShown() async {
        let viewModel = await editor()
        viewModel.selectCategory("cat-beta")
        viewModel.settleStop(2)

        XCTAssertEqual(viewModel.stopLabel(at: viewModel.displayedStopIndex), "Fixture Long Preset Name Tone (11)")
        XCTAssertEqual(viewModel.stopPositionText, "3 of 4")

        viewModel.settleStop(0)
        XCTAssertEqual(viewModel.stopLabel(at: 0), "Original", "Not Auto: no Auto was applied")
        XCTAssertEqual(viewModel.stopPositionText, "1 of 4")
    }

    // MARK: - Auto failures

    func testNoModelInBuildGoesStraightToEditingWithANotice() async {
        let viewModel = await editor()

        XCTAssertEqual(viewModel.phase, .ready, "No Retry: there is nothing to retry")
        XCTAssertEqual(viewModel.autoNotice, .notInBuild)
        XCTAssertEqual(viewModel.noLookStopLabel, "Original")
    }

    func testAGenuineAutoFailureOffersRetryAndContinue() async {
        let viewModel = await editor(auto: ScriptedAutoEnhancer(results: [.unavailable(.invalidBasis)]))

        XCTAssertEqual(viewModel.phase, .autoFailed(.invalidBasis))
        XCTAssertNil(viewModel.autoNotice, "The failure row explains it")
        XCTAssertFalse(viewModel.isReady, "Nothing is edited behind the failure")

        viewModel.continueWithoutAuto()
        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertEqual(viewModel.autoNotice, .failed)
        XCTAssertEqual(viewModel.noLookStopLabel, "Original")
        viewModel.settleStop(1)
        XCTAssertNotNil(viewModel.committedLook, "Looks still work without Auto")
    }

    func testRetryRunsAutoAgain() async {
        let auto = ScriptedAutoEnhancer(results: [.unavailable(.analysisFailed), .lut(.identity(dimension: 2))])
        let viewModel = await editor(auto: auto)
        XCTAssertEqual(viewModel.phase, .autoFailed(.analysisFailed))

        viewModel.retryAuto()
        XCTAssertEqual(viewModel.phase, .developing)
        await viewModel.developTask?.value

        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertEqual(viewModel.autoAvailability, .available)
        XCTAssertNil(viewModel.autoNotice)
        let calls = await auto.callCount
        XCTAssertEqual(calls, 2)
    }
}

/// Returns the scripted results in order, then repeats the last one.
actor ScriptedAutoEnhancer: AutoEnhancing {
    private let results: [AutoResult]
    private(set) var callCount = 0

    init(results: [AutoResult]) {
        self.results = results
    }

    func autoLUT(forAnalysisProxy proxy: CGImage) async -> AutoResult {
        defer { callCount += 1 }
        return results[min(callCount, results.count - 1)]
    }
}
