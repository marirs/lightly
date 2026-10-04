import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Import a signature (approved `wm-sig-import`): "The paper is removed. The ink keeps its
/// original colour and texture."
///
/// The paper is the photo's bright level (90th percentile of luma) and the ink its dark level
/// (2nd percentile). Each pixel's ink coverage α rises from 0 just below the paper level to 1
/// halfway to the ink level; its colour is un-mixed from the paper (C = (P − (1 − α)·paper)/α),
/// so the ink keeps its own hue and the stroke's texture survives as varying α. The result is
/// cropped to the ink and padded like the prototype's signature (the ink spans 32 of 50 units of
/// height, 6 units of margin each side), and written as PNG.
enum SignatureInkExtractor {

    /// The ink's share of the image height (prototype `SIG_DRAWN` spans y 8…40 of a 50 view box).
    static let inkHeightFraction = 32.0 / 50
    static let maximumLongEdge = 1_600

    /// nil when the photo has no ink distinguishable from the paper.
    static func extract(from image: CGImage) -> Data? {
        guard let decoded = rgba8(image, maximumLongEdge: maximumLongEdge) else { return nil }
        let (pixels, width, height) = decoded
        let count = width * height
        var luma = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let o = i * 4
            luma[i] = (0.2126 * Double(pixels[o]) + 0.7152 * Double(pixels[o + 1]) + 0.0722 * Double(pixels[o + 2])) / 255
        }
        let sorted = luma.sorted()
        let paperLevel = sorted[Int(Double(count - 1) * 0.90)]
        let inkLevel = sorted[Int(Double(count - 1) * 0.02)]
        guard paperLevel - inkLevel > 0.15 else { return nil }
        // The paper's colour: the mean of the pixels at or above the paper level.
        var paper = SIMD3<Double>(repeating: 0), paperCount = 0.0
        for i in 0..<count where luma[i] >= paperLevel {
            let o = i * 4
            paper += SIMD3(Double(pixels[o]), Double(pixels[o + 1]), Double(pixels[o + 2])) / 255
            paperCount += 1
        }
        paper /= max(paperCount, 1)
        let start = paperLevel - 0.06, full = paperLevel - (paperLevel - inkLevel) * 0.5
        var output = [UInt8](repeating: 0, count: count * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x, o = i * 4
                let alpha = min(max((start - luma[i]) / max(start - full, 1e-6), 0), 1)
                guard alpha > 0 else { continue }
                let observed = SIMD3(Double(pixels[o]), Double(pixels[o + 1]), Double(pixels[o + 2])) / 255
                var ink = (observed - (1 - alpha) * paper) / alpha
                ink = ink.clamped(lowerBound: .zero, upperBound: .one)
                // Premultiplied, as the bitmap context below expects.
                output[o] = UInt8((ink.x * alpha * 255).rounded())
                output[o + 1] = UInt8((ink.y * alpha * 255).rounded())
                output[o + 2] = UInt8((ink.z * alpha * 255).rounded())
                output[o + 3] = UInt8((alpha * 255).rounded())
                if alpha > 0.2 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let inkHeight = Double(maxY - minY + 1)
        let boxHeight = max(inkHeight / inkHeightFraction, 1)
        let margin = boxHeight * 6 / 50
        let outWidth = Int((Double(maxX - minX + 1) + 2 * margin).rounded())
        let outHeight = Int(boxHeight.rounded())
        let originX = Double(minX) - margin, originY = Double(minY) - (boxHeight - inkHeight) / 2
        guard let full = Self.image(rgba: output, width: width, height: height),
              let context = CGContext(data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: outWidth * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Bottom-left origin: place the full ink layer so the crop box maps to the output.
        context.draw(full, in: CGRect(x: -originX, y: -(Double(height) - (originY + boxHeight)), width: Double(width), height: Double(height)))
        guard let cropped = context.makeImage() else { return nil }
        return png(cropped)
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// A chosen logo as PNG (downscaled to 1024 on its long edge), keeping its own colours.
    static func logoPNG(from image: CGImage) -> Data? {
        guard let decoded = rgba8(image, maximumLongEdge: 1_024),
              let scaled = Self.image(rgba: decoded.0, width: decoded.1, height: decoded.2) else { return nil }
        return png(scaled)
    }

    private static func rgba8(_ image: CGImage, maximumLongEdge: Int) -> ([UInt8], Int, Int)? {
        let scale = min(1, Double(maximumLongEdge) / Double(max(image.width, image.height)))
        let width = max(Int((Double(image.width) * scale).rounded()), 1), height = max(Int((Double(image.height) * scale).rounded()), 1)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (pixels, width, height) : nil
    }

    private static func image(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The prototype's imported signature (`sigSvg(h, '', true)`): the sample path in #1D2A6B at
    /// stroke 2.6 and 90 % opacity, over a 1 px echo offset (1.2, 0.8) at 35 %, in a 170 × 50 box,
    /// as a transparent PNG at 6× (what an import of that paper signature would give). Design
    /// captures and tests use it to reproduce the approved screens.
    static func prototypeImportedSample(scale: Double = 6) -> Data? {
        let sample = DrawnSignature.prototypeSample
        let width = Int(170 * scale), height = Int(50 * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let ink = CGColor(srgbRed: 0x1D / 255.0, green: 0x2A / 255.0, blue: 0x6B / 255.0, alpha: 1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(ink)
        context.setAlpha(0.9)
        context.setLineWidth(2.6 * scale)
        context.addPath(sample.path(origin: .zero, height: 50 * scale))
        context.strokePath()
        context.setAlpha(0.35)
        context.setLineWidth(1 * scale)
        context.addPath(sample.path(origin: CGPoint(x: 1.2 * scale, y: 0.8 * scale), height: 50 * scale))
        context.strokePath()
        return context.makeImage().flatMap(png)
    }
}
