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
    ///   - colorSpace: The colour space to embed in the output file. When
    ///     `nil`, the image's own colour space is used (spec §15.4).
    /// - Throws: `LightlyError.exportFailed` when encoding fails.
    func encode(
        _ image: CGImage,
        originalData: Data,
        settings: ExportSettings,
        colorSpace: CGColorSpace?
    ) throws -> Data
}

/// ImageIO implementation.
struct ImageIOPhotoExporter: PhotoExporting {

    func encode(
        _ image: CGImage,
        originalData: Data,
        settings: ExportSettings,
        colorSpace: CGColorSpace? = nil
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

        // Colour space preservation (spec §15.4): the CGImage produced by
        // RecipeRenderer already carries the source's colour space (P3, sRGB,
        // etc.) via the outputColorSpace parameter. ImageIO automatically
        // embeds that colour profile when encoding, so no explicit embedding
        // step is needed here.

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

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
