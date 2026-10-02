import XCTest
@testable import Lightly

/// The editor driven by a Look pack (spec D5/D6, §4.5): categories and stop
/// names come from the manifest, the slider picks a preset (never an
/// intensity), the status of the Looks is stated honestly, and saved edits
/// survive relabelling and reordering of the catalog.
@MainActor
final class LookPackEditorTests: XCTestCase {

    private var metal: MetalLUTRenderer!
    private var fixtures: [LookPackFixture] = []

    override func setUpWithError() throws {
        metal = try MetalLUTRenderer()
    }

    override func tearDown() {
        fixtures.forEach { $0.remove() }
        fixtures = []
    }

    private func editor(
        book: LUTLookBook = LookPackFixture.editorBook, restoring savedEdit: LUTEditState? = nil,
        auto: any AutoEnhancing = ModelNotBundledAutoEnhancer()
    ) async -> LUTEditorViewModel {
        let viewModel = LUTEditorViewModel(
            photo: LUTEditSessionTests.makePhoto(), autoEnhancer: auto,
            lookBook: book, renderer: metal, libraryWriter: SpyLibraryWriter(),
            previewLongEdge: 400, restoring: savedEdit
        )
        await viewModel.developTask?.value
        await viewModel.settleRendering()
        return viewModel
    }

    private func book(_ categories: [LookPackFixture.Category]) throws -> LUTLookBook {
        let fixture = try LookPackFixture.write(categories)
        fixtures.append(fixture)
        let result = fixture.load()
        XCTAssertNil(result.problem)
        XCTAssertEqual(result.droppedLooks, [])
        return result.book
    }

    // MARK: - Categories and stops are manifest data

    func testCategoriesAreTheManifestsInOrderAndTheFirstIsSelected() async {
        let viewModel = await editor()

        XCTAssertEqual(viewModel.categories.map(\.label), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(viewModel.categories.map(\.id), ["cat-alpha", "cat-beta", "cat-gamma"])
        XCTAssertEqual(viewModel.selectedCategoryID, "cat-alpha", "Default category is the pack's first")
    }

    func testStopZeroIsNoLookAndTheRestAreTheManifestNamesInOrder() async {
        let viewModel = await editor()
        viewModel.selectCategory("cat-beta")

        XCTAssertTrue(viewModel.stops[0].isAutoStop)
        XCTAssertEqual(viewModel.stops.dropFirst().map(\.lookName),
                       ["Fixture Cool", "Fixture Long Preset Name Tone (11)", "Fixture Mono"])
        XCTAssertEqual((0..<viewModel.stops.count).map(viewModel.stopLabel(at:)),
                       ["Original", "Fixture Cool", "Fixture Long Preset Name Tone (11)", "Fixture Mono"])
    }

    // MARK: - Stop 0: "Original" unless Auto is actually applied

    /// No Auto model: stop 0 shows the untouched photo, so it must not claim
    /// to be Auto.
    func testStopZeroReadsOriginalWhenAutoIsUnavailable() async {
        let viewModel = await editor()

        XCTAssertTrue(viewModel.isAutoUnavailable)
        XCTAssertEqual(viewModel.stopLabel(at: 0), "Original")
        XCTAssertEqual(viewModel.sliderAccessibilityValue, "Alpha, Original, 1 of 3")
    }

    /// Auto available but at strength 0 is still the original; only an
    /// applied Auto correction makes stop 0 "Auto".
    func testStopZeroReadsAutoOnlyWhileAnAutoCorrectionIsApplied() async throws {
        let basis: [LUT3D] = [.identity(), .lut(dimension: 33) { 1.2 * $0 - SIMD3(repeating: 0.05) }]
        let viewModel = await editor(auto: BasisAutoEnhancer(basis: basis) { _ in [0, 1] })
        let session = try XCTUnwrap(viewModel.session)
        XCTAssertEqual(viewModel.autoAvailability, .available)

        XCTAssertEqual(viewModel.stopLabel(at: 0), "Original", "Auto available but not applied (strength 0)")

        session.setAutoStrength(0.8)
        XCTAssertEqual(viewModel.stopLabel(at: 0), "Auto")
        XCTAssertEqual(viewModel.sliderAccessibilityValue, "Alpha, Auto, 1 of 3")

        session.setAutoStrength(0)
        XCTAssertEqual(viewModel.stopLabel(at: 0), "Original")
    }

    func testAccessibilityValueNamesCategoryPresetAndPosition() async {
        let viewModel = await editor()
        viewModel.selectCategory("cat-beta")

        XCTAssertEqual(viewModel.sliderAccessibilityValue, "Beta, Original, 1 of 4")
        viewModel.settleStop(2)
        XCTAssertEqual(viewModel.sliderAccessibilityValue, "Beta, Fixture Long Preset Name Tone (11), 3 of 4")
    }

    /// Increment/decrement move exactly one stop and stop at the ends; each
    /// settles a preset, there is no strength in between.
    func testAccessibilityIncrementAndDecrementMoveOneStop() async throws {
        let viewModel = await editor()
        viewModel.selectCategory("cat-alpha")

        viewModel.adjustStop(by: 1)
        XCTAssertEqual(viewModel.committedLook?.name, "Fixture Lift")
        viewModel.adjustStop(by: 1)
        XCTAssertEqual(viewModel.committedLook?.name, "Fixture Warm (2)")
        viewModel.adjustStop(by: 1)
        XCTAssertEqual(viewModel.displayedStopIndex, 2, "Clamped at the last stop")
        let session = try XCTUnwrap(viewModel.session)
        XCTAssertEqual(session.committedState.lookStrength, 1, "The slider never changes strength")
        viewModel.adjustStop(by: -1)
        viewModel.adjustStop(by: -1)
        viewModel.adjustStop(by: -1)
        XCTAssertNil(viewModel.committedLook)
        XCTAssertEqual(viewModel.displayedStopIndex, 0)
    }

    func testChangingCategoryAloneIsNotAnUndoStep() async throws {
        let viewModel = await editor()
        viewModel.settleStop(1)
        let session = try XCTUnwrap(viewModel.session)

        viewModel.selectCategory("cat-gamma")
        viewModel.selectCategory("cat-beta")

        XCTAssertEqual(session.history.count, 2)
        XCTAssertEqual(viewModel.committedLook?.id, "fixture-lift-000001")
    }

    // MARK: - Honest status

    func testApproximateLooksAreLabelled() async throws {
        let approximate = await editor()
        XCTAssertTrue(approximate.showsApproximateLooksNotice, "Today's pack: model approximations, unvalidated")

        let validatedBook = try book([.init(id: "c", label: "C", looks: [
            .init(id: "v", name: "V", lutSource: "lightroom-hald", validation: "validated", transform: LookPackFixture.warm)
        ])])
        let validated = await editor(book: validatedBook)
        XCTAssertFalse(validated.showsApproximateLooksNotice)
        let noLooks = await editor(book: .empty)
        XCTAssertFalse(noLooks.showsApproximateLooksNotice, "No Looks: nothing to qualify")
    }

    // MARK: - Saved edits

    func testCommittedEditRecordsLookIDAndVersion() async throws {
        let viewModel = await editor()
        viewModel.settleStop(2)

        let state = try XCTUnwrap(viewModel.session).committedState
        XCTAssertEqual(state.lookID, "fixture-warm-000002")
        XCTAssertEqual(state.lookVersion, LookPackFixture.editorBook.look(id: "fixture-warm-000002")?.version)
    }

    /// An edit saved against one catalog replays the same Look after the
    /// catalog relabels its categories, reorders its stops and moves the Look
    /// to another category.
    func testRelabellingAndReorderingDoNotAffectASavedEdit() async throws {
        let first = try book([
            .init(id: "cat-warm", label: "Warm", looks: [
                .init(id: "look-a", name: "A", transform: LookPackFixture.lift),
                .init(id: "look-b", name: "B", transform: LookPackFixture.warm)
            ]),
            .init(id: "cat-cool", label: "Cool", looks: [.init(id: "look-c", name: "C", transform: LookPackFixture.cool)])
        ])
        let second = try book([
            .init(id: "cat-other", label: "Something Else", looks: [
                .init(id: "look-c", name: "C", transform: LookPackFixture.cool),
                .init(id: "look-b", name: "B", transform: LookPackFixture.warm)
            ]),
            .init(id: "cat-warm", label: "Renamed", looks: [.init(id: "look-a", name: "A", transform: LookPackFixture.lift)])
        ])
        let original = await editor(book: first)
        original.settleStop(2)
        await original.settleRendering()
        let saved = try XCTUnwrap(original.session).committedState

        let restored = await editor(book: second, restoring: saved)

        XCTAssertEqual(restored.committedLook?.id, "look-b")
        XCTAssertEqual(try XCTUnwrap(restored.session).committedState, saved)
        XCTAssertNil(restored.lookNotice)
        XCTAssertEqual(restored.selectedCategoryID, "cat-other", "Opens on the category that holds the Look")
        XCTAssertEqual(restored.settledStopIndex, 2)
        XCTAssertTrue(try MetalLUTRenderer.rgba8Bytes(of: restored.displayedImage)
                      == MetalLUTRenderer.rgba8Bytes(of: original.displayedImage), "Same Look, same pixels")
    }

    /// Spec §4.5: an unknown ID becomes "Look unavailable": the photo renders
    /// without it and a notice says so; nothing is substituted and the saved
    /// reference is kept (shared/fixtures/edit-state/README.md).
    // v3 differs: the reference used to be dropped from the restored state.
    func testAnUnknownLookIDRendersWithoutTheLookWithANotice() async throws {
        var saved = LUTEditState.original
        saved.lookID = "no-such-look-000000"
        saved.lookVersion = "000000000000"

        let viewModel = await editor(restoring: saved)
        let session = try XCTUnwrap(viewModel.session)

        XCTAssertNil(viewModel.committedLook)
        XCTAssertEqual(session.committedState, saved, "The saved LookRef is kept unchanged")
        XCTAssertEqual(viewModel.lookNotice, .unavailable)
        XCTAssertEqual(session.history.count, 1)
        XCTAssertTrue(try MetalLUTRenderer.rgba8Bytes(of: viewModel.displayedImage) == session.previewBase.pixels,
                      "Auto (unavailable here) means the original pixels")

        viewModel.settleStop(1)
        XCTAssertNil(viewModel.lookNotice, "Choosing a Look answers the notice")
    }
}
