import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes a rendered photograph for output.
protocol PhotoExporting: Sendable {
    /// Encodes `image`, carrying metadata across from `originalData` as the
    /// settings allow.
    ///
    /// - Parameters:
    ///   - image: The rendered photograph.
    ///   - originalData: Source bytes for metadata extraction.
    ///   - settings: Export configuration.
    /// - Throws: `LightlyError.exportFailed` when encoding fails.
    func encode(
        _ image: CGImage,
        originalData: Data,
        settings: ExportSettings
    ) throws -> Data
}

/// ImageIO implementation.
struct ImageIOPhotoExporter: PhotoExporting {

    func encode(
        _ image: CGImage,
        originalData: Data,
        settings: ExportSettings
    ) throws -> Data {
        let output = NSMutableData()

        guard let destination = CGImageDestinationCreateWithData(
            output,
            settings.format.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw LightlyError.exportFailed
        }

        // v3 differs: v1 copied the whole EXIF and IPTC blocks (stale pixel dimensions, maker
        // notes, IPTC place names) and copied GPS only when metadata was kept. The approved
        // Preferences make the two switches independent and the kept fields an allowlist
        // (`ExportMetadataComposer`). Orientation 1 and no thumbnail are always written there.
        var properties = ExportMetadataComposer.properties(
            from: originalData,
            policy: settings.metadataPolicy,
            outputSize: CGSize(width: image.width, height: image.height)
        )

        if settings.format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] =
                settings.quality.compressionQuality
        }

        // v3 differs: v1 embedded whatever profile the image carried (old
        // §15.4, "P3 stays P3"). Spec §4.3 makes export sRGB, so a non-sRGB
        // image is converted here; ImageIO then embeds the sRGB ICC profile
        // taken from the image's colour space.
        guard let sRGBImage = ColorPipeline.convertToSRGB8(image) else {
            throw LightlyError.exportFailed
        }

        // Exactly one image, added once: the file is encoded a single time
        // (spec §5.4), never re-encoded from an earlier lossy pass.
        CGImageDestinationAddImage(destination, sRGBImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw LightlyError.exportFailed
        }

        return output as Data
    }
}
