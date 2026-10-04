import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Lightly

/// Shared fixtures for the test suite.
enum TestFixtures {

    /// The legacy preset catalogue (`presets_photo.json`), read from the repository: it is no longer
    /// in the app bundle (its recipes came from third-party packs; the app ships the format-3 Look
    /// pack). Only the legacy catalogue's own tests read it.
    ///
    /// Loaded once: the resource is several megabytes and every test would
    /// otherwise decode it again. Uses the throwing loader, not `bundled()`,
    /// so a missing resource fails loudly here rather than as empty grids.
    static var legacyPresetsBundle: Bundle {
        Bundle(path: DevelopParityTests.fixture("ios/Lightly/Resources/Presets").path)!
    }

    static let bundledCatalog: BuiltInPresetCatalog = {
        do {
            return try BuiltInPresetCatalog.load(from: legacyPresetsBundle)
        } catch {
            fatalError("App bundle has no usable preset catalogue: \(error)")
        }
    }()

    /// A deterministic gradient image.
    ///
    /// Snapshots need a stable, non-trivial photograph: a flat colour would
    /// hide rendering differences, and a real asset would make references
    /// depend on a binary in the repository.
    static func makeImage(width: Int = 300, height: Int = 400) -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Test environment cannot create a bitmap context")
        }

        for row in 0..<height {
            let verticalPosition = Double(row) / Double(height)
            context.setFillColor(
                red: 0.20 + verticalPosition * 0.55,
                green: 0.30 + verticalPosition * 0.35,
                blue: 0.45 + verticalPosition * 0.20,
                alpha: 1
            )
            context.fill(CGRect(x: 0, y: row, width: width, height: 1))
        }

        guard let image = context.makeImage() else {
            fatalError("Test environment cannot render a bitmap")
        }
        return image
    }

    /// The gradient fixture as a Look thumbnail source on the Original.
    static func makeThumbnailSource() -> LookThumbnailSource {
        LookThumbnailSource(photo: makePhoto(), editBase: .unmodified)
    }

    /// A single-colour image, for tests that tell photos apart by pixels.
    static func makeSolidImage(
        width: Int = 300, height: Int = 400,
        red: Double, green: Double, blue: Double
    ) -> CGImage {
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Test environment cannot create a bitmap context")
        }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            fatalError("Test environment cannot render a bitmap")
        }
        return image
    }

    /// JPEG bytes for an arbitrary image.
    static func makeJPEGData(for image: CGImage) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A single-colour image in an arbitrary named colour space.
    static func makeSolidImage(
        width: Int = 16, height: Int = 16,
        colorSpaceName: CFString,
        components: [CGFloat]
    ) -> CGImage {
        guard let space = CGColorSpace(name: colorSpaceName),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let colour = CGColor(colorSpace: space, components: components + [1]) else {
            fatalError("Test environment cannot create a \(colorSpaceName) bitmap")
        }
        context.setFillColor(colour)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { fatalError("Cannot render bitmap") }
        return image
    }

    /// Encodes `image` losslessly (TIFF), optionally tagging an EXIF orientation.
    static func makeTIFFData(for image: CGImage, exifOrientation: Int = 1) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.tiff.identifier as CFString, 1, nil
        ) else { fatalError("Cannot create TIFF destination") }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImagePropertyOrientation: exifOrientation] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { fatalError("Cannot encode TIFF") }
        return data as Data
    }

    /// Raw 8-bit RGBA bytes of `image`, drawn into sRGB.
    static func rgbaBytes(of image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    /// Mean RGB of an image in 0...1, measured in sRGB.
    ///
    /// Lets tests assert on what was rendered rather than on dimensions or
    /// non-nil results.
    static func meanColour(of image: CGImage) -> (red: Double, green: Double, blue: Double) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { fatalError("Test environment cannot read back pixels") }

        var sums = (0.0, 0.0, 0.0)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            sums.0 += Double(pixels[index])
            sums.1 += Double(pixels[index + 1])
            sums.2 += Double(pixels[index + 2])
        }
        let count = Double(width * height) * 255
        return (sums.0 / count, sums.1 / count, sums.2 / count)
    }

    static func makePhoto(source: PhotoSource = .photoLibrary) -> SelectedPhoto {
        // Non-empty bytes so tests exercise the real metadata path rather than
        // the empty-source shortcut.
        SelectedPhoto(
            image: makeImage(),
            source: source,
            originalData: makeJPEGData()
        )
    }

    /// Encoded JPEG bytes for a fixture photograph.
    static func makeJPEGData() -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, makeImage(), nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
