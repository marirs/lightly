import SwiftUI
import XCTest
@testable import Lightly

private struct BlankThumbnails: LookThumbnailRendering {
    func thumbnail(for preset: LightlyPreset, from source: LookThumbnailSource, maximumDimension: Int) async throws -> CGImage {
        source.image
    }
}

/// Look names must be readable in full at accessibility text sizes.
@MainActor
final class LooksLayoutTests: XCTestCase {

    private func assertVisibleNamesAreNotTruncated(at size: DynamicTypeSize, file: StaticString = #filePath, line: UInt = #line) async throws {
        let viewModel = LooksViewModel(
            thumbnailSource: TestFixtures.makeThumbnailSource(),
            catalog: TestFixtures.bundledCatalog,
            thumbnailRenderer: BlankThumbnails(),
            entitlements: FreeTierEntitlementResolver()
        )
        viewModel.load(category: .recommended)
        await viewModel.inFlightThumbnailWork?.value

        let layout = LayoutProbe(
            LooksView(viewModel: viewModel, onPreviewChanged: { _, _ in }, onApply: { _, _ in }, onClose: {}),
            size: CGSize(width: 402, height: 874), dynamicTypeSize: size
        )
        defer { layout.tearDown() }

        var checked = 0
        for preset in viewModel.presets {
            guard let frame = layout.frame("look.name.\(preset.id)") else { continue }  // not materialised (lazy grid)
            let ideal = LayoutProbe.idealHeight(
                of: LooksView.nameLabel(preset.name, colorScheme: .light), width: frame.width, dynamicTypeSize: size
            )
            XCTAssertGreaterThanOrEqual(
                frame.height, ideal - 0.5,
                "'\(preset.name)' laid out \(frame.height) pt but needs \(ideal) pt at \(size): truncated",
                file: file, line: line
            )
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "No Look names were laid out", file: file, line: line)
    }

    func testNamesAtAccessibility3() async throws { try await assertVisibleNamesAreNotTruncated(at: .accessibility3) }
    func testNamesAtAccessibility5() async throws { try await assertVisibleNamesAreNotTruncated(at: .accessibility5) }
}
