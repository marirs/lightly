import SwiftUI
import XCTest
@testable import Lightly

/// The launch screen's only instruction must be readable in full at every
/// Dynamic Type size.
@MainActor
final class LaunchLayoutTests: XCTestCase {

    private func assertSwipePromptIsNotTruncated(at size: DynamicTypeSize, file: StaticString = #filePath, line: UInt = #line) throws {
        let layout = LayoutProbe(
            LaunchView().environment(AppState(photoLoader: ImageIOPhotoLoader())),
            size: SnapshotAssertion.defaultSize, dynamicTypeSize: size
        )
        defer { layout.tearDown() }

        let prompt = try XCTUnwrap(layout.frame("launch.swipePrompt"), file: file, line: line)
        let ideal = LayoutProbe.idealHeight(of: LaunchView.swipePrompt(.light), width: prompt.width, dynamicTypeSize: size)
        XCTAssertGreaterThanOrEqual(
            prompt.height, ideal - 0.5,
            "Swipe prompt laid out \(prompt.height) pt tall but needs \(ideal) pt at \(size): truncated",
            file: file, line: line
        )
        XCTAssertLessThanOrEqual(prompt.maxY, SnapshotAssertion.defaultSize.height, "Prompt off-screen at \(size)", file: file, line: line)
    }

    func testPromptAtDefaultSize() throws { try assertSwipePromptIsNotTruncated(at: .large) }
    func testPromptAtAccessibility3() throws { try assertSwipePromptIsNotTruncated(at: .accessibility3) }
    func testPromptAtAccessibility5() throws { try assertSwipePromptIsNotTruncated(at: .accessibility5) }
}
