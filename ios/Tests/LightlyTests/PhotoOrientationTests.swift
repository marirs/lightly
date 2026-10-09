import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import UIKit
@testable import Lightly

/// Verifies EXIF orientation handling against real encoded data.
///
/// Asserting `normalisesOrientation == true` would prove nothing on its own, so
/// these tests build genuine JPEG data carrying an orientation tag and check the
/// decoded pixels actually come back upright.
final class PhotoOrientationTests: XCTestCase {

    /// Encodes an image to JPEG with a specific EXIF orientation tag.
    private func makeJPEG(_ image: CGImage, exifOrientation: Int) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw XCTSkip("Cannot create a JPEG destination in this environment")
        }

        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: exifOrientation
        ] as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("Cannot finalise JPEG in this environment")
        }
        return data as Data
    }

    /// A deliberately non-square source, so a 90° rotation is detectable purely
    /// from the resulting dimensions.
    private func makeWideImage() -> CGImage {
        TestFixtures.makeImage(width: 200, height: 100)
    }

    // MARK: - Orientation 1 (upright)

    func testUprightImageIsUnchanged() async throws {
        let source = makeWideImage()
        let data = try makeJPEG(source, exifOrientation: 1)

        let photo = try await ImageIOPhotoLoader().loadPhoto(from: data, source: .photoLibrary)

        XCTAssertEqual(photo.image.width, 200)
        XCTAssertEqual(photo.image.height, 100)
    }

    // MARK: - Orientation 3 (180°, "upside down")

    /// The reported symptom: a photograph displaying upside down.
    func testUpsideDownImageIsRotatedUpright() async throws {
        let source = makeWideImage()
        let data = try makeJPEG(source, exifOrientation: 3)

        let photo = try await ImageIOPhotoLoader().loadPhoto(from: data, source: .photoLibrary)

        // A 180° rotation preserves dimensions, so compare pixels: the top-left
        // of an upside-down image must become the bottom-right once corrected.
        XCTAssertEqual(photo.image.width, 200)
        XCTAssertEqual(photo.image.height, 100)

        let originalTopLeft = try pixel(in: source, x: 4, y: 4)
        let correctedBottomRight = try pixel(in: photo.image, x: 195, y: 95)

        XCTAssertEqual(
            originalTopLeft.red, correctedBottomRight.red, accuracy: 0.06,
            "A 180° orientation tag was not applied."
        )
        XCTAssertEqual(
            originalTopLeft.blue, correctedBottomRight.blue, accuracy: 0.06,
            "A 180° orientation tag was not applied."
        )
    }

    // MARK: - Orientations 6 and 8 (90° rotations)

    func testNinetyDegreeRotationSwapsDimensions() async throws {
        for orientation in [6, 8] {
            let data = try makeJPEG(makeWideImage(), exifOrientation: orientation)

            let photo = try await ImageIOPhotoLoader()
                .loadPhoto(from: data, source: .photoLibrary)

            XCTAssertEqual(
                photo.image.width, 100,
                "Orientation \(orientation) should produce a portrait image."
            )
            XCTAssertEqual(
                photo.image.height, 200,
                "Orientation \(orientation) should produce a portrait image."
            )
        }
    }

    /// `pixelSize` is derived at construction, so it must reflect the corrected
    /// geometry rather than the stored one.
    func testPixelSizeReflectsCorrectedOrientation() async throws {
        let data = try makeJPEG(makeWideImage(), exifOrientation: 6)

        let photo = try await ImageIOPhotoLoader().loadPhoto(from: data, source: .photoLibrary)

        XCTAssertEqual(photo.pixelSize.width, 100)
        XCTAssertEqual(photo.pixelSize.height, 200)
    }

    // MARK: - Missing tag

    /// Screenshots and rendered images often carry no orientation tag; that is
    /// normal and must not be treated as a failure.
    func testImageWithoutOrientationTagLoads() async throws {
        let source = makeWideImage()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw XCTSkip("Cannot create a JPEG destination in this environment")
        }
        CGImageDestinationAddImage(destination, source, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let photo = try await ImageIOPhotoLoader()
            .loadPhoto(from: data as Data, source: .photoLibrary)

        XCTAssertEqual(photo.image.width, 200)
        XCTAssertEqual(photo.image.height, 100)
    }

    /// Exercise both capture encoders and the real loader with asymmetric pixels,
    /// including rotated sensor orientations: only the visible left/right changes.
    @MainActor
    func testFrontCameraMatchesMirroredPreviewAfterEncoding() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 64), format: format).image { _ in
            UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 48, height: 32))
            UIColor.green.setFill(); UIRectFill(CGRect(x: 48, y: 0, width: 48, height: 32))
            UIColor.blue.setFill(); UIRectFill(CGRect(x: 0, y: 32, width: 48, height: 32))
            UIColor.yellow.setFill(); UIRectFill(CGRect(x: 48, y: 32, width: 48, height: 32))
        }
        for orientation: UIImage.Orientation in [.up, .down, .left, .right, .upMirrored, .downMirrored, .leftMirrored, .rightMirrored] {
            let original = UIImage(cgImage: try XCTUnwrap(source.cgImage), scale: 1, orientation: orientation)
            let front = CameraCaptureView.imageMatchingPreview(original, camera: .front)
            let rear = CameraCaptureView.imageMatchingPreview(original, camera: .rear)
            XCTAssertTrue(rear === original, "Rear camera must remain unchanged")
            for heic in [false, true] {
                let rearData = try XCTUnwrap(heic ? rear.heicData() : rear.jpegData(compressionQuality: 1))
                let frontData = try XCTUnwrap(heic ? front.heicData() : front.jpegData(compressionQuality: 1))
                let loader = ImageIOPhotoLoader()
                let before = try await loader.loadPhoto(from: rearData, source: .camera)
                let after = try await loader.loadPhoto(from: frontData, source: .camera)
                XCTAssertEqual(before.image.width, after.image.width)
                XCTAssertEqual(before.image.height, after.image.height)
                for x in [before.image.width / 4, before.image.width * 3 / 4] {
                    for y in [before.image.height / 4, before.image.height * 3 / 4] {
                        let expected = try pixel(in: before.image, x: x, y: y)
                        let actual = try pixel(in: after.image, x: after.image.width - 1 - x, y: y)
                        XCTAssertEqual(expected.red, actual.red, accuracy: 0.04, "orientation \(orientation), HEIC \(heic)")
                        XCTAssertEqual(expected.green, actual.green, accuracy: 0.04)
                        XCTAssertEqual(expected.blue, actual.blue, accuracy: 0.04)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private struct Pixel {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// Samples a single pixel, normalised to 0...1.
    private func pixel(in image: CGImage, x: Int, y: Int) throws -> Pixel {
        var bytes = [UInt8](repeating: 0, count: 4)

        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Cannot create a sampling context")
        }

        // Translate so the requested pixel lands in the 1×1 context.
        context.translateBy(x: CGFloat(-x), y: CGFloat(-y))
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )

        return Pixel(
            red: Double(bytes[0]) / 255,
            green: Double(bytes[1]) / 255,
            blue: Double(bytes[2]) / 255
        )
    }
}
