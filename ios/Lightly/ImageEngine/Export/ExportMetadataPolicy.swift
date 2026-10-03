import CoreGraphics
import Foundation
import ImageIO

/// Which optional metadata a saved copy carries (approved Preferences › Saving).
///
/// Two independent switches. Turning one off never changes the other: a person can keep the
/// camera details without the location, or share where a photo was taken without the camera
/// details. Whatever they choose, the colour profile is always kept and the dimensions,
/// orientation and thumbnail always describe the new image, never the original file.
struct ExportMetadataPolicy: Equatable, Sendable {
    /// "Keep photo metadata": camera, lens, aperture, shutter speed, ISO and date taken.
    var keepsCaptureMetadata: Bool
    /// "Include location": the GPS block. Off by default.
    var includesLocation: Bool

    static let `default` = ExportMetadataPolicy(keepsCaptureMetadata: true, includesLocation: false)
}

/// Builds the ImageIO properties for one exported image from the original file's metadata.
///
/// An allowlist, not a copy-then-strip: the original's EXIF also holds maker notes, user
/// comments, serial numbers, stale pixel dimensions and thumbnail offsets, none of which the
/// person asked to keep and several of which would be wrong on the new file.
enum ExportMetadataComposer {

    /// EXIF capture fields kept by "Keep photo metadata". Held as `String` (CFString is not
    /// Sendable); ImageIO's keys bridge to the same strings.
    static let keptExifKeys: [String] = [
        // Aperture.
        kCGImagePropertyExifFNumber, kCGImagePropertyExifApertureValue,
        // Shutter speed.
        kCGImagePropertyExifExposureTime, kCGImagePropertyExifShutterSpeedValue,
        // ISO.
        kCGImagePropertyExifISOSpeedRatings,
        // Date taken (with its time zone and sub-second part, which belong to the same moment).
        kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifOffsetTimeOriginal,
        kCGImagePropertyExifSubsecTimeOriginal,
        // Lens.
        kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel,
        kCGImagePropertyExifLensSpecification, kCGImagePropertyExifFocalLength,
        kCGImagePropertyExifFocalLenIn35mmFilm
    ].map { $0 as String }

    /// TIFF fields kept by "Keep photo metadata": the camera. Not the TIFF orientation, which
    /// describes the original's pixels, nor Software/DateTime, which describe the original file.
    static let keptTIFFKeys: [String] = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel].map { $0 as String }

    /// Properties for `CGImageDestinationAddImage`.
    ///
    /// - Parameters:
    ///   - originalData: The bytes the photo was opened from. Unreadable or empty data simply
    ///     yields no carried metadata: a photo without provenance still saves.
    ///   - outputSize: Pixel size of the image being written, used for the EXIF pixel dimensions
    ///     so they never carry the original's (possibly cropped or downscaled) size.
    static func properties(
        from originalData: Data,
        policy: ExportMetadataPolicy,
        outputSize: CGSize
    ) -> [CFString: Any] {
        var properties: [CFString: Any] = [
            // The rendered pixels are already upright: any other value would rotate the photo a
            // second time in every viewer.
            kCGImagePropertyOrientation: 1,
            // A thumbnail would be a second, smaller picture of whatever was encoded; it is never
            // wanted in a saved copy and would go stale if anything rewrote the main image.
            kCGImageDestinationEmbedThumbnail: false
        ]
        let source = sourceProperties(of: originalData)

        if policy.keepsCaptureMetadata {
            if let exif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                var kept = exif.filter { keptExifKeys.contains($0.key as String) }
                if !kept.isEmpty {
                    // Written for the new image whenever an EXIF block is written at all.
                    kept[kCGImagePropertyExifPixelXDimension] = Int(outputSize.width)
                    kept[kCGImagePropertyExifPixelYDimension] = Int(outputSize.height)
                    properties[kCGImagePropertyExifDictionary] = kept
                }
            }
            if let tiff = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                var kept = tiff.filter { keptTIFFKeys.contains($0.key as String) }
                if !kept.isEmpty {
                    kept[kCGImagePropertyTIFFOrientation] = 1
                    properties[kCGImagePropertyTIFFDictionary] = kept
                }
            }
        }

        // Independent of the capture fields on purpose (see the type's comment).
        if policy.includesLocation, let gps = source[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty {
            properties[kCGImagePropertyGPSDictionary] = gps
        }
        return properties
    }

    private static func sourceProperties(of data: Data) -> [CFString: Any] {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return [:]
        }
        return properties
    }
}
