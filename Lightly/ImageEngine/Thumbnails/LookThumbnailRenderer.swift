import CoreGraphics
import CoreImage
import Foundation

/// Renders Look preview thumbnails from the user's own photograph (spec §7).
///
/// Thumbnails are rendered at reduced resolution; full resolution is produced
/// only when a Look is confirmed or exported. Rendering nine full-size variants
/// to fill a grid would stall the interface and burn battery for pixels nobody
/// sees at 100pt square.
protocol LookThumbnailRendering: Sendable {
    /// Produces a preview of `preset` applied to `image`.
    ///
    /// - Throws: `LightlyError.developFailed` if the preview cannot be rendered.
    func thumbnail(
        for preset: LightlyPreset,
        from image: CGImage,
        maximumDimension: Int
    ) async throws -> CGImage
}

/// Core Image implementation.
///
/// Downsamples once per source image and caches the result, so a grid of Looks
/// costs one downsample plus one cheap filter pass each rather than N
/// downsamples of a full-resolution photograph.
actor CoreImageThumbnailRenderer: LookThumbnailRendering {

    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let renderer = RecipeRenderer()

    /// Cached downsampled base, keyed by source identity and target size.
    private var downsampledBase: (sourceWidth: Int, dimension: Int, image: CGImage)?

    func thumbnail(
        for preset: LightlyPreset,
        from image: CGImage,
        maximumDimension: Int
    ) async throws -> CGImage {
        let base = try downsample(image, to: maximumDimension)
        return try renderer.render(base, with: preset.recipe)
    }

    /// Produces a reduced-resolution copy, preserving aspect ratio.
    ///
    /// Returns the source untouched when it is already small enough, avoiding a
    /// pointless re-encode.
    private func downsample(_ image: CGImage, to maximumDimension: Int) throws -> CGImage {
        if let cached = downsampledBase,
           cached.sourceWidth == image.width,
           cached.dimension == maximumDimension {
            return cached.image
        }

        let longestSide = max(image.width, image.height)
        guard longestSide > maximumDimension else {
            downsampledBase = (image.width, maximumDimension, image)
            return image
        }

        let scale = Double(maximumDimension) / Double(longestSide)
        let scaled = CIImage(cgImage: image).transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )

        guard let output = context.createCGImage(scaled, from: scaled.extent) else {
            throw LightlyError.developFailed
        }

        downsampledBase = (image.width, maximumDimension, output)
        return output
    }
}
