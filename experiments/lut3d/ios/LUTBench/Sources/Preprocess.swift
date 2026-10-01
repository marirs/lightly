import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// 8-bit RGBX pixels in sRGB with explicit row stride (vImage buffers may pad rows).
final class RGBX8Image {
    let width: Int
    let height: Int
    let rowBytes: Int
    let pixels: UnsafeMutableRawPointer

    init(width: Int, height: Int, rowBytes: Int, pixels: UnsafeMutableRawPointer) {
        self.width = width
        self.height = height
        self.rowBytes = rowBytes
        self.pixels = pixels
    }

    /// Takes ownership of `buffer.data` (allocated by vImage with malloc).
    convenience init(adopting buffer: vImage_Buffer) {
        self.init(width: Int(buffer.width), height: Int(buffer.height), rowBytes: buffer.rowBytes, pixels: buffer.data)
    }

    static func allocate(width: Int, height: Int) -> RGBX8Image {
        let rowBytes = width * 4
        return RGBX8Image(width: width, height: height, rowBytes: rowBytes, pixels: malloc(rowBytes * height)!)
    }

    var vImageBuffer: vImage_Buffer {
        vImage_Buffer(data: pixels, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
    }

    deinit { free(pixels) }
}

enum ImageDecoding {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// RGBX8888 in sRGB. Golden source.png files are written by PIL without an ICC chunk; ImageIO treats
    /// untagged RGB PNG as sRGB, so the conversion below is a no-op for them (and correct for tagged files).
    static var rgbx8Format: vImage_CGImageFormat {
        vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            renderingIntent: .defaultIntent)!
    }

    /// Fully decoded CGImage (ShouldCacheImmediately forces the decode inside this call).
    static func decodeCGImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: true] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw BenchError.message("ImageIO could not decode \(url.lastPathComponent)") }
        return image
    }

    /// ImageIO decode straight into a vImage RGBX8 sRGB buffer.
    static func decodeRGBX8(at url: URL) throws -> RGBX8Image {
        let image = try decodeCGImage(at: url)
        return try rgbx8(from: image)
    }

    static func rgbx8(from image: CGImage) throws -> RGBX8Image {
        var format = rgbx8Format
        var buffer = vImage_Buffer()
        let error = vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoFlags))
        guard error == kvImageNoError else { throw BenchError.message("vImageBuffer_InitWithCGImage failed: \(error)") }
        return RGBX8Image(adopting: buffer)
    }

    /// Downsampled decode as a preview pipeline would do it (ImageIO thumbnail, applies EXIF orientation).
    static func decodeThumbnail(at url: URL, maxPixelSize: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary)
        else { throw BenchError.message("ImageIO thumbnail failed for \(url.lastPathComponent)") }
        return image
    }
}

enum ClassifierPreprocessing {
    /// Chosen on-device resize: vImageScale_ARGB8888 with default flags (+ edge extend), i.e. vImage's
    /// Lanczos-3 kernel, which vImage widens automatically when downscaling (so it is antialiased).
    /// It operates on 8-bit data, so the 256x256 result is re-quantised to 8 bits before /255.
    /// The golden uses torch bilinear antialias=True (a widened triangle filter) on float data; the
    /// `torchAntialiasedBilinear` port below reproduces that exactly so filter choice can be separated
    /// from model/platform error.
    static let vImageMethodDescription = "vImageScale_ARGB8888 (default flags = Lanczos3, kvImageEdgeExtend), 8-bit, whole frame to 256x256 ignoring aspect, sRGB-encoded"

    static func resizeWithVImage(_ source: RGBX8Image) throws -> RGBX8Image {
        let destination = RGBX8Image.allocate(width: ClassifierIO.inputSide, height: ClassifierIO.inputSide)
        var sourceBuffer = source.vImageBuffer
        var destinationBuffer = destination.vImageBuffer
        let error = vImageScale_ARGB8888(&sourceBuffer, &destinationBuffer, nil, vImage_Flags(kvImageEdgeExtend))
        guard error == kvImageNoError else { throw BenchError.message("vImageScale_ARGB8888 failed: \(error)") }
        return destination
    }

    /// RGBX8 256x256 -> NCHW float [0,1].
    static func chwTensor(from image: RGBX8Image) -> [Float] {
        let side = ClassifierIO.inputSide
        let planeSize = side * side
        var tensor = [Float](repeating: 0, count: 3 * planeSize)
        tensor.withUnsafeMutableBufferPointer { output in
            for y in 0..<side {
                let row = image.pixels.advanced(by: y * image.rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<side {
                    for channel in 0..<3 {
                        output[channel * planeSize + y * side + x] = Float(row[x * 4 + channel]) / 255
                    }
                }
            }
        }
        return tensor
    }

    // MARK: torch.nn.functional.interpolate(mode="bilinear", antialias=True, align_corners=False) port

    /// Separable filter taps for one axis, following ATen's _upsample_aa / PIL ImagingResample:
    ///   center = scale*(i+0.5); support = scale (bilinear interp_size 2, downscaling);
    ///   xmin = max(trunc(center - support + 0.5), 0); xmax = min(trunc(center + support + 0.5), inSize)
    ///   w_j  = triangle((j + xmin - center + 0.5) / scale), normalised to sum 1.
    private struct AxisTaps {
        var start: [Int] = []
        var weights: [[Float]] = []
    }

    private static func axisTaps(inputSize: Int, outputSize: Int) -> AxisTaps {
        let scale = Double(inputSize) / Double(outputSize)
        let support = scale >= 1 ? scale : 1.0
        let inverseScale = scale >= 1 ? 1 / scale : 1.0
        var taps = AxisTaps()
        for outputIndex in 0..<outputSize {
            let center = scale * (Double(outputIndex) + 0.5)
            let first = max(Int(center - support + 0.5), 0)
            let end = min(Int(center + support + 0.5), inputSize)
            var weights: [Double] = []
            for j in first..<end {
                let distance = (Double(j) - center + 0.5) * inverseScale
                weights.append(max(0, 1 - abs(distance)))
            }
            let total = weights.reduce(0, +)
            taps.start.append(first)
            taps.weights.append(weights.map { Float(total > 0 ? $0 / total : 0) })
        }
        return taps
    }

    /// Exact (to float rounding) port of the golden preprocessing; CPU, not optimised.
    static func torchAntialiasedBilinear(_ source: RGBX8Image) -> [Float] {
        let side = ClassifierIO.inputSide
        let horizontal = axisTaps(inputSize: source.width, outputSize: side)
        let vertical = axisTaps(inputSize: source.height, outputSize: side)
        var tensor = [Float](repeating: 0, count: 3 * side * side)
        // Horizontal pass first: [height x 256] per channel in float.
        var horizontallyResized = [Float](repeating: 0, count: 3 * source.height * side)
        horizontallyResized.withUnsafeMutableBufferPointer { intermediate in
            for y in 0..<source.height {
                let row = source.pixels.advanced(by: y * source.rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<side {
                    let start = horizontal.start[x]
                    let weights = horizontal.weights[x]
                    var sums: (Float, Float, Float) = (0, 0, 0)
                    for (offset, weight) in weights.enumerated() {
                        let pixel = (start + offset) * 4
                        sums.0 += weight * Float(row[pixel]) / 255
                        sums.1 += weight * Float(row[pixel + 1]) / 255
                        sums.2 += weight * Float(row[pixel + 2]) / 255
                    }
                    let base = y * side + x
                    intermediate[base] = sums.0
                    intermediate[source.height * side + base] = sums.1
                    intermediate[2 * source.height * side + base] = sums.2
                }
            }
        }
        horizontallyResized.withUnsafeBufferPointer { intermediate in
            tensor.withUnsafeMutableBufferPointer { output in
                for channel in 0..<3 {
                    let planeOffset = channel * source.height * side
                    for y in 0..<side {
                        let start = vertical.start[y]
                        let weights = vertical.weights[y]
                        for x in 0..<side {
                            var sum: Float = 0
                            for (offset, weight) in weights.enumerated() {
                                sum += weight * intermediate[planeOffset + (start + offset) * side + x]
                            }
                            output[channel * side * side + y * side + x] = sum
                        }
                    }
                }
            }
        }
        return tensor
    }
}

enum ArrayComparison {
    static func maxAbsDifference(_ lhs: [Float], _ rhs: [Float]) -> Double {
        precondition(lhs.count == rhs.count, "length mismatch \(lhs.count) vs \(rhs.count)")
        var maximum: Float = 0
        for index in lhs.indices { maximum = max(maximum, abs(lhs[index] - rhs[index])) }
        return Double(maximum)
    }

    static func meanAbsDifference(_ lhs: [Float], _ rhs: [Float]) -> Double {
        var total: Double = 0
        for index in lhs.indices { total += Double(abs(lhs[index] - rhs[index])) }
        return total / Double(max(lhs.count, 1))
    }

    static func readFloat32File(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
