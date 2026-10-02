import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Lightly

/// Records the size of every image it is asked to analyse.
private actor RecordingAnalyser: ImageAnalysing {
    private(set) var analysedSizes: [(width: Int, height: Int)] = []
    private(set) var analysedColorSpaces: [String?] = []

    func analyse(_ image: CGImage) async throws -> ImageAnalysis {
        analysedSizes.append((image.width, image.height))
        analysedColorSpaces.append(image.colorSpace?.name as String?)
        return ImageAnalysis(
            meanLuminance: 0.42, highlightClippingRatio: 0, shadowClippingRatio: 0,
            colorTemperatureOffset: 0, tintOffset: 0, contrastSpread: 0.2, noiseLevel: 0
        )
    }
}

/// Analysis runs on a bounded proxy decode, never on full resolution
/// (spec §12 j: full-resolution analysis cost ≈ 2.2 GB at 48 MP).
final class AnalysisProxyTests: XCTestCase {

    /// A 48 MP (8000×6000) JPEG, produced by Core Image so the test itself
    /// never holds a full-resolution bitmap.
    private static func make48MegapixelJPEG(exifOrientation: Int = 1) throws -> Data {
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: 8000, y: 6000),
            "inputColor0": CIColor(red: 0.1, green: 0.2, blue: 0.4),
            "inputColor1": CIColor(red: 0.9, green: 0.7, blue: 0.3)
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 8000, height: 6000))
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.5
        ]
        let upright = try XCTUnwrap(CIContext().jpegRepresentation(
            of: gradient, colorSpace: ColorPipeline.sRGB, options: options
        ))
        return exifOrientation == 1 ? upright : try retagged(upright, exifOrientation: exifOrientation)
    }

    /// Rewrites only the orientation tag (no re-encode of the pixels).
    private static func retagged(_ jpeg: Data, exifOrientation: Int) throws -> Data {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        )
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueMatchingImageProperty(
            metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, exifOrientation as CFNumber
        )
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true
        ]
        var error: Unmanaged<CFError>?
        XCTAssertTrue(CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error))
        let data = output as Data
        let props = CGImageSourceCopyPropertiesAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil)), 0, nil
        ) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyOrientation] as? Int, exifOrientation, "Precondition: fixture is tagged")
        return data
    }

    /// Stands in for the decoded photo so the test does not allocate the
    /// 192 MB a real 48 MP decode would; the developer must not analyse it.
    private static func photo(withBytes data: Data) -> SelectedPhoto {
        SelectedPhoto(image: TestFixtures.makeImage(width: 300, height: 200), source: .photoLibrary, originalData: data)
    }

    func testAnalyserReceivesAProxyNoLargerThan1024FromA48MegapixelAsset() async throws {
        let analyser = RecordingAnalyser()
        let developer = AnalysingDeveloper(analyser: analyser)

        _ = try await developer.develop(Self.photo(withBytes: try Self.make48MegapixelJPEG())) { _ in }

        let sizes = await analyser.analysedSizes
        XCTAssertEqual(sizes.count, 1)
        XCTAssertEqual(sizes.first?.width, 1024, "Long edge must be the 1024 proxy, not full resolution")
        XCTAssertEqual(sizes.first?.height, 768)
        let spaces = await analyser.analysedColorSpaces
        XCTAssertEqual(spaces.first ?? nil, CGColorSpace.sRGB as String)
    }

    /// The proxy decode applies EXIF orientation (CreateThumbnailWithTransform).
    func testProxyIsUprightForARotatedAsset() throws {
        let proxy = try AnalysisProxy.make(from: Self.photo(withBytes: try Self.make48MegapixelJPEG(exifOrientation: 6)))

        XCTAssertEqual(proxy.width, 768)
        XCTAssertEqual(proxy.height, 1024)
    }

    func testProxyMemoryIsBounded() throws {
        let proxy = try AnalysisProxy.make(from: Self.photo(withBytes: try Self.make48MegapixelJPEG()))

        let proxyBytes = proxy.bytesPerRow * proxy.height
        XCTAssertLessThanOrEqual(proxyBytes, 1024 * 1024 * 4, "Proxy bitmap must stay within a 1024² RGBA budget")
        XCTAssertLessThan(proxyBytes * 50, 8000 * 6000 * 4, "Far below a single full-resolution bitmap")
    }

    /// Photos with no encoded bytes (synthetic or rendered) are downscaled.
    func testPhotoWithoutBytesIsDownscaledToTheBound() throws {
        let photo = SelectedPhoto(
            image: TestFixtures.makeImage(width: 2048, height: 1536), source: .photoLibrary, originalData: Data()
        )
        let proxy = try AnalysisProxy.make(from: photo)

        XCTAssertEqual(proxy.width, 1024)
        XCTAssertEqual(proxy.height, 768)
        XCTAssertEqual(proxy.colorSpace?.name, CGColorSpace.sRGB)
    }

    func testSmallPhotosAreNotUpscaled() throws {
        let photo = SelectedPhoto(
            image: TestFixtures.makeImage(width: 300, height: 400), source: .photoLibrary, originalData: Data()
        )
        let proxy = try AnalysisProxy.make(from: photo)

        XCTAssertEqual(proxy.width, 300)
        XCTAssertEqual(proxy.height, 400)
    }
}
