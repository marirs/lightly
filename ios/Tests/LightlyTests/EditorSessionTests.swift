import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Lightly

/// One continuous editing session (slice 2): opening and Auto, the Develop rules of the approved
/// prototype (ruler, categories, Amount, favourites), whole-recipe undo/redo, Compare, Save copy
/// of the committed recipe, and latest-request-wins previews.
@MainActor
final class EditorSessionTests: XCTestCase {

    private var library: DevelopLibrary!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        library = try EditorTestSupport.library()
        defaults = UserDefaults(suiteName: "EditorSessionTests-\(UUID().uuidString)")
    }

    private var pack: PresetPack { library.pack }

    private func panel(_ session: EditorSession) -> DevelopPanelModel {
        DevelopPanelModel(session: session, favourites: FavouritePresetsStore(defaults: defaults))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] { try MetalLUTRenderer.rgba8Bytes(of: image) }

    /// A preset that uses only the global stage, and one with spatial or finishing operators.
    private var globalOnlyPreset: PresetPack.Preset {
        pack.categories.flatMap(\.presets).first { $0.recipe.spatial.isEmpty && $0.recipe.finishing.isEmpty }
            ?? pack.categories[0].presets[0]
    }
    private var spatialPreset: PresetPack.Preset {
        pack.categories.flatMap(\.presets).first { $0.recipe.spatial.clarity != nil && $0.recipe.spatial.noiseReduction != nil }!
    }
    private var grayscalePreset: PresetPack.Preset {
        pack.categories.flatMap(\.presets).first { $0.recipe.global.grayscaleMix != nil }!
    }

    // MARK: - Opening and Auto

    func testOpeningDevelopsWithoutAButtonAndNoModelMeansTheUnavailableState() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.autoState, .unavailable, "No model ships: the approved unavailable state, never a fixed filter")
        XCTAssertEqual(session.recipe.auto, .noModelInBuild)
        XCTAssertNil(session.recipe.look)
        XCTAssertEqual(panel(session).displayedName, "Original", "Stop zero reads Auto only when Auto is applied")
        XCTAssertEqual(session.recipe.revision, 0)
        XCTAssertFalse(session.canUndo)
        // Nothing applied: the preview is the original.
        XCTAssertEqual(try pixels(session.displayedImage), try pixels(session.originalImage))
    }

    func testAutoUnavailableCannotBeSwitchedOn() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        session.toggleAuto()
        XCTAssertEqual(session.autoState, .unavailable)
        XCTAssertFalse(session.canUndo)
    }

    func testAFailedAutoOffersRetryAndContinueWithOriginal() async throws {
        let session = try await EditorTestSupport.readySession(library: library, autoEnhancer: FailingAutoEnhancer())
        XCTAssertEqual(session.autoState, .failed)
        XCTAssertEqual(panel(session).baseName, "Original")
        session.retryAuto()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.autoState, .failed, "Still failing: still offered")
        session.continueWithOriginal()
        XCTAssertEqual(session.autoState, .off)
        XCTAssertEqual(panel(session).baseName, "Original")
    }

    func testPortraitIsOfferedOnlyWhenAPersonWasFound() async throws {
        let withPerson = try await EditorTestSupport.readySession(library: library, personDetector: FixedPersonDetector(result: true))
        XCTAssertEqual(withPerson.hasPerson, true)
        XCTAssertEqual(EditorTool.available(hasPerson: true), EditorTool.allCases)
        XCTAssertFalse(EditorTool.available(hasPerson: false).contains(.portrait))
        XCTAssertEqual(EditorTool.available(hasPerson: false).count, 6, "Every other tool stays listed")
    }

    /// The app's library loads in the background from launch: a photo opened before it finishes
    /// must still render Looks once it has (regression: the preview had no renderer).
    func testAPhotoOpenedWhileTheLibraryLoadsStillRendersLooks() async throws {
        let loading = DevelopLibrary()
        let session = EditorSession(photo: try await EditorTestSupport.photo(), library: loading,
                                    personDetector: FixedPersonDetector(result: false), previewLongEdge: 640)
        session.start()
        try await Task.sleep(for: .milliseconds(100))
        await loading.loadBundled(lutApplier: try MetalLUTRenderer())
        await session.waitUntilReady()
        let mono = try XCTUnwrap(loading.pack.categories.flatMap(\.presets).first { $0.recipe.global.grayscaleMix != nil })
        session.applyLook(mono)
        await session.settleRendering()
        let mean = EditorTestSupport.mean(session.displayedImage)
        XCTAssertEqual(mean.x, mean.z, accuracy: 0.02, "The black & white Look is on screen")
        XCTAssertNotEqual(try pixels(session.displayedImage), try pixels(session.originalImage))
    }

    // MARK: - Ruler

    func testDraggingPreviewsAndOnlyReleaseCommitsOneStep() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let model = panel(session)
        model.selectCategory(pack.categories[0].id)
        model.dragChanged(to: 1)
        model.dragChanged(to: 2)
        await session.settleRendering()
        XCTAssertNil(session.recipe.look, "Dragging previews; it commits nothing")
        XCTAssertEqual(model.stop, 2)
        XCTAssertEqual(model.displayedName, model.currentPresets[1].displayName)
        XCTAssertNotEqual(try pixels(session.displayedImage), try pixels(session.originalImage), "The photo previews the stop")

        model.dragEnded(at: 2)
        XCTAssertEqual(session.recipe.look?.lookId, model.currentPresets[1].id)
        XCTAssertEqual(session.history.count, 2, "One undo step on release")
        XCTAssertEqual(session.recipe.revision, 1)
        XCTAssertEqual(model.stop, 2)

        session.undo()
        XCTAssertNil(session.recipe.look)
        session.redo()
        XCTAssertEqual(session.recipe.look?.lookId, model.currentPresets[1].id)
    }

    func testReleasingOnTheAppliedStopAddsNoStepAndStopZeroRemovesTheLook() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let model = panel(session)
        model.selectCategory(pack.categories[0].id)
        model.dragEnded(at: 1)
        model.dragChanged(to: 1)
        model.dragEnded(at: 1)
        XCTAssertEqual(session.history.count, 2)
        model.dragEnded(at: 0)
        XCTAssertNil(session.recipe.look)
        XCTAssertEqual(session.history.count, 3)
    }

    func testCategoryChangeAloneNeverChangesTheLookAndShowsTheAppliedContext() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let model = panel(session)
        let first = pack.categories[0], second = pack.categories[1]
        model.selectCategory(first.id)
        model.dragEnded(at: 1)
        let applied = try XCTUnwrap(session.appliedPreset)

        model.selectCategory(second.id)
        XCTAssertEqual(session.appliedPreset, applied)
        XCTAssertEqual(session.history.count, 2)
        XCTAssertEqual(model.stop, 0)
        // Owner amendment 2026-10-05: the name row keeps naming the applied preset, never "Original".
        XCTAssertEqual(model.displayedName, applied.displayName)
        XCTAssertEqual(model.contextLine, "Applied from \(first.name) · 1 / \(first.presets.count)", "The applied preset's own position, in its context")
        XCTAssertEqual(model.positionText, "", "No position beside the name that would read as this ruler's")
        XCTAssertTrue(model.categoryItems.first { $0.id == first.id }!.holdsAppliedPreset, "The applied category keeps its dot")
        XCTAssertEqual(model.currentCategoryID, second.id, "The underline is on the browsed category")

        model.selectCategory(first.id)
        XCTAssertNil(model.contextLine)
        XCTAssertEqual(model.stop, 1)
    }

    /// Owner feedback 2026-10-05: apply Landscape → browse Portrait → apply Portrait → Undo → Redo. At every step the
    /// photo's Look, the underline (browsed category), the dot (applied category) and the name row agree.
    func testBrowsingAndApplyingAcrossCategoriesWithUndoAndRedoStayConsistent() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let model = panel(session)
        let landscape = try XCTUnwrap(pack.category(id: "landscape")), portrait = try XCTUnwrap(pack.category(id: "portrait"))
        func dotted() -> [String] { model.categoryItems.filter { $0.holdsAppliedPreset && !$0.isFavourites }.map(\.id) }

        model.selectCategory(landscape.id); model.dragEnded(at: 3)
        let landscapePreset = landscape.presets[2]
        XCTAssertEqual(session.appliedPreset?.id, landscapePreset.id)
        XCTAssertEqual(model.currentCategoryID, landscape.id); XCTAssertEqual(dotted(), [landscape.id])
        XCTAssertEqual(model.displayedName, landscapePreset.displayName)

        model.selectCategory(portrait.id)
        XCTAssertEqual(session.appliedPreset?.id, landscapePreset.id, "Browsing changes nothing")
        XCTAssertEqual(model.currentCategoryID, portrait.id, "The underline moves at once")
        XCTAssertEqual(dotted(), [landscape.id], "The dot stays with the applied preset")
        XCTAssertEqual(model.displayedName, landscapePreset.displayName, "Not 'Original': the Landscape preset is still applied")
        XCTAssertEqual(model.contextLine, "Applied from \(landscape.name) · 3 / \(landscape.presets.count)")
        XCTAssertEqual(model.positionText, "")
        XCTAssertEqual(model.stop, 0, "The Portrait ruler rests at its start")

        // Dragging the Portrait ruler names what is under the needle, with this ruler's position.
        let historyBefore = session.history.count
        model.dragChanged(to: 4)
        XCTAssertEqual(model.displayedName, portrait.presets[3].displayName)
        XCTAssertEqual(model.positionText, "4 / \(portrait.presets.count)"); XCTAssertNil(model.contextLine)
        // Back to where it started and released: a cancel. The Landscape preset stays applied.
        model.dragChanged(to: 0)
        model.dragEnded(at: 0)
        XCTAssertEqual(session.appliedPreset?.id, landscapePreset.id, "Releasing where the drag started changes nothing")
        XCTAssertEqual(session.history.count, historyBefore)
        XCTAssertEqual(model.displayedName, landscapePreset.displayName)
        XCTAssertEqual(model.currentCategoryID, portrait.id, "Still browsing Portrait")
        // A touch on the resting ruler (no movement past stop 0) also changes nothing.
        model.dragChanged(to: 0); model.dragEnded(at: 0)
        XCTAssertEqual(session.appliedPreset?.id, landscapePreset.id)

        model.dragChanged(to: 2)
        model.dragEnded(at: 2)
        let portraitPreset = portrait.presets[1]
        XCTAssertEqual(session.appliedPreset?.id, portraitPreset.id)
        XCTAssertEqual(model.currentCategoryID, portrait.id); XCTAssertEqual(dotted(), [portrait.id])
        XCTAssertEqual(model.displayedName, portraitPreset.displayName); XCTAssertNil(model.contextLine)

        session.undo()
        XCTAssertEqual(session.appliedPreset?.id, landscapePreset.id)
        XCTAssertEqual(model.currentCategoryID, landscape.id, "After Undo the underline returns to the applied category")
        XCTAssertEqual(dotted(), [landscape.id]); XCTAssertEqual(model.displayedName, landscapePreset.displayName)
        XCTAssertEqual(model.stop, 3); XCTAssertNil(model.contextLine)
        XCTAssertEqual(model.positionText, "3 / \(landscape.presets.count)")

        session.redo()
        XCTAssertEqual(session.appliedPreset?.id, portraitPreset.id)
        XCTAssertEqual(model.currentCategoryID, portrait.id); XCTAssertEqual(dotted(), [portrait.id])
        XCTAssertEqual(model.displayedName, portraitPreset.displayName); XCTAssertEqual(model.stop, 2)
    }

    func testUnavailableAutoExplainsItselfOnlyWhenTapped() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        XCTAssertEqual(session.autoState, .unavailable)
        XCTAssertNil(session.toast)
        session.toggleAuto()
        XCTAssertEqual(session.toast, "Automatic correction isn't available. Presets still work.")
        XCTAssertEqual(session.history.count, 1, "Nothing changes")
    }

    func testDefaultCategoryIsLandscapeAndFavouritesComeFirst() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let model = panel(session)
        XCTAssertEqual(model.currentCategoryID, "landscape")
        XCTAssertEqual(model.categoryItems.first?.id, DevelopPanelModel.favouritesID)
        XCTAssertEqual(Array(model.categoryItems.dropFirst().map(\.id)), pack.categories.map(\.id), "No counts; categories in order")
    }

    func testANewLookReplacesOnlyTheDevelopLook() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let model = panel(session)
        model.selectCategory(pack.categories[0].id)
        model.dragEnded(at: 1)
        let toolsBefore = session.recipe.tools
        let sourceBefore = session.recipe.source
        model.dragEnded(at: 2)
        XCTAssertEqual(session.recipe.look?.lookId, pack.categories[0].presets[1].id)
        XCTAssertEqual(session.recipe.tools, toolsBefore)
        XCTAssertEqual(session.recipe.source, sourceBefore)
        XCTAssertEqual(session.recipe.auto, .noModelInBuild)
    }

    // MARK: - Amount

    func testAmountPreviewsWhileDraggingAndCommitsOneStepOnRelease() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let model = panel(session)
        model.selectCategory(pack.categories[0].id)
        model.dragEnded(at: 1)
        XCTAssertEqual(model.amountButtonTitle, "Amount 100")
        model.openAmount()
        XCTAssertTrue(model.isAmountOpen)
        model.amountChanged(40)
        XCTAssertEqual(model.amountButtonTitle, "Amount 40")
        XCTAssertEqual(session.recipe.look?.strength, 1, "Dragging previews only")
        model.amountEnded(70)
        XCTAssertEqual(session.recipe.look?.strength, 0.7)
        XCTAssertEqual(session.history.count, 3)
        model.closeAmount()
        XCTAssertFalse(model.isAmountOpen)
    }

    func testReselectingTheAppliedPresetKeepsItsAmount() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let model = panel(session)
        model.selectCategory(pack.categories[0].id)
        model.dragEnded(at: 1)
        model.amountEnded(70)
        model.dragChanged(to: 2)
        model.dragEnded(at: 1)
        XCTAssertEqual(session.recipe.look?.strength, 0.7, "Same preset: nothing changes")
        model.dragEnded(at: 2)
        XCTAssertEqual(session.recipe.look?.strength, 1)
        model.dragEnded(at: 1)
        XCTAssertEqual(session.recipe.look?.strength, 0.7, "Returning to it restores its Amount")
    }

    func testAmountZeroRendersTheOriginalAndAmountScalesTheLook() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        session.applyLook(globalOnlyPreset)
        await session.settleRendering()
        let full = EditorTestSupport.mean(session.displayedImage)
        session.commitAmount(0)
        await session.settleRendering()
        XCTAssertEqual(try pixels(session.displayedImage), try pixels(session.originalImage))
        session.commitAmount(50)
        await session.settleRendering()
        let half = EditorTestSupport.mean(session.displayedImage)
        let original = EditorTestSupport.mean(session.originalImage)
        for c in 0..<3 {
            XCTAssertEqual(half[c], (original[c] + full[c]) / 2, accuracy: 0.03, "in + s·(LUT(in) − in)")
        }
    }

    // MARK: - Favourites

    func testStarAddsAndRemovesAFavouriteAndASixthShowsTheFullNotice() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let model = panel(session)
        let presets = pack.categories.flatMap(\.presets)
        model.selectCategory(presets[0].categoryID)
        model.dragEnded(at: presets[0].stop == 1 ? 1 : 1)
        model.toggleStar()
        XCTAssertTrue(model.isPresetAtStopFavourite)
        XCTAssertEqual(model.favourites.presetIDs.count, 1)
        model.toggleStar()
        XCTAssertFalse(model.isPresetAtStopFavourite)

        model.favourites.replaceAll(with: Array(presets.dropFirst().prefix(5).map(\.id)))
        model.toggleStar()
        XCTAssertTrue(model.isFavouritesFullNoticeShown, "Five already: the approved full notice")
        XCTAssertEqual(model.favourites.presetIDs.count, 5)

        let replaced = model.favourites.presetIDs[2]
        model.isReplaceSheetShown = true
        model.replaceFavourite(replaced)
        XCTAssertEqual(model.favourites.presetIDs[2], session.appliedPreset?.id, "Replaced in place, order kept")
        XCTAssertFalse(model.isReplaceSheetShown)
        XCTAssertFalse(model.isFavouritesFullNoticeShown)
    }

    func testFavouritesCategoryListsTheFavouritesInOrder() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let model = panel(session)
        let picks = Array(pack.categories.flatMap(\.presets).suffix(3))
        model.favourites.replaceAll(with: picks.map(\.id))
        model.selectCategory(DevelopPanelModel.favouritesID)
        XCTAssertEqual(model.currentPresets.map(\.id), picks.map(\.id))
        model.dragEnded(at: 2)
        XCTAssertEqual(session.appliedPreset?.id, picks[1].id)
        XCTAssertEqual(model.stop, 2)
        // The dot means "contains the applied preset" (owner amendment 2026-10-05): Favourites holds it.
        XCTAssertTrue(model.categoryItems.contains { $0.id == DevelopPanelModel.favouritesID && $0.holdsAppliedPreset })
    }

    // MARK: - Compare and history

    func testCompareShowsTheOriginalWithoutChangingTheEdit() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        session.applyLook(globalOnlyPreset)
        session.beginCompare()
        XCTAssertTrue(session.isShowingOriginal)
        session.endCompare()
        XCTAssertFalse(session.isShowingOriginal)
        session.toggleCompare()
        XCTAssertTrue(session.isShowingOriginal, "The accessible toggle latches")
        session.toggleCompare()
        XCTAssertEqual(session.recipe.look?.lookId, globalOnlyPreset.id)
        XCTAssertEqual(session.history.count, 2)
    }

    func testUndoRedoRestoreTheWholeRecipe() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        session.applyLook(globalOnlyPreset)
        session.commitAmount(30)
        session.applyLook(spatialPreset)
        let afterAll = session.recipe
        session.undo(); session.undo()
        XCTAssertEqual(session.recipe.look?.lookId, globalOnlyPreset.id)
        XCTAssertEqual(session.recipe.look?.strength, 1)
        session.redo(); session.redo()
        XCTAssertEqual(session.recipe, afterAll)
        session.undo()
        session.applyLook(grayscalePreset)
        XCTAssertFalse(session.canRedo, "A new edit after Undo drops the redo branch")
    }

    // MARK: - Rendering

    func testSpatialAndFinishingOperatorsChangeTheCommittedPreview() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let preset = spatialPreset
        session.previewLook(preset)          // interactive: global stage only
        await session.settleRendering()
        let globalOnly = try pixels(session.displayedImage)
        session.applyLook(preset)            // committed: global, then spatial and finishing
        await session.settleRendering()
        XCTAssertNotEqual(try pixels(session.displayedImage), globalOnly)
    }

    func testTilesDoNotSeam() throws {
        let model = try EditorTestSupport.model()
        let renderer = DevelopFrameRenderer(lutApplier: try MetalLUTRenderer(), model: model)
        let cache = DevelopLUTCache(model: model)
        let image = TestFixtures.makeImage(width: 700, height: 500)
        let source = try MetalLUTRenderer.rgba8Bytes(of: image)
        let plan = DevelopRenderPlan.look(spatialPreset, strength: 1, cache: cache)
        let whole = try renderer.render(plan, pixels: source, width: 700, height: 500, tileSide: 4_096)
        let tiled = try renderer.render(plan, pixels: source, width: 700, height: 500, tileSide: 256)
        let worst = zip(whole, tiled).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, 1, "Tiles with a halo match the whole-frame render")
    }

    func testPreviewAndSaveCopyEvaluateTheSameCommittedRecipe() async throws {
        let writer = SpyLibraryWriter()
        let session = try await EditorTestSupport.readySession(library: library, writer: writer)
        let model = panel(session)
        session.applyLook(grayscalePreset)
        model.selectCategory(pack.categories[0].id)
        model.dragChanged(to: 1)             // a transient preview must not be saved
        session.saveCopy()
        XCTAssertEqual(session.saveState, .saving)
        await EditorTestSupport.waitForSave(session)
        guard case .saved = session.saveState else { return XCTFail("\(session.saveState)") }

        let lastSave = await writer.lastSave()
        let data = try XCTUnwrap(lastSave.data)
        XCTAssertEqual(lastSave.ext, "jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let saved = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(saved.width, session.photo.image.width, "Full resolution, not the preview")
        let mean = EditorTestSupport.mean(saved)
        XCTAssertEqual(mean.x, mean.z, accuracy: 0.02, "The committed black & white Look, not the previewed one")
        model.dragEnded(at: 0)
    }

    func testSaveCopyAppliesTheMetadataSwitchesInAllFourCombinations() async throws {
        let original = try ExportMetadataPolicyTests.makeCameraOriginal()
        let base = TestFixtures.makeImage(width: 240, height: 180)
        let photo = SelectedPhoto(image: base, source: .camera, originalData: original)
        var policy = ExportMetadataPolicy.default
        for combination in ExportMetadataPolicyTests.allCombinations {
            let writer = SpyLibraryWriter()
            let session = try await EditorTestSupport.readySession(photo: photo, library: library, writer: writer,
                                                                   settings: { .saveCopy(metadata: policy) }, previewLongEdge: 200)
            session.applyLook(globalOnlyPreset)
            // Changed after the editor exists: the switches are read when saving.
            policy = combination
            session.saveCopy()
            await EditorTestSupport.waitForSave(session)
            let lastSave = await writer.lastSave()
            let data = try XCTUnwrap(lastSave.data)
            ExportMetadataPolicyTests.assertPolicy(combination, on: try ExportMetadataPolicyTests.WrittenFile(data), width: 240, height: 180)
            // Share (approved `share`): the saved copy's own bytes, so the same render and the same
            // metadata policy, checked on the shared file itself.
            guard case .saved(let savedData) = session.saveState else { return XCTFail("not saved") }
            let shared = try Data(contentsOf: ShareItem(data: savedData).url)
            XCTAssertEqual(shared, data, "Share hands over exactly the saved copy")
            ExportMetadataPolicyTests.assertPolicy(combination, on: try ExportMetadataPolicyTests.WrittenFile(shared), width: 240, height: 180)
            XCTAssertEqual(session.photo.originalData, original, "The original is never modified")
        }
    }

    func testSaveErrorsKeepTheEdit() async throws {
        for (failure, expected) in [(LightlyError.permissionDenied, EditorSession.SaveState.permissionDenied),
                                    (.storageFull, .storageFull), (.exportFailed, .failed)] {
            let session = try await EditorTestSupport.readySession(library: library, writer: SpyLibraryWriter(behaviour: .fail(failure)))
            session.applyLook(globalOnlyPreset)
            session.saveCopy()
            await EditorTestSupport.waitForSave(session)
            XCTAssertEqual(session.saveState, expected)
            XCTAssertEqual(session.recipe.look?.lookId, globalOnlyPreset.id, "Edits are kept")
            XCTAssertTrue(session.hasUnsavedEdits)
            session.dismissSaveState()
            XCTAssertEqual(session.saveState, .idle)
        }
    }

    func testCancellingASaveWritesNothing() async throws {
        let writer = SpyLibraryWriter()
        let session = try await EditorTestSupport.readySession(photo: try await EditorTestSupport.photo(width: 3_000, height: 2_000),
                                                               library: library, writer: writer)
        session.applyLook(spatialPreset)
        session.saveCopy()
        session.cancelSave()
        await EditorTestSupport.waitForSave(session)
        XCTAssertEqual(session.saveState, .idle)
        XCTAssertEqual(session.toast, "Save cancelled · nothing was written")
        try await Task.sleep(for: .seconds(2))
        let saved = await writer.lastSave()
        XCTAssertNil(saved.data, "Cancelled: nothing was written")
    }

    func testAClosedSessionShowsNothingThatFinishesLater() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let before = session.publishedRenderCount
        session.applyLook(spatialPreset)
        session.close()
        await session.settleRendering()
        XCTAssertEqual(session.publishedRenderCount, before)
        session.applyLook(globalOnlyPreset)
        XCTAssertTrue(session.isSessionClosed)
    }

    /// Browsing performance on the simulator: scrubbing 20 consecutive stops at ~60 Hz never
    /// leaves the screen more than 100 ms behind the newest request.
    func testScrubbingTwentyStopsNeverShowsAStalePreview() async throws {
        let photo = try await EditorTestSupport.photo(width: 2_400, height: 1_600)
        // The real catalogue when this build bundles it (20 consecutive stops of one category).
        let developModel = try EditorTestSupport.model()
        let bundled = PresetPackLoader.loadBundled(model: developModel).pack
        let scrubLibrary = bundled.isEmpty ? library! : DevelopLibrary(pack: bundled, model: developModel, lutApplier: try MetalLUTRenderer())
        let session = try await EditorTestSupport.readySession(photo: photo, library: scrubLibrary, previewLongEdge: 1_600)
        let model = panel(session)
        let category = try XCTUnwrap(scrubLibrary.pack.categories.max { $0.presets.count < $1.presets.count })
        model.selectCategory(category.id)
        let stops = min(20, category.presets.count)
        for stop in 1...stops {
            model.dragChanged(to: stop)
            try await Task.sleep(for: .milliseconds(16))
        }
        model.dragEnded(at: stops)
        await session.settleRendering()
        let worst = session.previewStaleness.max() ?? .zero
        let sorted = session.previewStaleness.sorted()
        print("SCRUB staleness worst \(worst), median \(sorted[sorted.count / 2]) over \(sorted.count) requests, \(stops) stops, in order \(session.previewStaleness.map { Int(Double($0.components.attoseconds) / 1e15) }) ms, optimised: \(!_isDebugAssertConfiguration())")
        // Timing targets apply to optimised code; an unoptimised (-Onone) test build only reports.
        try XCTSkipIf(_isDebugAssertConfiguration(), "Unoptimised build: staleness recorded, not asserted")
        XCTAssertLessThanOrEqual(worst, .milliseconds(100))
    }

    /// Owner request 2026-10-06: the photo previews each newly crossed stop while the finger moves (reduced-size drag
    /// frames), the latest request wins, release commits one Undo step at normal preview quality, Undo restores.
    func testRulerDragPreviewsEveryCrossedStopAndTheLatestWins() async throws {
        let photo = try await EditorTestSupport.photo(width: 2_400, height: 1_600)
        let session = try await EditorTestSupport.readySession(photo: photo, library: library, previewLongEdge: 1_600)
        let model = panel(session)
        // The category with the most presets in this test pack.
        let landscape = try XCTUnwrap(pack.categories.max { $0.presets.count < $1.presets.count })
        let count = landscape.presets.count
        XCTAssertGreaterThanOrEqual(count, 4, "needs a few stops")
        model.selectCategory(landscape.id)
        let fullWidth = session.displayedImage.width
        let steps = session.history.count

        // Slow drag: every stop crossed is shown before the finger moves on.
        var frameTimes: [Duration] = []
        for stop in 1...min(6, count) {
            let start = ContinuousClock.now
            model.dragChanged(to: stop)
            await session.settleRendering()
            frameTimes.append(ContinuousClock.now - start)
            let last = try XCTUnwrap(session.debugPublished.last)
            XCTAssertEqual(last.lookID, landscape.presets[stop - 1].id, "stop \(stop) is on screen during the drag")
            XCTAssertTrue(last.dragFrame)
            XCTAssertLessThan(session.displayedImage.width, fullWidth, "a reduced-size drag frame")
        }
        print("drag frame times (simulator, cold LUTs except prefetched): \(frameTimes)")

        // Fast scrub and reverse without waiting: only the newest request may end on screen; frames never go backwards.
        let before = session.debugPublished.count
        let target = max(2, count / 2)
        for _ in 0..<3 {   // several sweeps, so many more requests than stops
            for stop in 1...count { model.dragChanged(to: stop) }
            for stop in stride(from: count, through: target, by: -1) { model.dragChanged(to: stop) }
        }
        await session.settleRendering()
        let scrub = session.debugPublished[before...]
        XCTAssertEqual(scrub.last?.lookID, landscape.presets[target - 1].id, "the latest selection is what stays on screen")
        XCTAssertEqual(Array(scrub.map(\.generation)), scrub.map(\.generation).sorted(), "no older frame after a newer one")
        XCTAssertLessThan(scrub.count, 3 * (2 * count - target + 1) / 2, "intermediate renders were skipped, not queued for playback")
        XCTAssertEqual(session.history.count, steps, "dragging records nothing")

        model.dragEnded(at: target)
        await session.settleRendering()
        XCTAssertEqual(session.history.count, steps + 1, "one Undo step for the whole drag")
        XCTAssertEqual(session.appliedPreset?.id, landscape.presets[target - 1].id)
        XCTAssertEqual(session.displayedImage.width, fullWidth, "the settled selection at normal preview quality")
        XCTAssertFalse(try XCTUnwrap(session.debugPublished.last).dragFrame)

        session.undo()
        await session.settleRendering()
        XCTAssertNil(session.appliedPreset, "Undo restores the previous edit")
        XCTAssertEqual(session.history.count, steps + 1)
    }
}
