import CoreGraphics
import CoreImage
import Foundation

/// The single, explicit colour policy for V1 (spec §4.3).
///
/// Working and output space is sRGB: Looks and the Auto model are defined in
/// the sRGB-encoded domain, and V1 exports sRGB JPEG. Wide-gamut originals
/// (Display P3, Adobe RGB) are converted once, at decode, so every later stage
/// sees one space. Device RGB is never used: it is uncalibrated, so the same
/// bytes would mean different colours depending on the device.
enum ColorPipeline {

    /// The working, interchange and export colour space.
    static let sRGB: CGColorSpace = {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            preconditionFailure("sRGB is a system colour space and always exists")
        }
        return space
    }()

    /// Core Image's internal space. Linear light so filters behave
    /// physically; extended so intermediate values outside [0,1] survive until
    /// the final clamp at encode.
    static let coreImageWorkingSpace: CGColorSpace = {
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
            preconditionFailure("extendedLinearSRGB is a system colour space and always exists")
        }
        return space
    }()

    /// A Core Image context whose colour behaviour is stated, not defaulted.
    static func makeContext() -> CIContext {
        CIContext(options: [
            .useSoftwareRenderer: false,
            .workingColorSpace: coreImageWorkingSpace,
            .outputColorSpace: sRGB
        ])
    }

    /// Renders `image` to an 8-bit sRGB bitmap.
    static func renderSRGB(_ image: CIImage, in context: CIContext) -> CGImage? {
        context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB)
    }

    /// Converts any CGImage to 8-bit sRGB through ColorSync (a draw into an
    /// sRGB bitmap), for callers that hold a CGImage rather than a CIImage.
    static func convertToSRGB8(_ image: CGImage) -> CGImage? {
        if isSRGB8(image) { return image }
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Whether `image` is already 8-bit sRGB, so conversion would be a no-op.
    static func isSRGB8(_ image: CGImage) -> Bool {
        image.colorSpace?.name == CGColorSpace.sRGB && image.bitsPerComponent == 8
    }
}
