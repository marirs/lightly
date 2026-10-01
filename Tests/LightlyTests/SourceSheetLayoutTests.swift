import SwiftUI
import XCTest
@testable import Lightly

/// The source-selection sheet keeps each row's text inside its own row, and
/// the rows apart, at every Dynamic Type size.
@MainActor
final class SourceSheetLayoutTests: XCTestCase {

    /// The size the accessibility snapshot uses.
    private let sheetSize = CGSize(width: 402, height: 360)

    private func assertRowsAreSelfContained(at size: DynamicTypeSize, file: StaticString = #filePath, line: UInt = #line) throws {
        let layout = LayoutProbe(
            SourceSelectionSheet().environment(AppState(photoLoader: ImageIOPhotoLoader())),
            size: sheetSize, dynamicTypeSize: size
        )
        defer { layout.tearDown() }
        func frame(_ name: String) throws -> CGRect {
            try XCTUnwrap(layout.frame(name), "\(name) missing at \(size); have \(layout.frames.keys.sorted())", file: file, line: line)
        }

        let camera = try frame("source.camera.row"), library = try frame("source.photoLibrary.row")
        XCTAssertFalse(camera.intersects(library), "Camera row \(camera) overlaps Library row \(library) at \(size)", file: file, line: line)

        for source in ["camera", "photoLibrary"] {
            let row = try frame("source.\(source).row")
            for part in ["title", "subtitle"] {
                let text = try frame("source.\(source).\(part)")
                XCTAssertTrue(
                    row.insetBy(dx: -0.5, dy: -0.5).contains(text),
                    "\(source) \(part) \(text) spills out of its row \(row) at \(size)",
                    file: file, line: line
                )
            }
        }
    }

    func testRowsAtDefaultSize() throws { try assertRowsAreSelfContained(at: .large) }

    /// At standard sizes both rows fit the 280 pt detent without scrolling.
    func testBothRowsFitTheStandardDetent() throws {
        let layout = LayoutProbe(
            SourceSelectionSheet().environment(AppState(photoLoader: ImageIOPhotoLoader())),
            size: CGSize(width: 402, height: 280), dynamicTypeSize: .large
        )
        defer { layout.tearDown() }
        let library = try XCTUnwrap(layout.frame("source.photoLibrary.row"))
        XCTAssertLessThanOrEqual(library.maxY, 280)
        XCTAssertEqual(SourceSelectionSheet.detents(for: .large), [.height(280)])
        XCTAssertEqual(SourceSelectionSheet.detents(for: .accessibility3), [.large])
    }
    func testRowsAtAccessibility3() throws { try assertRowsAreSelfContained(at: .accessibility3) }
    func testRowsAtAccessibility5() throws { try assertRowsAreSelfContained(at: .accessibility5) }
}
