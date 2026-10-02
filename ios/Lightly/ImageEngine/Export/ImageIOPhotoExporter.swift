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

        var properties: [CFString: Any] = [:]

        if settings.format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] =
                settings.quality.compressionQuality
        }

        if settings.preservesMetadata {
            properties.merge(
                metadataToCarryOver(from: originalData, includingLocation: settings.preservesLocation)
            ) { current, _ in current }
        }

        // The rendered image is already upright, so the exported file must
        // declare orientation 1. Copying the source's orientation tag across
        // would rotate the photograph a second time on every viewer.
        properties[kCGImagePropertyOrientation] = 1

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

    /// Extracts the metadata blocks worth carrying to the exported file.
    ///
    /// Deliberately selective rather than a wholesale copy: the source
    /// dictionary also contains pixel dimensions, colour profile details, and
    /// thumbnail data that describe the *original* file and would be wrong or
    /// misleading attached to the exported one.
    private func metadataToCarryOver(
        from originalData: Data,
        includingLocation: Bool
    ) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(originalData as CFData, nil),
              let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            // Missing metadata is not an export failure — the photograph still
            // exports, simply without provenance.
            return [:]
        }

        var carried: [CFString: Any] = [:]

        // EXIF: capture date, exposure, camera settings.
        if let exif = sourceProperties[kCGImagePropertyExifDictionary] {
            carried[kCGImagePropertyExifDictionary] = exif
        }

        // TIFF: camera make and model.
        if let tiff = sourceProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            var cleaned = tiff
            // The TIFF block carries its own orientation field, which would
            // otherwise contradict the corrected orientation set above.
            cleaned.removeValue(forKey: kCGImagePropertyTIFFOrientation)
            carried[kCGImagePropertyTIFFDictionary] = cleaned
        }

        if let iptc = sourceProperties[kCGImagePropertyIPTCDictionary] {
            carried[kCGImagePropertyIPTCDictionary] = iptc
        }

        // GPS travels only on explicit opt-in (spec §13, §19).
        if includingLocation, let gps = sourceProperties[kCGImagePropertyGPSDictionary] {
            carried[kCGImagePropertyGPSDictionary] = gps
        }

        return carried
    }
}
