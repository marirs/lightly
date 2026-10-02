import SwiftUI
import XCTest
@testable import Lightly

/// Snapshot coverage for the editor wired to `LUTEditSession`: developing,
/// ready with Auto unavailable, a Look applied, Compare, Save copy
/// confirmation, the failure state, both appearances and large text.
///
/// References are recorded on first run and committed; a later layout or copy
/// change that alters any of these screens will fail here.
@MainActor
final class EditorSnapshotTests: XCTestCase {

    private func editor(_ viewModel: LUTEditorViewModel) -> some View {
        EditorView(viewModel: viewModel, onBack: {})
    }

    // MARK: - Developing

    func testDevelopingLight() throws {
        let viewModel = try EditorFixtures.developingEditor()
        defer { viewModel.close() }
        SnapshotAssertion.assert(of: editor(viewModel), named: "editor-lut-developing-light")
    }

    // MARK: - Ready (Auto unavailable)

    func testReadyLight() async throws {
        let viewModel = try await EditorFixtures.readyEditor()
        SnapshotAssertion.assert(of: editor(viewModel), named: "editor-lut-ready-light")
    }

    func testReadyDark() async throws {
        let viewModel = try await EditorFixtures.readyEditor()
        SnapshotAssertion.assert(of: editor(viewModel), named: "editor-lut-ready-dark", colorScheme: .dark)
    }

    func testReadyAccessibilityTextSize() async throws {
        let viewModel = try await EditorFixtures.readyEditor(lookStop: 1)
        let view = editor(viewModel).environment(\.dynamicTypeSize, .accessibility3)
        SnapshotAssertion.assert(of: view, named: "editor-lut-look-applied-accessibility3")
    }

    // DEFERRED: a long-preset-name snapshot at AX3. On the pinned 402×874
    // canvas the AX3 panel scrolls the slider below the fold, so it would
    // only duplicate editor-lut-look-applied-accessibility3; it needs a taller
    // canvas. EditorLayoutTests.testLongPresetNameWrapsAtAccessibility3
    // checks that the name wraps instead of truncating.

    /// A build without a Look pack says so instead of showing an empty slider.
    func testNoLooksInBuild() async throws {
        let viewModel = try await EditorFixtures.readyEditor(lookBook: .empty)
        SnapshotAssertion.assert(of: editor(viewModel), named: "editor-lut-no-looks")
    }

    // MARK: - Looks, Compare, Save copy

    func testLookApplied() async throws {
        let viewModel = try await EditorFixtures.readyEditor()
        viewModel.selectCategory("cat-beta")
        viewModel.settleStop(2)
        await viewModel.settleRendering()
        SnapshotAssertion.assert(of: editor(viewModel), named: "editor-lut-look-applied")
    }

    /// Compare engaged: the original must be on screen and the toggle shown
    /// as selected.
    func testComparing() async throws {
        let viewModel = try await EditorFixtures.readyEditor(lookStop: 1)
        viewModel.toggleCompare()
        SnapshotAssertion.assert(of: editor(viewModel), named: "editor-lut-comparing")
    }

    func testSavedConfirmation() async throws {
        let viewModel = try await EditorFixtures.readyEditor(lookStop: 1)
        viewModel.saveCopy()
        await viewModel.saveTask?.value
        SnapshotAssertion.assert(of: editor(viewModel), named: "editor-lut-saved")
    }

    // MARK: - Failure

    /// No renderer: the editor says so and offers a way out, with the
    /// original still visible.
    func testFailureState() {
        let viewModel = LUTEditorViewModel(
            photo: TestFixtures.makePhoto(), autoEnhancer: ModelNotBundledAutoEnhancer(),
            lookBook: LookPackFixture.editorBook, renderer: nil, libraryWriter: SpyLibraryWriter()
        )
        SnapshotAssertion.assert(of: editor(viewModel), named: "editor-lut-failed")
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
