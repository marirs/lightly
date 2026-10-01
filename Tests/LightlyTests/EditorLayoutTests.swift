import SwiftUI
import XCTest
@testable import Lightly

/// The photograph is the subject of the editor (spec §4.3); at accessibility
/// text sizes the enlarged controls must not cover it.
@MainActor
final class EditorLayoutTests: XCTestCase {

    private func editor(developed: Bool) async -> EditorViewModel {
        let viewModel = EditorViewModel(original: TestFixtures.makePhoto(), developer: DebugFixedRecipeDeveloper())
        if developed {
            viewModel.develop()
            await viewModel.developTask?.value
        }
        return viewModel
    }

    private func overlap(developed: Bool, size: DynamicTypeSize) async throws -> CGRect {
        let viewModel = await editor(developed: developed)
        let layout = LayoutProbe(
            EditorView(viewModel: viewModel, onBack: {}),
            size: SnapshotAssertion.defaultSize, dynamicTypeSize: size
        )
        defer { layout.tearDown() }
        let photo = try XCTUnwrap(layout.frame("editor.photo"), "photo not laid out; have \(layout.frames.keys.sorted())")
        let controls = try XCTUnwrap(layout.frame("editor.bottomControls"), "controls not laid out at \(size)")
        return photo.intersection(controls)
    }

    private func assertPhotoUncovered(developed: Bool, size: DynamicTypeSize, file: StaticString = #filePath, line: UInt = #line) async throws {
        let covered = try await overlap(developed: developed, size: size)
        XCTAssertTrue(
            covered.isNull || covered.height < 0.5,
            "\(developed ? "Developed" : "Pre-develop") controls cover \(covered.height) pt of the photo at \(size)",
            file: file, line: line
        )
    }

    func testPreDevelopControlsDoNotCoverThePhotoAtAccessibility3() async throws {
        try await assertPhotoUncovered(developed: false, size: .accessibility3)
    }

    func testDevelopedControlsDoNotCoverThePhotoAtAccessibility3() async throws {
        try await assertPhotoUncovered(developed: true, size: .accessibility3)
    }

    func testDevelopedControlsDoNotCoverThePhotoAtAccessibility5() async throws {
        try await assertPhotoUncovered(developed: true, size: .accessibility5)
    }

    func testPreDevelopControlsDoNotCoverThePhotoAtAccessibility5() async throws {
        try await assertPhotoUncovered(developed: false, size: .accessibility5)
    }

    /// Records (does not assert) the standard-size behaviour, where controls
    /// float over a full-bleed photo by design.
    func testStandardSizeOverlapIsReported() async throws {
        let covered = try await overlap(developed: true, size: .large)
        print("Standard size: developed controls cover \(covered.isNull ? 0 : covered.height) pt of the photo")
    }
}
