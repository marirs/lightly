import CoreGraphics
import CoreImage
import XCTest
@testable import Lightly

/// Decode must yield upright, 8-bit sRGB pixels regardless of the source's
/// colour space or EXIF orientation (spec §4.1 O0, §4.3).
final class ColorPipelineLoadTests: XCTestCase {

    private let loader = ImageIOPhotoLoader()
    private static let tolerance = 3.0 / 255

    private func load(_ data: Data) async throws -> CGImage {
        try await loader.loadPhoto(from: data, source: .photoLibrary).image
    }

    /// The reference conversion: ColorSync drawing the source into sRGB.
    private func colorSyncMean(of image: CGImage) -> (red: Double, green: Double, blue: Double) {
        TestFixtures.meanColour(of: image)
    }

    private func assertConvertedToSRGB(
        colorSpaceName: CFString, components: [CGFloat],
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let source = TestFixtures.makeSolidImage(colorSpaceName: colorSpaceName, components: components)
        let decoded = try await load(TestFixtures.makeTIFFData(for: source))

        XCTAssertEqual(decoded.colorSpace?.name, CGColorSpace.sRGB, "Decoded image must be tagged sRGB", file: file, line: line)
        XCTAssertEqual(decoded.bitsPerComponent, 8, file: file, line: line)

        // Read back the *stored* bytes as sRGB values. If the image were still
        // P3-tagged, drawing would convert and hide the bug; asserting the tag
        // above makes this read the decoded values directly.
        let decodedMean = TestFixtures.meanColour(of: decoded)
        let expected = colorSyncMean(of: source)
        XCTAssertEqual(decodedMean.red, expected.red, accuracy: Self.tolerance, file: file, line: line)
        XCTAssertEqual(decodedMean.green, expected.green, accuracy: Self.tolerance, file: file, line: line)
        XCTAssertEqual(decodedMean.blue, expected.blue, accuracy: Self.tolerance, file: file, line: line)
    }

    func testDisplayP3PureRedIsConvertedToSRGB() async throws {
        try await assertConvertedToSRGB(colorSpaceName: CGColorSpace.displayP3, components: [1, 0, 0])
    }

    func testInGamutDisplayP3ColourIsConvertedToSRGB() async throws {
        try await assertConvertedToSRGB(colorSpaceName: CGColorSpace.displayP3, components: [0.6, 0.4, 0.3])
    }

    func testAdobeRGBSourceIsConvertedToSRGB() async throws {
        try await assertConvertedToSRGB(colorSpaceName: CGColorSpace.adobeRGB1998, components: [0.2, 0.7, 0.4])
    }

    // MARK: - Orientation

    /// A non-square, four-quadrant image, so any rotation or mirror shows.
    private func makeQuadrants() -> CGImage {
        let width = 40, height = 20
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: ColorPipeline.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fatalError("Cannot create bitmap") }
        let colours: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0)]
        for (index, colour) in colours.enumerated() {
            context.setFillColor(red: colour.0, green: colour.1, blue: colour.2, alpha: 1)
            context.fill(CGRect(x: (index % 2) * 20, y: (index / 2) * 10, width: 20, height: 10))
        }
        return context.makeImage()!
    }

    /// Stores `upright` as a file whose EXIF tag says to apply `orientation`.
    private func storedRotated(_ upright: CGImage, exifOrientation orientation: Int32) -> Data {
        // The stored pixels are the upright image with the *inverse* transform
        // applied; only 6 and 8 are not their own inverses.
        let inverse: Int32 = orientation == 6 ? 8 : (orientation == 8 ? 6 : orientation)
        let oriented = CIImage(cgImage: upright).oriented(forExifOrientation: inverse)
        let context = CIContext()
        let stored = context.createCGImage(
            oriented, from: oriented.extent, format: .RGBA8, colorSpace: ColorPipeline.sRGB
        )!
        return TestFixtures.makeTIFFData(for: stored, exifOrientation: Int(orientation))
    }

    func testUprightAndEXIFRotatedSourcesDecodeToIdenticalPixels() async throws {
        let upright = makeQuadrants()
        let reference = try await load(TestFixtures.makeTIFFData(for: upright))

        for orientation: Int32 in [3, 6, 8, 2, 5] {
            let decoded = try await load(storedRotated(upright, exifOrientation: orientation))
            XCTAssertEqual(decoded.width, reference.width, "orientation \(orientation)")
            XCTAssertEqual(decoded.height, reference.height, "orientation \(orientation)")
            XCTAssertEqual(
                TestFixtures.rgbaBytes(of: decoded), TestFixtures.rgbaBytes(of: reference),
                "EXIF orientation \(orientation) decoded to different pixels"
            )
            XCTAssertEqual(decoded.colorSpace?.name, CGColorSpace.sRGB)
        }
    }

    // MARK: - Policy

    /// Spec §4.3: Device RGB is banned in the app. Scans the app sources on
    /// the host (simulator tests run against the checkout via #filePath).
    func testAppSourcesNeverUseDeviceRGB() throws {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LightlyTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Lightly")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil))

        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("CGColorSpaceCreateDeviceRGB") || text.contains("genericRGBLinear") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertGreaterThan(scanned, 20, "Expected to scan the app sources")
        XCTAssertEqual(offenders, [], "Device/generic RGB used in app code")
    }
}
