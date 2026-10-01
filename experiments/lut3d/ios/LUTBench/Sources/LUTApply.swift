import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

enum LUTFusion {
    static let dimension = 33
    static let floatsPerLUT = 33 * 33 * 33 * 4  // RGBA, red fastest (CIColorCube order)

    /// Fused = sum_i w_i * LUT_i over the interleaved RGBA float arrays, then alpha reset to 1
    /// (each basis LUT has alpha 1, so the weighted sum would otherwise give alpha = sum(w)).
    static func fuse(basisLUTs: [Float], weights: [Float]) -> [Float] {
        precondition(basisLUTs.count == 3 * floatsPerLUT && weights.count == 3)
        var fused = [Float](repeating: 0, count: floatsPerLUT)
        let length = vDSP_Length(floatsPerLUT)
        basisLUTs.withUnsafeBufferPointer { basis in
            fused.withUnsafeMutableBufferPointer { output in
                var weight0 = weights[0], weight1 = weights[1], weight2 = weights[2]
                vDSP_vsmul(basis.baseAddress!, 1, &weight0, output.baseAddress!, 1, length)
                vDSP_vsma(basis.baseAddress! + floatsPerLUT, 1, &weight1, output.baseAddress!, 1, output.baseAddress!, 1, length)
                vDSP_vsma(basis.baseAddress! + 2 * floatsPerLUT, 1, &weight2, output.baseAddress!, 1, output.baseAddress!, 1, length)
                var one: Float = 1
                vDSP_vfill(&one, output.baseAddress! + 3, 4, vDSP_Length(dimension * dimension * dimension))
            }
        }
        return fused
    }
}

/// How the fused LUT is applied with Core Image. Core Image normally works in a *linear* (extended
/// linear sRGB) working space, but the LUT was trained on sRGB-*encoded* values, so the cube must see
/// gamma-encoded input. Variants:
///  - cubeWithColorSpace_linearWorking: CIColorCubeWithColorSpace(colorSpace: sRGB). CI converts
///    working-linear -> sRGB-encoded, applies the cube, converts back. The intended API for this.
///  - cube_sRGBWorking: plain CIColorCube with the CIContext workingColorSpace = sRGB (non-linear), so
///    the working values already are sRGB-encoded and no conversion happens around the cube.
///  - cube_linearWorking_naive: plain CIColorCube in the default linear working space (the common
///    mistake; applies the LUT to linear values). Diagnostic only.
///  Each is also tried with workingFormat RGBAf (default on GPU is RGBAh, half float).
enum LUTApplicationMethod: String, CaseIterable {
    case cubeWithColorSpace_linearWorking
    case cube_sRGBWorking
    case cube_linearWorking_naive
    case cubeWithColorSpace_linearWorking_RGBAf
    case cube_sRGBWorking_RGBAf

    var isDiagnosticOnly: Bool { self == .cube_linearWorking_naive }
}

final class CoreImageLUTApplier {
    let metalDevice: MTLDevice
    private var contexts: [LUTApplicationMethod: CIContext] = [:]
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw BenchError.message("no Metal device") }
        metalDevice = device
        for method in LUTApplicationMethod.allCases {
            contexts[method] = Self.makeContext(device: device, method: method)
        }
    }

    private static func makeContext(device: MTLDevice, method: LUTApplicationMethod) -> CIContext {
        var options: [CIContextOption: Any] = [
            .cacheIntermediates: false,          // every timed run does the full work
            .name: "lutbench-\(method.rawValue)",
        ]
        switch method {
        case .cube_sRGBWorking, .cube_sRGBWorking_RGBAf:
            options[.workingColorSpace] = sRGB
        default:
            break  // default: extended linear sRGB
        }
        switch method {
        case .cubeWithColorSpace_linearWorking_RGBAf, .cube_sRGBWorking_RGBAf:
            options[.workingFormat] = CIFormat.RGBAf
        default:
            break
        }
        return CIContext(mtlDevice: device, options: options)
    }

    func context(for method: LUTApplicationMethod) -> CIContext { contexts[method]! }

    func filteredImage(source: CGImage, fusedLUT: Data, method: LUTApplicationMethod) -> CIImage {
        // Tag explicitly as sRGB so CI's input conversion is well-defined even for untagged PNGs.
        let input = CIImage(cgImage: source, options: [.colorSpace: Self.sRGB])
        let filter: CIFilter
        switch method {
        case .cubeWithColorSpace_linearWorking, .cubeWithColorSpace_linearWorking_RGBAf:
            filter = CIFilter(name: "CIColorCubeWithColorSpace")!
            filter.setValue(Self.sRGB, forKey: "inputColorSpace")
        case .cube_sRGBWorking, .cube_sRGBWorking_RGBAf, .cube_linearWorking_naive:
            filter = CIFilter(name: "CIColorCube")!
        }
        filter.setValue(LUTFusion.dimension, forKey: "inputCubeDimension")
        filter.setValue(fusedLUT, forKey: "inputCubeData")
        filter.setValue(input, forKey: kCIInputImageKey)
        return filter.outputImage!
    }

    /// End-to-end apply: build CIImage + filter, render synchronously into an RGBA8 sRGB bitmap.
    /// CIContext.render(_:toBitmap:...) blocks until the GPU work is complete, so the wall time is honest.
    func applyAndRender(source: CGImage, fusedLUT: Data, method: LUTApplicationMethod, into bitmap: RGBX8Image) {
        let output = filteredImage(source: source, fusedLUT: fusedLUT, method: method)
        context(for: method).render(
            output, toBitmap: bitmap.pixels, rowBytes: bitmap.rowBytes,
            bounds: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height),
            format: .RGBA8, colorSpace: Self.sRGB)
    }

    /// Timing: 1 first run + `repeatCount` further runs (median reported), reusing one output bitmap.
    func timeApply(source: CGImage, fusedLUT: Data, method: LUTApplicationMethod, repeatCount: Int = 10) -> [String: Any] {
        let bitmap = RGBX8Image.allocate(width: source.width, height: source.height)
        let (_, firstMilliseconds) = Clock.measureMilliseconds { applyAndRender(source: source, fusedLUT: fusedLUT, method: method, into: bitmap) }
        var repeated: [Double] = []
        for _ in 0..<repeatCount {
            let (_, milliseconds) = Clock.measureMilliseconds { applyAndRender(source: source, fusedLUT: fusedLUT, method: method, into: bitmap) }
            repeated.append(milliseconds)
        }
        var record = Statistics.firstAndMedian(firstRunMilliseconds: firstMilliseconds, repeatedMilliseconds: repeated)
        record["width"] = source.width
        record["height"] = source.height
        return record
    }

    /// Resample (ignoring aspect) to an exact size with Lanczos; used to build preview and synthetic
    /// 12/48 MP inputs. Untimed setup work.
    func resampled(_ source: CGImage, width: Int, height: Int) throws -> CGImage {
        let input = CIImage(cgImage: source, options: [.colorSpace: Self.sRGB])
        let scaleY = Double(height) / Double(source.height)
        let scaleX = Double(width) / Double(source.width)
        let lanczos = CIFilter(name: "CILanczosScaleTransform")!
        lanczos.setValue(input, forKey: kCIInputImageKey)
        lanczos.setValue(scaleY, forKey: kCIInputScaleKey)
        lanczos.setValue(scaleX / scaleY, forKey: kCIInputAspectRatioKey)
        let output = lanczos.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context(for: .cubeWithColorSpace_linearWorking).createCGImage(
            output, from: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: Self.sRGB)
        else { throw BenchError.message("createCGImage failed for \(width)x\(height)") }
        return image
    }
}

enum PixelComparison {
    /// 8-bit RGB comparison (alpha/padding ignored). Fractions count pixels where ANY channel exceeds.
    static func compare(_ lhs: RGBX8Image, _ rhs: RGBX8Image) throws -> [String: Any] {
        guard lhs.width == rhs.width, lhs.height == rhs.height else {
            throw BenchError.message("size mismatch \(lhs.width)x\(lhs.height) vs \(rhs.width)x\(rhs.height)")
        }
        var maxDifference = 0
        var sumDifference = 0
        var pixelsOverOne = 0
        var pixelsOverTwo = 0
        var histogram = [Int](repeating: 0, count: 256)  // per-channel |diff| histogram
        for y in 0..<lhs.height {
            let rowA = lhs.pixels.advanced(by: y * lhs.rowBytes).assumingMemoryBound(to: UInt8.self)
            let rowB = rhs.pixels.advanced(by: y * rhs.rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<lhs.width {
                var pixelMax = 0
                for channel in 0..<3 {
                    let difference = abs(Int(rowA[x * 4 + channel]) - Int(rowB[x * 4 + channel]))
                    sumDifference += difference
                    histogram[difference] += 1
                    pixelMax = max(pixelMax, difference)
                }
                maxDifference = max(maxDifference, pixelMax)
                if pixelMax > 1 { pixelsOverOne += 1 }
                if pixelMax > 2 { pixelsOverTwo += 1 }
            }
        }
        let pixelCount = Double(lhs.width * lhs.height)
        var smallHistogram: [String: Int] = [:]
        for difference in 0..<min(8, histogram.count) where histogram[difference] > 0 { smallHistogram[String(difference)] = histogram[difference] }
        let largeCount = histogram[8...].reduce(0, +)
        if largeCount > 0 { smallHistogram[">=8"] = largeCount }
        return [
            "max_abs_diff": maxDifference,
            "mean_abs_diff": Double(sumDifference) / (pixelCount * 3),
            "frac_gt1": Double(pixelsOverOne) / pixelCount,
            "frac_gt2": Double(pixelsOverTwo) / pixelCount,
            "channel_diff_histogram": smallHistogram,
        ]
    }
}

enum ImageEncoding {
    static func cgImage(from bitmap: RGBX8Image) -> CGImage {
        let context = CGContext(
            data: bitmap.pixels, width: bitmap.width, height: bitmap.height, bitsPerComponent: 8,
            bytesPerRow: bitmap.rowBytes, space: CoreImageLUTApplier.sRGB,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return context.makeImage()!
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw BenchError.message("cannot create PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BenchError.message("PNG finalize failed") }
    }

    /// Single JPEG encode (quality 0.9, sRGB) to memory; returns (bytes, milliseconds).
    static func timeJPEGEncode(_ image: CGImage) throws -> (bytes: Int, milliseconds: Double) {
        let data = NSMutableData()
        let start = Clock.nowSeconds()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw BenchError.message("cannot create JPEG destination")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw BenchError.message("JPEG finalize failed") }
        return (data.length, (Clock.nowSeconds() - start) * 1000)
    }
}

/// CPU reference applications of a 33^3 RGBA LUT, used only to *explain* Core Image's residual
/// differences (diagnostic, untimed). Trilinear reproduces the golden reference.png (exact grid,
/// binsize 1/(dim-1), demo rounding x*255+0.5 truncated); tetrahedral is the other common cube
/// interpolation, to test whether Core Image interpolates tetrahedrally.
enum CPULUTReference {
    enum Interpolation { case trilinear, tetrahedral }

    /// How LUT node values are conditioned before interpolation. The golden interpolates raw nodes and
    /// clamps only the final result; a GPU path that stores the cube in a normalised texture would clamp
    /// (and possibly quantise) the nodes first, which changes results near clipped colours.
    enum NodeConditioning { case raw, clampedToUnit, clampedAndQuantised8Bit }

    static func conditioned(_ lut: [Float], _ conditioning: NodeConditioning) -> [Float] {
        switch conditioning {
        case .raw: return lut
        case .clampedToUnit: return lut.map { min(max($0, 0), 1) }
        case .clampedAndQuantised8Bit: return lut.map { (min(max($0, 0), 1) * 255).rounded() / 255 }
        }
    }

    static func apply(lut rawLUT: [Float], source: RGBX8Image, interpolation: Interpolation, nodes: NodeConditioning = .raw) -> RGBX8Image {
        let dimension = LUTFusion.dimension
        let lut = conditioned(rawLUT, nodes)
        let output = RGBX8Image.allocate(width: source.width, height: source.height)
        lut.withUnsafeBufferPointer { table in
            func entry(_ r: Int, _ g: Int, _ b: Int, _ channel: Int) -> Float {
                table[((b * dimension + g) * dimension + r) * 4 + channel]
            }
            for y in 0..<source.height {
                let inRow = source.pixels.advanced(by: y * source.rowBytes).assumingMemoryBound(to: UInt8.self)
                let outRow = output.pixels.advanced(by: y * output.rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<source.width {
                    // No per-pixel arrays: this loop runs over up to ~13.5 MP twice per image.
                    let cellScale = Float(dimension - 1) / 255
                    let sr = Float(inRow[x * 4]) * cellScale
                    let sg = Float(inRow[x * 4 + 1]) * cellScale
                    let sb = Float(inRow[x * 4 + 2]) * cellScale
                    let r0 = min(Int(sr), dimension - 2), g0 = min(Int(sg), dimension - 2), b0 = min(Int(sb), dimension - 2)
                    let fr = sr - Float(r0), fg = sg - Float(g0), fb = sb - Float(b0)
                    for channel in 0..<3 {
                        let value: Float
                        switch interpolation {
                        case .trilinear:
                            var sum: Float = 0
                            for dr in 0...1 { for dg in 0...1 { for db in 0...1 {
                                let weight = (dr == 1 ? fr : 1 - fr) * (dg == 1 ? fg : 1 - fg) * (db == 1 ? fb : 1 - fb)
                                sum += weight * entry(r0 + dr, g0 + dg, b0 + db, channel)
                            } } }
                            value = sum
                        case .tetrahedral:
                            value = tetrahedral(fr, fg, fb) { dr, dg, db in entry(r0 + dr, g0 + dg, b0 + db, channel) }
                        }
                        outRow[x * 4 + channel] = UInt8(max(0, min(255, value * 255 + 0.5)))
                    }
                    outRow[x * 4 + 3] = 255
                }
            }
        }
        return output
    }

    /// Standard 6-tetrahedra split of the unit cube, ordered by fraction magnitude.
    private static func tetrahedral(_ fr: Float, _ fg: Float, _ fb: Float, _ corner: (Int, Int, Int) -> Float) -> Float {
        let c000 = corner(0, 0, 0), c111 = corner(1, 1, 1)
        if fr >= fg {
            if fg >= fb { return (1 - fr) * c000 + (fr - fg) * corner(1, 0, 0) + (fg - fb) * corner(1, 1, 0) + fb * c111 }
            if fr >= fb { return (1 - fr) * c000 + (fr - fb) * corner(1, 0, 0) + (fb - fg) * corner(1, 0, 1) + fg * c111 }
            return (1 - fb) * c000 + (fb - fr) * corner(0, 0, 1) + (fr - fg) * corner(1, 0, 1) + fg * c111
        }
        if fb >= fg { return (1 - fb) * c000 + (fb - fg) * corner(0, 0, 1) + (fg - fr) * corner(0, 1, 1) + fr * c111 }
        if fb >= fr { return (1 - fg) * c000 + (fg - fb) * corner(0, 1, 0) + (fb - fr) * corner(0, 1, 1) + fr * c111 }
        return (1 - fg) * c000 + (fg - fr) * corner(0, 1, 0) + (fr - fb) * corner(1, 1, 0) + fb * c111
    }
}
