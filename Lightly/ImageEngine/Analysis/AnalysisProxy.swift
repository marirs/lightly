import CoreGraphics
import Foundation
import ImageIO

/// The reduced-size, upright, sRGB image that analysis (and, later, the Auto
/// model's canonical input) is computed from.
///
/// Why a separate decode: analysis at full resolution cost about 45 B/px —
/// roughly 2.2 GB for a 48 MP photo (spec §12 j). ImageIO's thumbnail path
/// decodes straight to the target size (using the codec's downscaled decode
/// where it has one), so the full-resolution bitmap is never materialised for
/// analysis. The long edge is 1024: the bound asked for here, and also the
/// minimum the model contract accepts as its source (spec §4.6).
enum AnalysisProxy {

    static let maximumLongEdge = 1024

    /// Builds the proxy, preferring the encoded bytes over the decoded image.
    ///
    /// - Throws: `LightlyError.developFailed` when neither path yields pixels.
    static func make(from photo: SelectedPhoto) throws -> CGImage {
        let proxy = photo.originalData.isEmpty
            ? downscaled(photo.image)
            : decoded(photo.originalData) ?? downscaled(photo.image)
        guard let proxy, let sRGBProxy = ColorPipeline.convertToSRGB8(proxy) else {
            throw LightlyError.developFailed
        }
        return sRGBProxy
    }

    /// Decodes at most `maximumLongEdge` directly from the encoded bytes,
    /// with EXIF orientation applied.
    static func decoded(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            // Always from the full image: an embedded EXIF preview is often
            // only 160 px and would make analysis depend on the camera.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumLongEdge,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Fallback for photos with no encoded bytes (synthetic or rendered
    /// images): the decode already exists, so only the analysis working set
    /// is bounded here.
    static func downscaled(_ image: CGImage) -> CGImage? {
        let longEdge = max(image.width, image.height)
        guard longEdge > maximumLongEdge else { return image }

        let scale = Double(maximumLongEdge) / Double(longEdge)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: ColorPipeline.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
