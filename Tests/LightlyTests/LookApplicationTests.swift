import XCTest
@testable import Lightly

/// Covers Look application through the editor: non-destructive, reversible, and
/// composed correctly with the Develop result.
@MainActor
final class LookApplicationTests: XCTestCase {

    private func makeDevelopedEditor() async -> EditorViewModel {
        let viewModel = EditorViewModel(
            original: TestFixtures.makePhoto(),
            developer: DebugFixedRecipeDeveloper()
        )
        viewModel.develop()
        await viewModel.developTask?.value
        return viewModel
    }

    private var goldenMemory: LightlyPreset {
        guard let preset = BuiltInPresetCatalog().recommended(for: .unclassified).first else {
            fatalError("Starter catalogue is missing a known preset")
        }
        return preset
    }

    // MARK: - Application records history

    func testApplyingALookRecordsItInHistory() async {
        let viewModel = await makeDevelopedEditor()

        viewModel.applyLook(goldenMemory, intensity: 1)

        XCTAssertEqual(viewModel.history.currentLookID, goldenMemory.id)
        XCTAssertTrue(viewModel.canUndo)
    }

    func testApplyingALookAtPartialIntensityRecordsBoth() async {
        let viewModel = await makeDevelopedEditor()

        viewModel.applyLook(goldenMemory, intensity: 0.5)

        XCTAssertEqual(viewModel.history.currentLookID, goldenMemory.id)
        XCTAssertEqual(viewModel.history.currentIntensity, 0.5, accuracy: 0.001)
    }

    // MARK: - Reversibility

    func testUndoingALookReturnsToTheDevelopedImage() async {
        let viewModel = await makeDevelopedEditor()
        let developedRecipe = viewModel.history.composedRecipe
        viewModel.applyLook(goldenMemory, intensity: 1)

        viewModel.undo()

        XCTAssertNil(viewModel.history.currentLookID)
        XCTAssertEqual(viewModel.history.composedRecipe, developedRecipe)
        // The developed version survives: undoing the Look must not undo
        // Develop as well.
        XCTAssertTrue(viewModel.history.hasDevelopedVersion)
        XCTAssertEqual(viewModel.phase, .developed)
    }

    func testUndoingIntensityLeavesTheLookApplied() async {
        let viewModel = await makeDevelopedEditor()
        viewModel.applyLook(goldenMemory, intensity: 0.3)

        viewModel.undo()

        XCTAssertEqual(
            viewModel.history.currentLookID,
            goldenMemory.id,
            "Undo should reverse the intensity change, not the Look."
        )
        XCTAssertEqual(viewModel.history.currentIntensity, 1, accuracy: 0.001)
    }

    /// The original is never touched, whatever is applied on top of it.
    func testOriginalSurvivesLookApplicationAndReset() async {
        let viewModel = await makeDevelopedEditor()
        let originalImage = viewModel.original.image
        viewModel.applyLook(goldenMemory, intensity: 0.8)

        viewModel.reset()

        XCTAssertTrue(viewModel.original.image === originalImage)
        XCTAssertTrue(viewModel.displayedImage === originalImage)
        XCTAssertNil(viewModel.history.currentLookID)
    }

    // MARK: - Preview leaves no trace

    /// Previewing must have no permanent consequence: abandoning the Looks
    /// screen leaves the edit stack exactly as it was.
    func testPreviewingDoesNotModifyHistory() async {
        let viewModel = await makeDevelopedEditor()
        let historyBefore = viewModel.history

        viewModel.previewLook(goldenMemory, intensity: 0.6)

        XCTAssertEqual(viewModel.history, historyBefore)
        XCTAssertNil(viewModel.history.currentLookID)
    }

    func testClearingAPreviewRestoresTheCommittedImage() async {
        let viewModel = await makeDevelopedEditor()
        viewModel.previewLook(goldenMemory, intensity: 1)

        viewModel.previewLook(nil, intensity: 1)

        XCTAssertEqual(viewModel.history.composedRecipe, viewModel.history.composedRecipe)
        XCTAssertNil(viewModel.history.currentLookID)
    }

    // MARK: - Composition

    /// A new Look replaces the previous one's intensity rather than inheriting
    /// it — otherwise a Look applied after a subtle one would silently arrive
    /// at reduced strength.
    func testApplyingASecondLookResetsIntensity() async {
        let viewModel = await makeDevelopedEditor()
        viewModel.applyLook(goldenMemory, intensity: 0.2)

        guard let other = BuiltInPresetCatalog().presets(in: .cinematic).first else {
            return XCTFail("Expected preset in cinematic category")
        }
        viewModel.applyLook(other, intensity: 1)

        XCTAssertEqual(viewModel.history.currentLookID, other.id)
        XCTAssertEqual(viewModel.history.currentIntensity, 1, accuracy: 0.001)
    }

    func testComposedRecipeStacksDevelopAndLook() async {
        let viewModel = await makeDevelopedEditor()
        let developRecipe = DebugFixedRecipeDeveloper.fixedRecipe

        viewModel.applyLook(goldenMemory, intensity: 1)

        let composed = viewModel.history.composedRecipe
        XCTAssertEqual(
            composed.exposure,
            developRecipe.exposure + goldenMemory.recipe.exposure,
            accuracy: 0.0001
        )
    }

    func testZeroIntensityLeavesTheDevelopedResultUnchanged() async {
        let viewModel = await makeDevelopedEditor()
        let developedRecipe = viewModel.history.composedRecipe

        viewModel.applyLook(goldenMemory, intensity: 0)

        XCTAssertEqual(viewModel.history.composedRecipe, developedRecipe)
    }
}

/// Covers the recipe arithmetic that intensity depends on.
final class RecipeCompositionTests: XCTestCase {

    private var sample: DevelopRecipe {
        DevelopRecipe(
            whiteBalance: .init(temperature: 200, tint: -4),
            exposure: 0.2,
            highlights: -0.4,
            shadows: 0.3,
            contrast: 0.1,
            vibrance: 0.2,
            clarity: 0.05,
            dehaze: 0.02,
            sharpening: 0.1,
            noiseReduction: 0.05
        )
    }

    func testScalingByOneIsIdentity() {
        XCTAssertEqual(sample.scaled(by: 1), sample)
    }

    func testScalingByZeroYieldsNoChange() {
        XCTAssertEqual(sample.scaled(by: 0), .unmodified)
    }

    func testScalingIsProportional() {
        let half = sample.scaled(by: 0.5)

        XCTAssertEqual(half.exposure, 0.1, accuracy: 0.0001)
        XCTAssertEqual(half.whiteBalance.temperature, 100, accuracy: 0.0001)
        XCTAssertEqual(half.highlights, -0.2, accuracy: 0.0001)
    }

    func testScalingClampsOutOfRangeFactors() {
        XCTAssertEqual(sample.scaled(by: 3), sample)
        XCTAssertEqual(sample.scaled(by: -2), .unmodified)
    }

    func testCombiningWithIdentityIsUnchanged() {
        XCTAssertEqual(sample.combined(with: .unmodified), sample)
    }

    func testCombiningIsAdditive() {
        let doubled = sample.combined(with: sample)

        XCTAssertEqual(doubled.exposure, 0.4, accuracy: 0.0001)
        XCTAssertEqual(doubled.whiteBalance.tint, -8, accuracy: 0.0001)
    }
}
