import SwiftUI
import XCTest
@testable import Lightly

/// The photograph is the subject of the editor (spec D4): no control may
/// cover it, at any text size, and it must keep a usable share of the
/// screen even at the largest accessibility sizes.
@MainActor
final class EditorLayoutTests: XCTestCase {

    private func layout(_ viewModel: LUTEditorViewModel, size: DynamicTypeSize) -> LayoutProbe {
        LayoutProbe(EditorView(viewModel: viewModel, onBack: {}), size: SnapshotAssertion.defaultSize, dynamicTypeSize: size)
    }

    private func assertPhotoUncoveredAndVisible(
        _ viewModel: LUTEditorViewModel, size: DynamicTypeSize,
        minimumPhotoShare: CGFloat, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let probe = layout(viewModel, size: size)
        defer { probe.tearDown() }
        let photo = try XCTUnwrap(probe.frame("editor.photo"), "photo not laid out; have \(probe.frames.keys.sorted())", file: file, line: line)
        let controls = try XCTUnwrap(probe.frame("editor.bottomControls"), "controls not laid out at \(size)", file: file, line: line)

        let covered = photo.intersection(controls)
        XCTAssertTrue(covered.isNull || covered.height < 0.5,
                      "Controls cover \(covered.height) pt of the photo at \(size)", file: file, line: line)
        // The fixture photo is portrait (3:4), so its fitted height is the
        // limiting dimension.
        let share = photo.height / SnapshotAssertion.defaultSize.height
        XCTAssertGreaterThanOrEqual(share, minimumPhotoShare,
                                    "Photo is only \(Int(share * 100))% of the screen height at \(size)", file: file, line: line)
    }

    func testReadyEditorAtStandardSize() async throws {
        try assertPhotoUncoveredAndVisible(try await EditorFixtures.readyEditor(lookStop: 1), size: .large, minimumPhotoShare: 0.4)
    }

    func testReadyEditorAtAccessibility3() async throws {
        try assertPhotoUncoveredAndVisible(try await EditorFixtures.readyEditor(lookStop: 1), size: .accessibility3, minimumPhotoShare: 0.2)
    }

    func testReadyEditorAtAccessibility5() async throws {
        try assertPhotoUncoveredAndVisible(try await EditorFixtures.readyEditor(lookStop: 1), size: .accessibility5, minimumPhotoShare: 0.2)
    }

    func testDevelopingEditorAtAccessibility5() throws {
        let viewModel = try EditorFixtures.developingEditor()
        defer { viewModel.close() }
        try assertPhotoUncoveredAndVisible(viewModel, size: .accessibility5, minimumPhotoShare: 0.2)
    }

    /// Spec D4: the bottom panel takes at most 35% of the height on a
    /// compact screen at standard text size.
    func testBottomPanelStaysWithinItsShareAtStandardSize() async throws {
        let probe = layout(try await EditorFixtures.readyEditor(), size: .large)
        defer { probe.tearDown() }
        let controls = try XCTUnwrap(probe.frame("editor.bottomControls"))

        XCTAssertLessThanOrEqual(controls.height, SnapshotAssertion.defaultSize.height * 0.35 + 0.5)
    }

    /// Every edit action stays on screen (reachable) at AX5, scrolled or not.
    func testEveryActionIsLaidOutAtAccessibility5() async throws {
        let probe = layout(try await EditorFixtures.readyEditor(lookStop: 1), size: .accessibility5)
        defer { probe.tearDown() }
        for anchor in ["editor.lookSlider", "editor.control.action.undo", "editor.control.action.reset",
                       "editor.control.action.compare", "editor.control.action.saveCopy"] {
            XCTAssertNotNil(probe.frame(anchor), "\(anchor) missing at AX5; have \(probe.frames.keys.sorted())")
        }
    }
}
