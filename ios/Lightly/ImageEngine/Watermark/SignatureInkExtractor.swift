import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Import a signature (approved `wm-sig-import`): "The paper is removed. The ink keeps its
/// original colour and texture."
///
/// The paper is estimated locally (the 90th luma percentile of 32 px blocks, smoothed), so uneven
/// lighting on a photographed page does not survive as a tinted rectangle. A pixel's ink coverage
/// rises from well above the paper's grain to full at half the ink's contrast; below a hard floor,
/// and anywhere more than a few px from ink, it is exactly 0. The ink's colour is un-mixed from the
/// local paper colour (C = (P − (1 − α)·paper)/α), so the ink keeps its hue without a paper fringe.
/// The result is cropped to the ink and padded like the prototype's signature (the ink spans 32 of
/// 50 units of height, 6 units of margin each side), and written as PNG.
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
        // The paper's own level, locally: lighting and shadows make a photographed page uneven,
        // so a single global level leaves its darker parts as a faint tinted rectangle.
        let paperLuma = localPaperLevel(luma, width: width, height: height)
        let paperRGB = localPaperColour(pixels, luma: luma, paperLuma: paperLuma, width: width, height: height)
        var difference = [Double](repeating: 0, count: count)
        for i in 0..<count { difference[i] = max(paperLuma[i] - luma[i], 0) }
        let inkContrast = difference.sorted()[Int(Double(count - 1) * 0.98)]
        guard inkContrast > 0.15 else { return nil }
        // Coverage rises from a threshold well above the paper's grain to full at half the ink's
        // contrast; below `alphaFloor` it is exactly 0.
        let start = max(0.06, inkContrast * 0.22), full = inkContrast * 0.5
        var alpha = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let a = min(max((difference[i] - start) / max(full - start, 1e-6), 0), 1)
            alpha[i] = a < alphaFloor ? 0 : a
        }
        // Feathering only near ink: coverage survives only within `inkProximity` px of a core
        // pixel (coverage ≥ 0.5); everything else is paper and becomes exactly transparent.
        let near = Self.dilate(alpha.map { $0 >= 0.5 }, width: width, height: height, radius: inkProximity)
        var output = [UInt8](repeating: 0, count: count * 4)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x, o = i * 4
                guard near[i], alpha[i] > 0 else { continue }
                let a = alpha[i]
                let observed = SIMD3(Double(pixels[o]), Double(pixels[o + 1]), Double(pixels[o + 2])) / 255
                var ink = (observed - (1 - a) * paperRGB[i]) / a
                ink = ink.clamped(lowerBound: .zero, upperBound: .one)
                // Premultiplied, as the bitmap context below expects.
                output[o] = UInt8((ink.x * a * 255).rounded())
                output[o + 1] = UInt8((ink.y * a * 255).rounded())
                output[o + 2] = UInt8((ink.z * a * 255).rounded())
                output[o + 3] = UInt8((a * 255).rounded())
                if a > 0.2 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
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

    /// Coverage below this is paper: exactly transparent.
    static let alphaFloor = 0.12
    /// Partial coverage is kept only this close to ink (px, at the working size).
    static let inkProximity = 4

    /// The paper's luma around each pixel: the 90th percentile of 32 px blocks (ink is a small
    /// share of a block), smoothed across blocks so it follows lighting, not strokes.
    static func localPaperLevel(_ luma: [Double], width: Int, height: Int) -> [Double] {
        let block = 32
        let bw = (width + block - 1) / block, bh = (height + block - 1) / block
        var levels = [Double](repeating: 0, count: bw * bh)
        for by in 0..<bh {
            for bx in 0..<bw {
                var values: [Double] = []
                for y in (by * block)..<min((by + 1) * block, height) {
                    for x in (bx * block)..<min((bx + 1) * block, width) { values.append(luma[y * width + x]) }
                }
                values.sort()
                levels[by * bw + bx] = values[Int(Double(values.count - 1) * 0.9)]
            }
        }
        // A block that is mostly ink takes the brightest neighbour (3 × 3), so strokes never set the paper.
        var spread = levels
        for by in 0..<bh {
            for bx in 0..<bw {
                var best = levels[by * bw + bx]
                for dy in -1...1 { for dx in -1...1 {
                    let x = bx + dx, y = by + dy
                    if x >= 0, y >= 0, x < bw, y < bh { best = max(best, levels[y * bw + x]) }
                } }
                spread[by * bw + bx] = best
            }
        }
        // Bilinear between block centres.
        var out = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let fy = min(max((Double(y) + 0.5) / Double(block) - 0.5, 0), Double(bh - 1))
            let y0 = Int(fy), y1 = min(y0 + 1, bh - 1), ty = fy - Double(y0)
            for x in 0..<width {
                let fx = min(max((Double(x) + 0.5) / Double(block) - 0.5, 0), Double(bw - 1))
                let x0 = Int(fx), x1 = min(x0 + 1, bw - 1), tx = fx - Double(x0)
                let top = spread[y0 * bw + x0] * (1 - tx) + spread[y0 * bw + x1] * tx
                let bottom = spread[y1 * bw + x0] * (1 - tx) + spread[y1 * bw + x1] * tx
                out[y * width + x] = top * (1 - ty) + bottom * ty
            }
        }
        return out
    }

    /// The paper's colour around each pixel: the page's mean paper hue (pixels at their local
    /// paper level) at the local paper brightness, so the un-mixed ink has no paper fringe.
    static func localPaperColour(_ pixels: [UInt8], luma: [Double], paperLuma: [Double], width: Int, height: Int) -> [SIMD3<Double>] {
        var sum = SIMD3<Double>(repeating: 0), n = 0.0, lumaSum = 0.0
        for i in 0..<(width * height) where luma[i] >= paperLuma[i] - 0.02 {
            let o = i * 4
            sum += SIMD3(Double(pixels[o]), Double(pixels[o + 1]), Double(pixels[o + 2])) / 255
            lumaSum += luma[i]; n += 1
        }
        let hue = n > 0 ? sum / n : SIMD3(repeating: 1)
        let hueLuma = n > 0 ? lumaSum / n : 1
        return paperLuma.map { level in (hue * (level / max(hueLuma, 1e-6))).clamped(lowerBound: .zero, upperBound: .one) }
    }

    /// Square dilation of a mask (separable max).
    static func dilate(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var horizontal = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width {
                var hit = false
                for dx in max(0, x - radius)...min(width - 1, x + radius) where mask[y * width + dx] { hit = true; break }
                horizontal[y * width + x] = hit
            }
        }
        var out = [Bool](repeating: false, count: mask.count)
        for x in 0..<width {
            for y in 0..<height {
                var hit = false
                for dy in max(0, y - radius)...min(height - 1, y + radius) where horizontal[dy * width + x] { hit = true; break }
                out[y * width + x] = hit
            }
        }
        return out
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Import signature (defect W6: Use must never be dead; the as-is fallback is a PROVISIONAL
    /// coordinator approach, pending the owner): the paper removed when ink is found; otherwise the
    /// photo as it is (no paper removal), downscaled to 1,600 px on its long edge, so Use always
    /// works (the prototype's Use always saves). nil only when the image cannot be read.
    static func importPNG(from image: CGImage) -> Data? {
        switch importSignature(from: image) {
        case .inkFound(let png), .asIs(let png): return png
        case .blank, .unreadable: return nil
        }
    }

    /// What an import gives (W6 and its follow-up): a signature with the paper removed; a photo
    /// with content but no ink told from the paper, used as it is; a blank page (nothing to show:
    /// its "signature" would be an empty rectangle); or an image that could not be read.
    enum ImportResult: Equatable {
        case inkFound(Data)
        case asIs(Data)
        case blank
        case unreadable
    }

    /// Luma spread (98th − 2nd percentile) below which a page holds nothing to import.
    static let blankSpread = 0.04

    static func importSignature(from image: CGImage?) -> ImportResult {
        guard let image, let decoded = rgba8(image, maximumLongEdge: maximumLongEdge) else { return .unreadable }
        if let extracted = extract(from: image) { return .inkFound(extracted) }
        let (pixels, width, height) = decoded
        var luma = [Double](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let o = i * 4
            luma[i] = (0.2126 * Double(pixels[o]) + 0.7152 * Double(pixels[o + 1]) + 0.0722 * Double(pixels[o + 2])) / 255
        }
        luma.sort()
        let spread = luma[Int(Double(luma.count - 1) * 0.98)] - luma[Int(Double(luma.count - 1) * 0.02)]
        guard spread >= blankSpread else { return .blank }
        guard let scaled = Self.image(rgba: pixels, width: width, height: height), let data = png(scaled) else { return .unreadable }
        return .asIs(data)
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
