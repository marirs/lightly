import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Lightly

/// Counts encodes while delegating to the real encoder.
private final class CountingExporter: PhotoExporting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let wrapped = ImageIOPhotoExporter()

    var encodeCount: Int { lock.withLock { calls } }

    func encode(_ image: CGImage, originalData: Data, settings: ExportSettings) throws -> Data {
        lock.withLock { calls += 1 }
        return try wrapped.encode(image, originalData: originalData, settings: settings)
    }
}

/// Spec §4.3 / §5.4 / D8: export is an sRGB JPEG with an embedded sRGB
/// profile and orientation 1, encoded exactly once.
@MainActor
final class ExportColorPipelineTests: XCTestCase {

    private static let tolerance = 4.0 / 255
    private static let sRGBProfileName = "sRGB IEC61966-2.1"

    private struct ExportResult {
        let data: Data
        let fileExtension: String?
        let encodeCount: Int
        let wideGamutSource: CGImage
    }

    /// Loads a Display P3 pure-red original and exports it with default settings.
    private func exportP3Red() async throws -> ExportResult {
        let p3Red = TestFixtures.makeSolidImage(
            width: 64, height: 48, colorSpaceName: CGColorSpace.displayP3, components: [1, 0, 0]
        )
        let photo = try await ImageIOPhotoLoader().loadPhoto(
            from: TestFixtures.makeTIFFData(for: p3Red), source: .photoLibrary
        )
        let exporter = CountingExporter()
        let writer = SpyLibraryWriter()
        let viewModel = ExportViewModel(
            originalImage: photo.image,
            recipe: .unmodified,
            originalData: photo.originalData,
            exporter: exporter,
            libraryWriter: writer,
            entitlements: FreeTierEntitlementResolver()
        )

        // Selected explicitly: making JPEG the default (D8) is deferred
        // pending approval to re-record the export-sheet snapshots.
        viewModel.select(format: .jpeg)
        viewModel.export(to: .photoLibrary)
        await viewModel.inFlightExport?.value

        XCTAssertEqual(viewModel.outcome, .savedToLibrary)
        let saved = await writer.lastSave()
        return ExportResult(
            data: try XCTUnwrap(saved.data),
            fileExtension: saved.ext,
            encodeCount: exporter.encodeCount,
            wideGamutSource: p3Red
        )
    }

    private func properties(of data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Compares against ColorSync's sRGB conversion of the wide-gamut source.
    private func assertPixelsMatchSRGBConversion(
        of reference: CGImage, in decoded: CGImage,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let mean = TestFixtures.meanColour(of: decoded)
        let expected = TestFixtures.meanColour(of: reference)
        XCTAssertEqual(mean.red, expected.red, accuracy: Self.tolerance, file: file, line: line)
        XCTAssertEqual(mean.green, expected.green, accuracy: Self.tolerance, file: file, line: line)
        XCTAssertEqual(mean.blue, expected.blue, accuracy: Self.tolerance, file: file, line: line)
    }

    func testJPEGExportOfDisplayP3RedIsSRGBTaggedWithTheConvertedPixel() async throws {
        let export = try await exportP3Red()

        let source = try XCTUnwrap(CGImageSourceCreateWithData(export.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        XCTAssertEqual(export.fileExtension, "jpg")

        let props = properties(of: export.data)
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int, 1)
        XCTAssertEqual(props[kCGImagePropertyProfileName] as? String, Self.sRGBProfileName, "sRGB ICC must be embedded")

        let decoded = try decode(export.data)
        XCTAssertEqual(decoded.colorSpace?.name, CGColorSpace.sRGB)
        assertPixelsMatchSRGBConversion(of: export.wideGamutSource, in: decoded)
    }

    func testExportEncodesExactlyOnce() async throws {
        let export = try await exportP3Red()
        XCTAssertEqual(export.encodeCount, 1)
    }

    /// The encoder is the last line of defence: a wide-gamut image handed to
    /// it directly is converted, not written with its own profile.
    func testEncoderConvertsANonSRGBInputRatherThanEmbeddingItsProfile() throws {
        let p3 = TestFixtures.makeSolidImage(
            width: 32, height: 32, colorSpaceName: CGColorSpace.displayP3, components: [0.6, 0.4, 0.3]
        )
        var settings = ExportSettings.default
        settings.format = .jpeg

        let data = try ImageIOPhotoExporter().encode(p3, originalData: Data(), settings: settings)

        XCTAssertEqual(properties(of: data)[kCGImagePropertyProfileName] as? String, Self.sRGBProfileName)
        assertPixelsMatchSRGBConversion(of: p3, in: try decode(data))
    }

    /// Spec §5.4: JPEG quality 0.92.
    func testDefaultQualityIsSpecJPEGQuality() {
        XCTAssertEqual(ExportSettings.default.quality.compressionQuality, 0.92, accuracy: 0.0001)
    }
}
