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

    // MARK: - Strength, Redo, notices

    /// Strength at 40% after an undo: Strength shown (secondary), Redo enabled.
    func testStrengthAndRedo() async throws {
        let viewModel = try await EditorFixtures.readyEditor(lookStop: 2)
        viewModel.commitLookStrength(0.4)
        viewModel.commitLookStrength(0.6)
        viewModel.undo()
        await viewModel.settleRendering()
        SnapshotAssertion.assert(of: editor(viewModel), named: "editor-lut-strength-redo")
    }

    /// A restored edit whose Look changed: not applied, compact notice with "Use current version".
    func testLookChangedNotice() async throws {
        let viewModel = try await EditorFixtures.restoredEditor(
            look: SavedLookRef(lookId: "fixture-warm-000002", lookVersion: "legacy-v1-2", strength: 1)
        )
        SnapshotAssertion.assert(of: editor(viewModel), named: "editor-lut-look-changed")
    }

    /// A restored edit whose Look is not in this pack: not applied, notice, nothing substituted.
    func testLookUnavailableNotice() async throws {
        let viewModel = try await EditorFixtures.restoredEditor(
            look: SavedLookRef(lookId: "no-such-look-000000", lookVersion: "000000000000", strength: 1)
        )
        SnapshotAssertion.assert(of: editor(viewModel), named: "editor-lut-look-unavailable")
    }

    /// A genuine Auto failure: Retry and Continue, the photo still visible.
    func testAutoFailed() async throws {
        let viewModel = try await EditorFixtures.readyEditor(auto: ScriptedAutoEnhancer(results: [.unavailable(.invalidBasis)]))
        SnapshotAssertion.assert(of: editor(viewModel), named: "editor-lut-auto-failed")
    }

    // MARK: - Wide screens

    func testPhoneLandscape() async throws {
        let viewModel = try await EditorFixtures.readyEditor(lookStop: 2)
        SnapshotAssertion.assert(of: editor(viewModel), named: "editor-lut-phone-landscape", size: CGSize(width: 874, height: 402))
    }

    func testPadPortrait() async throws {
        let viewModel = try await EditorFixtures.readyEditor(lookStop: 2)
        SnapshotAssertion.assert(of: editor(viewModel), named: "editor-lut-pad-portrait", size: CGSize(width: 834, height: 1_210))
    }

    /// A landscape photo on iPad portrait is shown larger full width, so the controls go below.
    func testPadPortraitLandscapePhoto() async throws {
        let viewModel = try await EditorFixtures.readyEditor(lookStop: 2, photo: EditorFixtures.landscapePhoto())
        SnapshotAssertion.assert(of: editor(viewModel), named: "editor-lut-pad-portrait-landscape-photo",
                                 size: CGSize(width: 834, height: 1_210))
    }

    func testPadLandscapeComparing() async throws {
        let viewModel = try await EditorFixtures.readyEditor(lookStop: 2)
        viewModel.toggleCompare()
        SnapshotAssertion.assert(of: editor(viewModel), named: "editor-lut-pad-landscape-comparing",
                                 size: CGSize(width: 1_210, height: 834))
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
