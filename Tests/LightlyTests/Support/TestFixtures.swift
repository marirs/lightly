import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Lightly

/// Shared fixtures for the test suite.
enum TestFixtures {

    /// The real catalogue from the app bundle (tests are hosted in the app).
    ///
    /// Loaded once: the resource is several megabytes and every test would
    /// otherwise decode it again. Uses the throwing loader, not `bundled()`,
    /// so a missing resource fails loudly here rather than as empty grids.
    static let bundledCatalog: BuiltInPresetCatalog = {
        do {
            return try BuiltInPresetCatalog.load(from: .main)
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

/// A developer that never finishes, holding the editor in `.developing`.
struct NeverCompletingDeveloper: PhotoDeveloping {
    let implementationKind: DevelopImplementationKind = .debugFixedRecipe
    let performedStages: [DevelopStage] = [.whiteBalance, .exposure, .highlights]

    func develop(
        _ photo: SelectedPhoto,
        onStageCompleted: @escaping @Sendable (DevelopStage) -> Void
    ) async throws -> DevelopRecipe {
        // Suspends until cancelled. Used to snapshot the developing state.
        try await Task.sleep(for: .seconds(3600))
        return .unmodified
    }
}

/// A developer that always fails.
struct FailingDeveloper: PhotoDeveloping {
    let implementationKind: DevelopImplementationKind = .debugFixedRecipe
    let performedStages: [DevelopStage] = [.whiteBalance]

    func develop(
        _ photo: SelectedPhoto,
        onStageCompleted: @escaping @Sendable (DevelopStage) -> Void
    ) async throws -> DevelopRecipe {
        throw LightlyError.developFailed
    }
}

/// A developer claiming production status, used to verify that the debug
/// disclosure is driven by the engine rather than hard-coded.
struct StubProductionDeveloper: PhotoDeveloping {
    let implementationKind: DevelopImplementationKind = .production
    let performedStages: [DevelopStage] = DevelopStage.allCases

    func develop(
        _ photo: SelectedPhoto,
        onStageCompleted: @escaping @Sendable (DevelopStage) -> Void
    ) async throws -> DevelopRecipe {
        performedStages.forEach(onStageCompleted)
        return DebugFixedRecipeDeveloper.fixedRecipe
    }
}
