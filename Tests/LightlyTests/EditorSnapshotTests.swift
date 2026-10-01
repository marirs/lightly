import SwiftUI
import XCTest
@testable import Lightly

/// Snapshot coverage for the editor phases, both appearances, Dynamic Type, and
/// the error states reachable in this milestone.
///
/// References are recorded on first run and committed; a later layout or copy
/// change that alters any of these screens will fail here.
@MainActor
final class EditorSnapshotTests: XCTestCase {

    // MARK: - Helpers

    private func makeViewModel(
        developer: any PhotoDeveloping = DebugFixedRecipeDeveloper()
    ) -> EditorViewModel {
        EditorViewModel(original: TestFixtures.makePhoto(), developer: developer)
    }

    private func editor(_ viewModel: EditorViewModel) -> some View {
        EditorView(viewModel: viewModel, onBack: {})
    }

    // MARK: - Phase: ready to develop

    func testPreDevelopLight() {
        let view = editor(makeViewModel())
        SnapshotAssertion.assert(of: view, named: "editor-predevelop-light")
    }

    func testPreDevelopDark() {
        let view = editor(makeViewModel())
        SnapshotAssertion.assert(of: view, named: "editor-predevelop-dark", colorScheme: .dark)
    }

    /// Verifies the largest accessibility text size does not break the layout.
    func testPreDevelopAccessibilityTextSize() {
        let view = editor(makeViewModel())
            .environment(\.dynamicTypeSize, .accessibility3)
        SnapshotAssertion.assert(of: view, named: "editor-predevelop-accessibility3")
    }

    // MARK: - Phase: developing

    func testDevelopingLight() {
        let viewModel = makeViewModel(developer: NeverCompletingDeveloper())
        viewModel.develop()

        let view = editor(viewModel)
        SnapshotAssertion.assert(of: view, named: "editor-developing-light")

        viewModel.cancelDevelop()
    }

    func testDevelopingDark() {
        let viewModel = makeViewModel(developer: NeverCompletingDeveloper())
        viewModel.develop()

        let view = editor(viewModel)
        SnapshotAssertion.assert(of: view, named: "editor-developing-dark", colorScheme: .dark)

        viewModel.cancelDevelop()
    }

    /// The overlay is snapshot directly so partial stage completion can be
    /// rendered deterministically, without racing an in-flight develop.
    func testDevelopingOverlayPartialProgress() {
        let view = ZStack {
            Color.gray
            DevelopingOverlay(
                stages: DebugFixedRecipeDeveloper().performedStages,
                completedStages: [.whiteBalance, .exposure]
            )
        }
        SnapshotAssertion.assert(of: view, named: "developing-overlay-partial")
    }

    func testDevelopingOverlayAccessibilityTextSize() {
        let view = ZStack {
            Color.gray
            DevelopingOverlay(
                stages: DebugFixedRecipeDeveloper().performedStages,
                completedStages: [.whiteBalance]
            )
        }
        .environment(\.dynamicTypeSize, .accessibility3)

        SnapshotAssertion.assert(of: view, named: "developing-overlay-accessibility3")
    }

    // MARK: - Phase: developed

    func testDevelopedLight() async {
        let viewModel = makeViewModel()
        viewModel.develop()
        await viewModel.developTask?.value

        let view = editor(viewModel)
        SnapshotAssertion.assert(of: view, named: "editor-developed-light")
    }

    func testDevelopedDark() async {
        let viewModel = makeViewModel()
        viewModel.develop()
        await viewModel.developTask?.value

        let view = editor(viewModel)
        SnapshotAssertion.assert(of: view, named: "editor-developed-dark", colorScheme: .dark)
    }

    func testDevelopedAccessibilityTextSize() async {
        let viewModel = makeViewModel()
        viewModel.develop()
        await viewModel.developTask?.value

        let view = editor(viewModel).environment(\.dynamicTypeSize, .accessibility3)
        SnapshotAssertion.assert(of: view, named: "editor-developed-accessibility3")
    }

    /// Compare engaged: the original must be on screen.
    func testDevelopedShowingOriginal() async {
        let viewModel = makeViewModel()
        viewModel.develop()
        await viewModel.developTask?.value
        viewModel.beginCompare()

        let view = editor(viewModel)
        SnapshotAssertion.assert(of: view, named: "editor-developed-comparing")
    }

    // MARK: - Error states

    /// Spec §28: a failed Develop returns to the pre-develop screen with the
    /// original intact and a defined message presented.
    func testDevelopFailureState() async {
        let viewModel = makeViewModel(developer: FailingDeveloper())
        viewModel.develop()
        await viewModel.developTask?.value

        let view = editor(viewModel)
        SnapshotAssertion.assert(of: view, named: "editor-develop-failed")
    }

    // MARK: - Non-production disclosure

    /// The debug notice must be visible whenever a non-production engine is in
    /// use (spec §24.8).
    func testDebugDisclosureIsVisibleWithDebugEngine() {
        let view = editor(makeViewModel(developer: DebugFixedRecipeDeveloper()))
        SnapshotAssertion.assert(of: view, named: "editor-debug-disclosure-visible")
    }

    /// ...and absent for a production engine, proving it is engine-driven.
    func testDebugDisclosureIsAbsentWithProductionEngine() {
        let view = editor(makeViewModel(developer: StubProductionDeveloper()))
        SnapshotAssertion.assert(of: view, named: "editor-debug-disclosure-absent")
    }
}

/// Snapshot coverage for the launch and source-selection screens from
/// milestone 1, so that editor work cannot silently regress them.
@MainActor
final class LaunchSnapshotTests: XCTestCase {

    private var appState: AppState {
        AppState(photoLoader: ImageIOPhotoLoader())
    }

    func testLaunchLight() {
        let view = LaunchView()
            .environment(appState)
            
        SnapshotAssertion.assert(of: view, named: "launch-light")
    }

    func testLaunchDark() {
        let view = LaunchView()
            .environment(appState)
            
        SnapshotAssertion.assert(of: view, named: "launch-dark", colorScheme: .dark)
    }

    func testLaunchAccessibilityTextSize() {
        let view = LaunchView()
            .environment(appState)
            .environment(\.dynamicTypeSize, .accessibility3)
        SnapshotAssertion.assert(of: view, named: "launch-accessibility3")
    }

    func testSourceSheetLight() {
        let view = SourceSelectionSheet()
            .environment(appState)
            
        SnapshotAssertion.assert(
            of: view,
            named: "source-sheet-light",
            size: CGSize(width: 402, height: 280)
        )
    }

    func testSourceSheetDark() {
        let view = SourceSelectionSheet()
            .environment(appState)
            
        SnapshotAssertion.assert(
            of: view,
            named: "source-sheet-dark",
            size: CGSize(width: 402, height: 280),
            colorScheme: .dark
        )
    }

    func testSourceSheetAccessibilityTextSize() {
        let view = SourceSelectionSheet()
            .environment(appState)
            .environment(\.dynamicTypeSize, .accessibility3)
        SnapshotAssertion.assert(
            of: view,
            named: "source-sheet-accessibility3",
            // The sheet opens at the large detent at accessibility sizes
            // (SourceSelectionSheet.detents), so the snapshot is full height.
            size: SnapshotAssertion.defaultSize
        )
    }
}
