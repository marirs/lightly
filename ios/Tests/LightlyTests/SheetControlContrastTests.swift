import SwiftUI
import XCTest
@testable import Lightly

private struct InertWriter: PhotoLibraryWriting {
    func save(_ data: Data, fileExtension: String) async throws {}
}

/// WCAG 1.4.11 for the export and source sheets: Save, Share and the source
/// rows must show a boundary ≥ 3:1 against the sheet, at the default size
/// and at AX3, in light and dark; their labels ≥ 4.5:1 (WCAG 1.4.3).
@MainActor
final class SheetControlContrastTests: XCTestCase {

    /// Full height, so the actions are on screen even at AX3 (where they
    /// flow after the options inside the scroll view).
    private let size = SnapshotAssertion.defaultSize

    private func exportSheet() -> some View {
        ExportSheet(
            viewModel: ExportViewModel(
                originalImage: TestFixtures.makeImage(), recipe: .unmodified, originalData: Data(),
                exporter: ImageIOPhotoExporter(), libraryWriter: InertWriter(),
                entitlements: FreeTierEntitlementResolver()
            ),
            onClose: {}
        )
    }

    private func sourceSheet() -> some View {
        SourceSelectionSheet().environment(AppState(photoLoader: ImageIOPhotoLoader()))
    }

    private func assertBoundaries(
        _ view: some View, anchors: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for scheme in [ColorScheme.light, .dark] {
            for typeSize in [DynamicTypeSize.large, .accessibility3] {
                let sized = view.environment(\.dynamicTypeSize, typeSize)
                let rendered = try XCTUnwrap(SnapshotAssertion.renderWithAnchors(sized, size: size, colorScheme: scheme))
                let pixels = try MetalLUTRenderer.rgba8Bytes(of: rendered.image)
                for anchor in anchors {
                    let frame = try XCTUnwrap(rendered.anchors[anchor], "\(anchor) missing at \(typeSize)", file: file, line: line)
                    let measured = WCAG.edgeContrast(of: frame, in: pixels, width: rendered.image.width)
                    print("contrast \(anchor) \(scheme) \(typeSize): \(String(format: "%.2f", measured.ratio)):1")
                    XCTAssertGreaterThanOrEqual(
                        measured.ratio, 3.0,
                        "\(anchor) boundary \(String(format: "%.2f", measured.ratio)):1 against \(measured.outside) in \(scheme) at \(typeSize)",
                        file: file, line: line
                    )
                }
            }
        }
    }

    func testExportActionBoundaries() throws {
        try assertBoundaries(exportSheet(), anchors: ["export.save", "export.share"])
    }

    func testSourceRowBoundaries() throws {
        try assertBoundaries(sourceSheet(), anchors: ["source.camera.row", "source.photoLibrary.row"])
    }

    /// Text on these controls: primary on the elevated fill (Save, rows),
    /// primary on the sheet (Share), secondary on the elevated fill (row
    /// subtitles).
    func testLabelContrast() {
        for scheme in [ColorScheme.light, .dark] {
            let pairs: [(String, Color, Color)] = [
                ("primary/elevated", LightlyColor.textPrimary(scheme), LightlyColor.surfaceElevated(scheme)),
                ("primary/surface", LightlyColor.textPrimary(scheme), LightlyColor.surface(scheme)),
                ("secondary/elevated", LightlyColor.textSecondary(scheme), LightlyColor.surfaceElevated(scheme))
            ]
            for (name, text, fill) in pairs {
                let ratio = WCAG.contrast(WCAG.luminance(of: text), WCAG.luminance(of: fill))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) \(scheme): \(ratio):1")
            }
        }
    }
}
