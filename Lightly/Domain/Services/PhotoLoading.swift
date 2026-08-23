import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Decodes a user-selected asset into a `SelectedPhoto`.
///
/// Phase 1 defines the boundary only. The real implementation (orientation
/// normalisation, colour-space handling, RAW budgeting) arrives in Phase 2 with
/// the image pipeline; until then a mock conforms to this protocol so the UI
/// shell is fully testable without Photos or Core Image.
protocol PhotoLoading: Sendable {

    /// Whether this loader applies EXIF orientation normalisation.
    ///
    /// Declared on the protocol rather than left as a comment because the V1
    /// acceptance criterion "selected image orientation is correct" cannot be
    /// claimed while this is `false`. A test asserts the current value, so
    /// implementing normalisation forces that assertion to be updated — the
    /// debt cannot be silently absorbed.
    var normalisesOrientation: Bool { get }

    /// Whether this loader preserves the asset's original encoding.
    ///
    /// `false` means the pipeline re-encodes on ingest, losing quality before
    /// editing has even begun — unacceptable in a photo application, and
    /// tracked as Phase 2 work.
    var preservesOriginalEncoding: Bool { get }

    /// Decodes transferable data produced by `PhotosPicker` or the camera.
    ///
    /// - Parameters:
    ///   - data: Raw bytes vended by the system picker or capture flow.
    ///   - source: Provenance, preserved on the resulting value.
    /// - Returns: A normalised, ready-to-edit photograph.
    /// - Throws: `LightlyError.unsupportedImageFormat` when the bytes cannot be
    ///   decoded, or `LightlyError.photoLoadingFailed` for any other decode
    ///   failure. Callers must map both onto a defined state from spec §28.
    func loadPhoto(from data: Data, source: PhotoSource) async throws -> SelectedPhoto
}

/// Decodes images using ImageIO, normalising orientation on ingest.
///
/// Orientation is resolved here — at the boundary — rather than at display time.
/// A `CGImage` carries no orientation of its own, so if the EXIF tag were left
/// unapplied every downstream consumer (editor, thumbnails, renderer, export)
/// would have to remember to compensate, and any one of them forgetting would
/// produce a rotated result. Normalising once means the domain layer only ever
/// holds upright pixels.
///
/// Colour management and RAW handling remain Phase 2 decisions.
struct ImageIOPhotoLoader: PhotoLoading {

    /// EXIF orientation is applied during `loadPhoto`.
    let normalisesOrientation = true

    /// Camera captures now arrive as HEIC (the native iPhone capture format)
    /// rather than lossy JPEG re-encodes. Photo Library selections have always
    /// been passed through unmodified. True RAW/ProRAW preservation — retaining
    /// the raw sensor data — requires `AVCapturePhotoOutput` and is Phase 5+.
    let preservesOriginalEncoding = true

    /// Shared context for the orientation transform.
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func loadPhoto(from data: Data, source: PhotoSource) async throws -> SelectedPhoto {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw LightlyError.unsupportedImageFormat
        }

        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw LightlyError.photoLoadingFailed
        }

        let orientation = exifOrientation(of: imageSource)
        return SelectedPhoto(
            image: try upright(image, exifOrientation: orientation),
            source: source,
            // Retained so export can carry EXIF across; a CGImage has none.
            originalData: data
        )
    }

    /// Reads the EXIF orientation tag, defaulting to "already upright".
    ///
    /// A missing tag is normal — screenshots and rendered images often have
    /// none — and means no rotation is needed.
    private func exifOrientation(of imageSource: CGImageSource) -> Int32 {
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let value = properties?[kCGImagePropertyOrientation] as? Int32
        return value ?? 1
    }

    /// Applies the orientation transform, returning upright pixels.
    ///
    /// - Returns: The source unchanged when it is already upright, avoiding a
    ///   pointless re-render of every screenshot and rendered image.
    private func upright(_ image: CGImage, exifOrientation: Int32) throws -> CGImage {
        // 1 is "upright, no transform required".
        guard exifOrientation != 1 else { return image }

        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: exifOrientation)

        guard let output = context.createCGImage(oriented, from: oriented.extent) else {
            throw LightlyError.photoLoadingFailed
        }
        return output
    }
}
