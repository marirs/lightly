import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Lightly

/// The two independent Preferences switches, "Keep photo metadata" (default on) and "Include
/// location" (default off), checked on the bytes of written JPEGs in all four combinations.
///
/// Whatever the switches say, every file keeps its colour profile, declares orientation 1,
/// describes its own pixel size and carries no embedded thumbnail.
final class ExportMetadataPolicyTests: XCTestCase {

    /// A camera original: rotated (orientation 6), 4032×3024 in its EXIF, with an embedded
    /// thumbnail, private fields that must never travel, IPTC place names and GPS.
    static func makeCameraOriginal() throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImageDestinationEmbedThumbnail: true,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifFNumber: 1.8,
                kCGImagePropertyExifExposureTime: 1.0 / 120.0,
                kCGImagePropertyExifISOSpeedRatings: [200],
                kCGImagePropertyExifDateTimeOriginal: "2024:01:15 09:41:00",
                kCGImagePropertyExifOffsetTimeOriginal: "+04:00",
                kCGImagePropertyExifLensMake: "Apple",
                kCGImagePropertyExifLensModel: "iPhone 17 back camera 5.96mm f/1.8",
                kCGImagePropertyExifFocalLength: 5.96,
                kCGImagePropertyExifPixelXDimension: 4032,
                kCGImagePropertyExifPixelYDimension: 3024,
                kCGImagePropertyExifUserComment: "private note",
                kCGImagePropertyExifBodySerialNumber: "SERIAL-123"
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Apple",
                kCGImagePropertyTIFFModel: "iPhone 17",
                kCGImagePropertyTIFFOrientation: 6,
                kCGImagePropertyTIFFSoftware: "26.5"
            ],
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCity: "Dubai"
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 25.2,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 55.27,
                kCGImagePropertyGPSLongitudeRef: "E"
            ]
        ]
        CGImageDestinationAddImage(destination, TestFixtures.makeImage(width: 160, height: 120), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        // The fixture itself must have what the policy is expected to remove.
        XCTAssertTrue(hasEmbeddedJPEGThumbnail(data as Data), "Fixture should embed a thumbnail")
        return data as Data
    }

    /// Everything a check needs to know about one written file.
    struct WrittenFile {
        let properties: [CFString: Any]
        let pixelWidth: Int
        let pixelHeight: Int
        let hasEmbeddedThumbnail: Bool
        let typeIdentifier: String?

        var exif: [CFString: Any] { properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:] }
        var tiff: [CFString: Any] { properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:] }
        var gps: [CFString: Any]? { properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] }

        init(_ data: Data) throws {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            typeIdentifier = CGImageSourceGetType(source) as String?
            properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            pixelWidth = image.width
            pixelHeight = image.height
            hasEmbeddedThumbnail = ExportMetadataPolicyTests.hasEmbeddedJPEGThumbnail(data)
        }
    }

    /// An EXIF thumbnail is a second JPEG inside the APP1 segment, so the file holds a second
    /// start-of-image marker (FF D8 FF). ImageIO's thumbnail API cannot tell: it returns a
    /// downscaled main image when there is none.
    static func hasEmbeddedJPEGThumbnail(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var startOfImageMarkers = 0
        for index in 0..<max(0, bytes.count - 2) where bytes[index] == 0xFF && bytes[index + 1] == 0xD8 && bytes[index + 2] == 0xFF {
            startOfImageMarkers += 1
        }
        return startOfImageMarkers > 1
    }

    /// Checks one combination of the two switches on a written file.
    static func assertPolicy(
        _ policy: ExportMetadataPolicy, on file: WrittenFile, width: Int, height: Int,
        file sourceFile: StaticString = #filePath, line: UInt = #line
    ) {
        let label = "keep=\(policy.keepsCaptureMetadata) location=\(policy.includesLocation)"

        // Always, whatever the switches.
        XCTAssertEqual(file.typeIdentifier, UTType.jpeg.identifier, label, file: sourceFile, line: line)
        XCTAssertEqual(file.properties[kCGImagePropertyProfileName] as? String, "sRGB IEC61966-2.1",
                       "Colour profile must always be kept (\(label))", file: sourceFile, line: line)
        XCTAssertEqual(file.pixelWidth, width, label, file: sourceFile, line: line)
        XCTAssertEqual(file.pixelHeight, height, label, file: sourceFile, line: line)
        XCTAssertEqual(file.properties[kCGImagePropertyPixelWidth] as? Int, width, label, file: sourceFile, line: line)
        XCTAssertEqual(file.properties[kCGImagePropertyPixelHeight] as? Int, height, label, file: sourceFile, line: line)
        XCTAssertEqual(file.properties[kCGImagePropertyOrientation] as? Int ?? 1, 1,
                       "Upright pixels declare orientation 1 (\(label))", file: sourceFile, line: line)
        if let tiffOrientation = file.tiff[kCGImagePropertyTIFFOrientation] as? Int {
            XCTAssertEqual(tiffOrientation, 1, label, file: sourceFile, line: line)
        }
        // Stale dimensions: absent, or the new image's own.
        if let x = file.exif[kCGImagePropertyExifPixelXDimension] as? Int {
            XCTAssertEqual(x, width, "Stale EXIF width (\(label))", file: sourceFile, line: line)
        }
        if let y = file.exif[kCGImagePropertyExifPixelYDimension] as? Int {
            XCTAssertEqual(y, height, "Stale EXIF height (\(label))", file: sourceFile, line: line)
        }
        XCTAssertFalse(file.hasEmbeddedThumbnail, "No thumbnail (\(label))", file: sourceFile, line: line)
        // Never copied under any policy.
        XCTAssertNil(file.exif[kCGImagePropertyExifUserComment], label, file: sourceFile, line: line)
        XCTAssertNil(file.exif[kCGImagePropertyExifBodySerialNumber], label, file: sourceFile, line: line)
        XCTAssertNil(file.tiff[kCGImagePropertyTIFFSoftware], label, file: sourceFile, line: line)
        XCTAssertNil(file.properties[kCGImagePropertyIPTCDictionary], "IPTC place names never travel (\(label))", file: sourceFile, line: line)

        // Keep photo metadata.
        let exif = file.exif, tiff = file.tiff
        if policy.keepsCaptureMetadata {
            XCTAssertEqual(exif[kCGImagePropertyExifFNumber] as? Double, 1.8, label, file: sourceFile, line: line)
            XCTAssertEqual(exif[kCGImagePropertyExifExposureTime] as? Double ?? 0, 1.0 / 120.0, accuracy: 1e-6, label, file: sourceFile, line: line)
            XCTAssertEqual(exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], [200], label, file: sourceFile, line: line)
            XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2024:01:15 09:41:00", label, file: sourceFile, line: line)
            XCTAssertEqual(exif[kCGImagePropertyExifLensModel] as? String, "iPhone 17 back camera 5.96mm f/1.8", label, file: sourceFile, line: line)
            XCTAssertEqual(exif[kCGImagePropertyExifLensMake] as? String, "Apple", label, file: sourceFile, line: line)
            XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "Apple", label, file: sourceFile, line: line)
            XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "iPhone 17", label, file: sourceFile, line: line)
        } else {
            for key in ExportMetadataComposer.keptExifKeys {
                XCTAssertNil(exif[key as CFString], "\(key) kept although Keep photo metadata is off", file: sourceFile, line: line)
            }
            XCTAssertNil(tiff[kCGImagePropertyTIFFMake], label, file: sourceFile, line: line)
            XCTAssertNil(tiff[kCGImagePropertyTIFFModel], label, file: sourceFile, line: line)
        }

        // Include location: independent of the switch above.
        if policy.includesLocation {
            let gps = file.gps
            XCTAssertNotNil(gps, "GPS missing although Include location is on (\(label))", file: sourceFile, line: line)
            XCTAssertEqual(gps?[kCGImagePropertyGPSLatitude] as? Double ?? 0, 25.2, accuracy: 1e-4, label, file: sourceFile, line: line)
            XCTAssertEqual(gps?[kCGImagePropertyGPSLongitude] as? Double ?? 0, 55.27, accuracy: 1e-4, label, file: sourceFile, line: line)
        } else {
            XCTAssertNil(file.gps, "GPS leaked although Include location is off (\(label))", file: sourceFile, line: line)
        }
    }

    static let allCombinations: [ExportMetadataPolicy] = [
        ExportMetadataPolicy(keepsCaptureMetadata: true, includesLocation: false),
        ExportMetadataPolicy(keepsCaptureMetadata: true, includesLocation: true),
        ExportMetadataPolicy(keepsCaptureMetadata: false, includesLocation: true),
        ExportMetadataPolicy(keepsCaptureMetadata: false, includesLocation: false)
    ]

    // MARK: - Encoder

    func testEncoderAppliesEveryCombination() throws {
        let original = try Self.makeCameraOriginal()
        let rendered = TestFixtures.makeImage(width: 90, height: 120)
        for policy in Self.allCombinations {
            let data = try ImageIOPhotoExporter().encode(rendered, originalData: original, settings: .saveCopy(metadata: policy))
            Self.assertPolicy(policy, on: try WrittenFile(data), width: 90, height: 120)
        }
    }

    func testDefaultsAreKeepMetadataOnAndLocationOff() {
        XCTAssertEqual(ExportMetadataPolicy.default, ExportMetadataPolicy(keepsCaptureMetadata: true, includesLocation: false))
        XCTAssertEqual(ExportSettings.default.metadataPolicy, .default)
    }

    func testAnOriginalWithoutMetadataStillSavesWithItsProfile() throws {
        let data = try ImageIOPhotoExporter().encode(
            TestFixtures.makeImage(width: 40, height: 30), originalData: Data(),
            settings: .saveCopy(metadata: ExportMetadataPolicy(keepsCaptureMetadata: true, includesLocation: true))
        )
        let file = try WrittenFile(data)
        XCTAssertNil(file.gps)
        XCTAssertEqual(file.properties[kCGImagePropertyProfileName] as? String, "sRGB IEC61966-2.1")
        XCTAssertFalse(file.hasEmbeddedThumbnail)
    }
}
