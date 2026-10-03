import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Lightly

/// The editor screen's bindings to `LUTEditSession` (spec §2 primary flow):
/// photo → Auto (unavailable here) → stepped Looks → Compare → Undo → Reset
/// → Save copy.
@MainActor
final class LUTEditorViewModelTests: XCTestCase {

    private var metal: MetalLUTRenderer!

    /// The synthetic test Looks, arranged as one slider category.
    static let book = LUTLookBook(
        looks: TestLookBook.book.looks,
        categories: [
            LUTLookCategory(id: "Test", label: "Test", lookIDs: [TestLookBook.warm.id, TestLookBook.cool.id, TestLookBook.mono.id]),
            LUTLookCategory(id: "Other", label: "Other", lookIDs: [TestLookBook.mono.id])
        ]
    )

    override func setUpWithError() throws {
        metal = try MetalLUTRenderer()
    }

    private func makeEditor(
        auto: any AutoEnhancing = ModelNotBundledAutoEnhancer(),
        renderer: (any LUTRendering)?? = .none,
        writer: any PhotoLibraryWriting = SpyLibraryWriter()
    ) async -> LUTEditorViewModel {
        let viewModel = LUTEditorViewModel(
            photo: LUTEditSessionTests.makePhoto(), autoEnhancer: auto, lookBook: Self.book,
            renderer: renderer ?? metal, libraryWriter: writer, previewLongEdge: 400
        )
        await viewModel.developTask?.value
        return viewModel
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] { try MetalLUTRenderer.rgba8Bytes(of: image) }

    private func expectedPreview(_ viewModel: LUTEditorViewModel, passes: [LUT3D]) throws -> [UInt8] {
        let base = try XCTUnwrap(viewModel.session).previewBase
        return try metal.apply(passes, toRGBA8: base.pixels, width: base.width, height: base.height)
    }

    // MARK: - Develop and Auto

    func testSelectingAPhotoDevelopsWithoutADevelopButton() async {
        let viewModel = LUTEditorViewModel(
            photo: LUTEditSessionTests.makePhoto(), autoEnhancer: ModelNotBundledAutoEnhancer(),
            lookBook: Self.book, renderer: metal, libraryWriter: SpyLibraryWriter(), previewLongEdge: 400
        )
        XCTAssertEqual(viewModel.phase, .developing, "Auto starts as soon as the editor exists (spec D2)")

        await viewModel.developTask?.value

        XCTAssertEqual(viewModel.phase, .ready)
    }

    func testUnavailableAutoIsReportedAndBlocksNothing() async throws {
        let viewModel = await makeEditor()

        XCTAssertTrue(viewModel.isAutoUnavailable)
        XCTAssertEqual(viewModel.autoAvailability, .unavailable(.modelNotBundled))
        XCTAssertTrue(viewModel.canSaveCopy)
        XCTAssertEqual(viewModel.stops.count, 4, "Auto stop plus three Looks")

        viewModel.settleStop(1)
        await viewModel.settleRendering()
        XCTAssertEqual(viewModel.committedLook?.id, TestLookBook.warm.id, "Looks work without Auto")
    }

    func testWithoutARendererTheEditorFailsVisibly() async {
        let viewModel = await makeEditor(renderer: .some(nil))

        XCTAssertEqual(viewModel.phase, .failed(.developFailed))
        XCTAssertFalse(viewModel.canSaveCopy)
        viewModel.settleStop(1)
        XCTAssertNil(viewModel.committedLook)
    }

    // MARK: - Stepped slider

    func testDraggingPreviewsAndOnlySettlingCommits() async throws {
        let viewModel = await makeEditor()
        let session = try XCTUnwrap(viewModel.session)

        viewModel.previewStop(2)
        await viewModel.settleRendering()
        XCTAssertEqual(viewModel.displayedStopIndex, 2)
        XCTAssertEqual(session.history.count, 1, "Previewing is not an undo step")
        XCTAssertTrue(try pixels(viewModel.displayedImage) == expectedPreview(viewModel, passes: [TestLookBook.cool.lut]))

        viewModel.settleStop(2)
        await viewModel.settleRendering()
        XCTAssertEqual(session.history.count, 2)
        XCTAssertEqual(viewModel.committedLook?.id, TestLookBook.cool.id)
        XCTAssertEqual(viewModel.settledStopIndex, 2)
        XCTAssertNil(viewModel.previewedStopIndex)
    }

    func testSettlingAnotherStopReplacesTheLook() async throws {
        let viewModel = await makeEditor()
        viewModel.settleStop(1)
        viewModel.settleStop(3)
        await viewModel.settleRendering()

        let session = try XCTUnwrap(viewModel.session)
        // State, not LUT equality: the strength blend toward identity is
        // not bit-exact at strength 1 for every LUT.
        XCTAssertEqual(session.committedState.lookID, TestLookBook.mono.id)
        XCTAssertEqual(session.passes(for: session.committedState).count, 1, "Looks replace, never stack")
        XCTAssertTrue(try pixels(viewModel.displayedImage) == expectedPreview(viewModel, passes: [TestLookBook.mono.lut]))
    }

    func testSettlingOnTheAutoStopRemovesTheLookAsOneStep() async throws {
        let viewModel = await makeEditor()
        viewModel.settleStop(1)
        let session = try XCTUnwrap(viewModel.session)

        viewModel.previewStop(0)
        viewModel.settleStop(0)
        await viewModel.settleRendering()

        XCTAssertNil(viewModel.committedLook)
        XCTAssertEqual(session.history.count, 3)
        XCTAssertTrue(try pixels(viewModel.displayedImage) == session.previewBase.pixels)
    }

    func testChangingCategoryDoesNotChangeTheLook() async throws {
        let viewModel = await makeEditor()
        viewModel.settleStop(2)
        let session = try XCTUnwrap(viewModel.session)

        viewModel.selectCategory("Other")

        XCTAssertEqual(viewModel.committedLook?.id, TestLookBook.cool.id)
        XCTAssertEqual(session.history.count, 2)
        XCTAssertEqual(viewModel.settledStopIndex, 0, "The cool Look is not in this category, so the slider shows Auto")
    }

    func testCategoryChangeAbandonsAnUnsettledPreview() async throws {
        let viewModel = await makeEditor()
        viewModel.previewStop(3)
        viewModel.selectCategory("Other")
        await viewModel.settleRendering()

        XCTAssertNil(viewModel.previewedStopIndex)
        XCTAssertTrue(try pixels(viewModel.displayedImage) == XCTUnwrap(viewModel.session).previewBase.pixels)
    }

    func testControlsAreInertWhileDeveloping() async throws {
        let slow = DelayedAutoEnhancer(wrapped: ModelNotBundledAutoEnhancer(), delay: .seconds(5))
        let viewModel = LUTEditorViewModel(
            photo: LUTEditSessionTests.makePhoto(), autoEnhancer: slow,
            lookBook: Self.book, renderer: metal, libraryWriter: SpyLibraryWriter(), previewLongEdge: 400
        )
        defer { viewModel.close() }

        viewModel.settleStop(1)
        viewModel.toggleCompare()

        XCTAssertEqual(viewModel.phase, .developing)
        XCTAssertNil(viewModel.committedLook)
        XCTAssertFalse(viewModel.isShowingOriginal)
        XCTAssertFalse(viewModel.canSaveCopy)
    }

    // MARK: - Compare

    func testCompareByToggleAndByHold() async throws {
        let viewModel = await makeEditor()
        viewModel.settleStop(1)
        await viewModel.settleRendering()
        let original = try XCTUnwrap(viewModel.session).previewBase.pixels

        viewModel.toggleCompare()
        XCTAssertTrue(viewModel.isShowingOriginal)
        XCTAssertTrue(try pixels(viewModel.displayedImage) == original)

        // Releasing a hold must not switch off the toggle.
        viewModel.beginCompareHold()
        viewModel.endCompareHold()
        XCTAssertTrue(viewModel.isShowingOriginal)

        viewModel.toggleCompare()
        XCTAssertFalse(viewModel.isShowingOriginal)

        viewModel.beginCompareHold()
        XCTAssertTrue(viewModel.isShowingOriginal)
        viewModel.endCompareHold()
        XCTAssertFalse(viewModel.isShowingOriginal)
        XCTAssertTrue(try pixels(viewModel.displayedImage) == expectedPreview(viewModel, passes: [TestLookBook.warm.lut]))
    }

    // MARK: - Undo and Reset

    func testUndoAndResetToAuto() async throws {
        let viewModel = await makeEditor()
        XCTAssertFalse(viewModel.canUndo)
        XCTAssertFalse(viewModel.canResetToAuto, "Nothing to reset without a Look")

        viewModel.settleStop(1)
        viewModel.settleStop(3)
        XCTAssertTrue(viewModel.canResetToAuto)

        viewModel.undo()
        await viewModel.settleRendering()
        XCTAssertEqual(viewModel.committedLook?.id, TestLookBook.warm.id)

        viewModel.resetToAuto()
        await viewModel.settleRendering()
        XCTAssertNil(viewModel.committedLook)
        XCTAssertFalse(viewModel.canResetToAuto)
        XCTAssertTrue(viewModel.canUndo, "Reset is undoable")

        viewModel.undo()
        await viewModel.settleRendering()
        XCTAssertEqual(viewModel.committedLook?.id, TestLookBook.warm.id)
        XCTAssertTrue(try pixels(viewModel.displayedImage) == expectedPreview(viewModel, passes: [TestLookBook.warm.lut]))
    }

    // MARK: - Save copy

    func testSaveCopyWritesTheCommittedEditAsANewJPEG() async throws {
        let writer = SpyLibraryWriter()
        let viewModel = await makeEditor(writer: writer)
        let originalBytes = viewModel.photo.originalData
        viewModel.settleStop(3)   // mono
        viewModel.previewStop(1)  // a transient preview must not be saved

        viewModel.saveCopy()
        XCTAssertEqual(viewModel.saveStatus, .saving)
        XCTAssertFalse(viewModel.canSaveCopy, "One save at a time")
        await viewModel.saveTask?.value

        XCTAssertEqual(viewModel.saveStatus, .saved)
        let saved = await writer.lastSave()
        XCTAssertEqual(saved.ext, "jpg")
        let data = try XCTUnwrap(saved.data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, viewModel.photo.image.width, "Full resolution, not the preview")
        let mean = TestFixtures.meanColour(of: image)
        XCTAssertEqual(mean.red, mean.blue, accuracy: 0.02, "The committed mono Look, not the warm preview")
        XCTAssertEqual(viewModel.photo.originalData, originalBytes, "The original is never modified")
    }

    /// Save copy writes each combination of the two Preferences switches, read at the moment
    /// of saving: the saved JPEG's bytes are inspected for all four (`ExportMetadataPolicyTests`).
    func testSaveCopyAppliesTheMetadataSwitchesInAllFourCombinations() async throws {
        let original = try ExportMetadataPolicyTests.makeCameraOriginal()
        let base = LUTEditSessionTests.makePhoto(width: 240, height: 180)
        let photo = SelectedPhoto(image: base.image, source: .camera, originalData: original)
        var policy = ExportMetadataPolicy.default
        for combination in ExportMetadataPolicyTests.allCombinations {
            let writer = SpyLibraryWriter()
            let viewModel = LUTEditorViewModel(
                photo: photo, autoEnhancer: ModelNotBundledAutoEnhancer(), lookBook: Self.book,
                renderer: metal, libraryWriter: writer,
                saveCopySettings: { .saveCopy(metadata: policy) },
                previewLongEdge: 200
            )
            await viewModel.developTask?.value
            viewModel.settleStop(1)
            // Changed after the editor exists: the switch is read when saving, not when opening.
            policy = combination

            viewModel.saveCopy()
            await viewModel.saveTask?.value

            XCTAssertEqual(viewModel.saveStatus, .saved)
            let saved = await writer.lastSave()
            let data = try XCTUnwrap(saved.data)
            ExportMetadataPolicyTests.assertPolicy(
                combination, on: try ExportMetadataPolicyTests.WrittenFile(data), width: 240, height: 180
            )
            XCTAssertEqual(viewModel.photo.originalData, original, "The original is never modified")
        }
    }

    func testSaveFailureIsShownAndTheEditKept() async throws {
        let viewModel = await makeEditor(writer: SpyLibraryWriter(behaviour: .fail(.permissionDenied)))
        viewModel.settleStop(1)

        viewModel.saveCopy()
        await viewModel.saveTask?.value

        XCTAssertEqual(viewModel.saveStatus, .failed(.permissionDenied))
        XCTAssertEqual(viewModel.committedLook?.id, TestLookBook.warm.id)
        XCTAssertTrue(viewModel.canSaveCopy, "Retry is possible")
    }

    func testSavedConfirmationClearsWhenTheEditChanges() async throws {
        let viewModel = await makeEditor()
        viewModel.settleStop(1)
        viewModel.saveCopy()
        await viewModel.saveTask?.value
        XCTAssertEqual(viewModel.saveStatus, .saved)

        viewModel.settleStop(2)

        XCTAssertEqual(viewModel.saveStatus, .idle, "'Saved' must not describe a newer, unsaved edit")
    }
}
