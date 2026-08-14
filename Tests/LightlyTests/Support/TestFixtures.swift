import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Lightly

/// Shared fixtures for the test suite.
enum TestFixtures {

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
