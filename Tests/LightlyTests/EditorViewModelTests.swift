import XCTest
@testable import Lightly

@MainActor
final class EditorViewModelTests: XCTestCase {

    private func makeViewModel(
        developer: any PhotoDeveloping = DebugFixedRecipeDeveloper()
    ) -> EditorViewModel {
        EditorViewModel(original: TestFixtures.makePhoto(), developer: developer)
    }

    // MARK: - Pre-develop boundary

    func testStartsReadyToDevelop() {
        let viewModel = makeViewModel()

        XCTAssertEqual(viewModel.phase, .readyToDevelop)
        XCTAssertTrue(viewModel.history.operations.isEmpty)
    }

    /// Spec §0.11 and §4.3: Compare must be unavailable until a developed
    /// version exists.
    func testCompareIsUnavailableBeforeDevelopment() {
        let viewModel = makeViewModel()

        XCTAssertFalse(viewModel.isCompareAvailable)
        XCTAssertFalse(viewModel.isShareAvailable)
    }

    func testBeginCompareIsIgnoredBeforeDevelopment() {
        let viewModel = makeViewModel()

        viewModel.beginCompare()

        XCTAssertFalse(
            viewModel.isShowingOriginal,
            "Compare must not engage before a developed version exists."
        )
    }

    // MARK: - Developing boundary

    func testDevelopEntersDevelopingPhaseImmediately() {
        let viewModel = makeViewModel(developer: NeverCompletingDeveloper())

        viewModel.develop()

        XCTAssertEqual(viewModel.phase, .developing)
        viewModel.cancelDevelop()
    }

    /// Spec §4.4: only genuine stages may be displayed. The debug engine does
    /// not perform Detail or Clarity, so it must not advertise them.
    func testOnlyStagesTheEnginePerformsAreDisplayed() {
        let viewModel = makeViewModel(developer: DebugFixedRecipeDeveloper())

        XCTAssertEqual(
            viewModel.displayedStages,
            [.whiteBalance, .exposure, .highlights, .shadows, .colour]
        )
        XCTAssertFalse(viewModel.displayedStages.contains(.detail))
        XCTAssertFalse(viewModel.displayedStages.contains(.clarity))
    }

    func testCancellingDevelopReturnsToReadyWithoutError() async {
        let viewModel = makeViewModel(developer: NeverCompletingDeveloper())
        viewModel.develop()

        viewModel.cancelDevelop()
        await viewModel.developTask?.value

        XCTAssertEqual(viewModel.phase, .readyToDevelop)
        XCTAssertNil(viewModel.activeError)
        XCTAssertTrue(viewModel.completedStages.isEmpty)
    }

    // MARK: - Developed boundary

    func testSuccessfulDevelopEnablesCompareAndShare() async {
        let viewModel = makeViewModel()

        viewModel.develop()
        await viewModel.developTask?.value

        XCTAssertEqual(viewModel.phase, .developed)
        XCTAssertTrue(viewModel.isCompareAvailable)
        XCTAssertTrue(viewModel.isShareAvailable)
        XCTAssertTrue(viewModel.history.hasDevelopedVersion)
    }

    /// The rendering must genuinely change pixels — a placeholder that returns
    /// the input unchanged would make Compare meaningless.
    func testDevelopProducesADifferentImageFromTheOriginal() async {
        let viewModel = makeViewModel()

        viewModel.develop()
        await viewModel.developTask?.value

        XCTAssertFalse(
            viewModel.renderedImage === viewModel.original.image,
            "Develop must produce a genuinely rendered image, not the original."
        )
    }

    func testCompareShowsTheOriginalWhileHeld() async {
        let viewModel = makeViewModel()
        viewModel.develop()
        await viewModel.developTask?.value

        viewModel.beginCompare()
        XCTAssertTrue(viewModel.displayedImage === viewModel.original.image)

        viewModel.endCompare()
        XCTAssertFalse(viewModel.displayedImage === viewModel.original.image)
    }

    // MARK: - Original preservation

    /// Spec §2.6: the original is never overwritten, through any operation.
    func testOriginalIsPreservedThroughDevelopAndUndo() async {
        let viewModel = makeViewModel()
        let originalImage = viewModel.original.image

        viewModel.develop()
        await viewModel.developTask?.value
        viewModel.undo()

        XCTAssertTrue(
            viewModel.original.image === originalImage,
            "The original asset must never be replaced."
        )
        XCTAssertTrue(viewModel.displayedImage === originalImage)
    }

    // MARK: - History

    func testUndoRemovesTheDevelopmentAndRevokesCompare() async {
        let viewModel = makeViewModel()
        viewModel.develop()
        await viewModel.developTask?.value

        viewModel.undo()

        XCTAssertEqual(viewModel.phase, .readyToDevelop)
        XCTAssertFalse(viewModel.isCompareAvailable)
        XCTAssertFalse(viewModel.canUndo)
    }

    /// Compare must not remain engaged after an undo removes the developed
    /// version — otherwise the user is left holding a control that no longer
    /// has a second state to show.
    func testUndoWhileComparingClearsTheComparison() async {
        let viewModel = makeViewModel()
        viewModel.develop()
        await viewModel.developTask?.value
        viewModel.beginCompare()

        viewModel.undo()

        XCTAssertFalse(viewModel.isShowingOriginal)
    }

    func testResetReturnsToTheOriginal() async {
        let viewModel = makeViewModel()
        viewModel.develop()
        await viewModel.developTask?.value

        viewModel.reset()

        XCTAssertEqual(viewModel.phase, .readyToDevelop)
        XCTAssertTrue(viewModel.history.operations.isEmpty)
        XCTAssertTrue(viewModel.displayedImage === viewModel.original.image)
    }

    // MARK: - Failure

    /// Spec §28: a failed Develop leaves the original unchanged and returns the
    /// user to a usable state rather than stranding the UI.
    func testFailedDevelopReturnsToReadyAndPreservesTheOriginal() async {
        let viewModel = makeViewModel(developer: FailingDeveloper())

        viewModel.develop()
        await viewModel.developTask?.value

        XCTAssertEqual(viewModel.phase, .readyToDevelop)
        XCTAssertEqual(viewModel.activeError, .developFailed)
        XCTAssertTrue(viewModel.displayedImage === viewModel.original.image)
        XCTAssertFalse(viewModel.isCompareAvailable)
    }

    // MARK: - Non-production disclosure

    /// Spec §24.8: the disclosure is driven by the engine's own declaration, so
    /// a placeholder cannot be presented as finished by forgetting a flag.
    func testDebugEngineRequiresDisclosure() {
        let viewModel = makeViewModel(developer: DebugFixedRecipeDeveloper())

        XCTAssertTrue(viewModel.requiresDebugDisclosure)
    }

    func testProductionEngineRequiresNoDisclosure() {
        let viewModel = makeViewModel(developer: StubProductionDeveloper())

        XCTAssertFalse(viewModel.requiresDebugDisclosure)
    }
}
