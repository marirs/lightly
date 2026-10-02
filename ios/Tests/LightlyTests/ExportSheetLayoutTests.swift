import SwiftUI
import XCTest
@testable import Lightly

private struct InertLibraryWriter: PhotoLibraryWriting {
    func save(_ data: Data, fileExtension: String) async throws {}
}

/// Geometry of the export sheet across Dynamic Type sizes: every section is
/// laid out and nothing sits under the actions (spec §20 accessibility).
@MainActor
final class ExportSheetLayoutTests: XCTestCase {

    /// The size the export snapshots use: a sheet at roughly its medium detent.
    private let sheetSize = CGSize(width: 402, height: 560)

    private let contentAnchors = ["export.metadataHeader", "export.preserveMetadata", "export.preserveLocation"]
    private let actionAnchors = ["export.save", "export.share"]

    private func probe(_ size: DynamicTypeSize) -> LayoutProbe {
        let viewModel = ExportViewModel(
            originalImage: TestFixtures.makeImage(),
            recipe: .unmodified,
            originalData: Data(),
            exporter: ImageIOPhotoExporter(),
            libraryWriter: InertLibraryWriter(),
            entitlements: FreeTierEntitlementResolver()
        )
        return LayoutProbe(ExportSheet(viewModel: viewModel, onClose: {}), size: sheetSize, dynamicTypeSize: size)
    }

    private func assertNoOverlapWithActions(at size: DynamicTypeSize, file: StaticString = #filePath, line: UInt = #line) throws {
        let layout = probe(size)
        defer { layout.tearDown() }

        func frame(_ name: String) throws -> CGRect {
            try XCTUnwrap(layout.frame(name), "\(name) not laid out at \(size); have \(layout.frames.keys.sorted())", file: file, line: line)
        }
        for content in contentAnchors {
            for action in actionAnchors {
                let contentFrame = try frame(content), actionFrame = try frame(action)
                XCTAssertFalse(
                    contentFrame.intersects(actionFrame),
                    "\(content) \(contentFrame) overlaps \(action) \(actionFrame) at \(size)",
                    file: file, line: line
                )
            }
        }
        XCTAssertFalse(try frame("export.save").intersects(try frame("export.share")), "Save overlaps Share at \(size)", file: file, line: line)
        XCTAssertGreaterThan(try frame("export.share").height, 0, file: file, line: line)
        // Actions come after every option, never beside or under them, so
        // scrolling the sheet reaches each control in reading order.
        XCTAssertGreaterThanOrEqual(
            try frame("export.save").minY, try frame("export.preserveLocation").maxY,
            "Save must follow the last option at \(size)", file: file, line: line
        )
    }

    func testNothingOverlapsTheActionsAtDefaultSize() throws {
        try assertNoOverlapWithActions(at: .large)
    }

    func testNothingOverlapsTheActionsAtAccessibility3() throws {
        try assertNoOverlapWithActions(at: .accessibility3)
    }

    func testNothingOverlapsTheActionsAtAccessibility5() throws {
        try assertNoOverlapWithActions(at: .accessibility5)
    }
}
