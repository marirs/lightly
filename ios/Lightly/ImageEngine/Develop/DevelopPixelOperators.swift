import Foundation
import simd

/// The Develop spatial stage (rendering-v2 §5: noise reduction → clarity → texture → sharpening)
/// and the preset's finishing operators evaluated in the Effects stage (§6: vignette → grain), on
/// the CPU in float32, ported from `reference_model.py`.
///
/// None of these operators has a golden vector yet (the contract publishes tolerances only for
/// develop.global), and the constants are calibrated-not-validated (clarity, texture) or
/// provisional/experimental (noise reduction, sharpening, vignette, grain). Two deliberate
/// approximations, both allowed by §5 ("a port may approximate large Gaussians") and both recorded
/// in docs/v1/slice2-ios.md:
/// 1. **Clarity's large Gaussian** (σ = 5.4 % of the long edge) is computed on a fixed 256 px
///    proxy of the developed photo and sampled back bilinearly. Because the proxy size does not
///    depend on the output size, preview and export get the same clarity.
/// 2. **One OKLab conversion for the whole spatial stage.** The reference converts back to sRGB
///    (clipping to [0, 1]) between operators; here L is clamped to [0, 1] after each operator, as
///    the reference does, and the colour is converted back once. The results differ only where an
///    intermediate colour leaves the sRGB gamut.
enum DevelopPixelOperators {

    /// Pixels the spatial stage reads beyond a tile edge, for a long edge in pixels: three sigma
    /// of the widest small-kernel operator (noise reduction's colour blur at full smoothness).
    static func haloPixels(for spatial: PresetRecipe.Spatial, longEdge: Int, model: DevelopModel) -> Int {
        let scale = Double(longEdge) / model.referenceLongEdgePx
        var sigma = 0.3
        if let nr = spatial.noiseReduction {
            sigma = max(sigma, model.noiseLumaRadiusPx * scale, model.noiseColourRadiusPx * scale * (0.5 + nr.colorSmoothness / 100))
        }
        if spatial.texture != nil { sigma = max(sigma, model.radiusTexture * Double(longEdge)) }
        if let sharpening = spatial.sharpening { sigma = max(sigma, sharpening.radius * scale) }
        // Sharpening's edge mask differentiates a blurred plane: one more pixel.
        return Int((3 * sigma).rounded(.up)) + 3
    }

    // MARK: - Planes

    /// One region of the frame in OKLab, planar float32.
    struct LabRegion {
        let width: Int
        let height: Int
        var lightness: [Float]
        var a: [Float]
        var b: [Float]
    }

    static func toLab(rgb: UnsafeBufferPointer<SIMD4<Float>>, width: Int, height: Int) -> LabRegion {
        var region = LabRegion(width: width, height: height,
                               lightness: [Float](repeating: 0, count: width * height),
                               a: [Float](repeating: 0, count: width * height),
                               b: [Float](repeating: 0, count: width * height))
        region.lightness.withUnsafeMutableBufferPointer { l in
            region.a.withUnsafeMutableBufferPointer { ap in
                region.b.withUnsafeMutableBufferPointer { bp in
                    let lBase = l.baseAddress!, aBase = ap.baseAddress!, bBase = bp.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: height) { row in
                        for column in 0..<width {
                            let index = row * width + column
                            let pixel = rgb[index]
                            let lab = ColourMath.oklab(fromEncoded: SIMD3(pixel.x, pixel.y, pixel.z))
                            lBase[index] = lab.x; aBase[index] = lab.y; bBase[index] = lab.z
                        }
                    }
                }
            }
        }
        return region
    }

    // MARK: - Gaussian blur (reference: separable, reflect padding, truncated at 3σ)

    /// `reference_model.gaussian_blur`. `frameLongEdge` sets the radius cap (half the frame's long
    /// edge) so a tile and the whole frame use the same kernel.
    static func gaussianBlur(_ plane: [Float], width: Int, height: Int, sigma requested: Double, frameLongEdge: Int) -> [Float] {
        let sigma = max(requested, 0.3)
        let radius = Int(min(max(3, (3 * sigma).rounded(.up)), Double(max(frameLongEdge / 2 - 1, 1))))
        var kernel = (-radius...radius).map { Float(exp(-0.5 * pow(Double($0) / sigma, 2))) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var horizontal = [Float](repeating: 0, count: plane.count)
        var output = [Float](repeating: 0, count: plane.count)
        plane.withUnsafeBufferPointer { source in
            horizontal.withUnsafeMutableBufferPointer { destination in
                let src = source.baseAddress!, dst = destination.baseAddress!
                DispatchQueue.concurrentPerform(iterations: height) { row in
                    let rowStart = row * width
                    for column in 0..<width {
                        var sum: Float = 0
                        for tap in -radius...radius {
                            sum += kernel[tap + radius] * src[rowStart + reflect(column + tap, width)]
                        }
                        dst[rowStart + column] = sum
                    }
                }
            }
        }
        horizontal.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                let src = source.baseAddress!, dst = destination.baseAddress!
                DispatchQueue.concurrentPerform(iterations: height) { row in
                    for column in 0..<width {
                        var sum: Float = 0
                        for tap in -radius...radius {
                            sum += kernel[tap + radius] * src[reflect(row + tap, height) * width + column]
                        }
                        dst[row * width + column] = sum
                    }
                }
            }
        }
        return output
    }

    /// numpy `pad(mode="reflect")`: mirrored about the edge sample, without repeating it.
    @inline(__always)
    static func reflect(_ index: Int, _ count: Int) -> Int {
        guard count > 1 else { return 0 }
        var i = index
        let period = 2 * (count - 1)
        i %= period
        if i < 0 { i += period }
        return i < count ? i : period - i
    }

    // MARK: - S1 noise reduction (provisional)

    static func noiseReduction(_ region: inout LabRegion, _ params: PresetRecipe.NoiseReduction, frameLongEdge: Int,
                               model: DevelopModel) {
        let scale = Double(frameLongEdge) / model.referenceLongEdgePx
        if params.luminance != 0 {
            let smooth = gaussianBlur(region.lightness, width: region.width, height: region.height,
                                      sigma: model.noiseLumaRadiusPx * scale, frameLongEdge: frameLongEdge)
            let detailEdge = Float(model.noiseDetailScale * (1.01 - params.luminanceDetail / 100))
            let gain = Float(params.luminance / 100 * (1 - 0.5 * params.luminanceContrast / 100))
            for i in region.lightness.indices {
                let l = region.lightness[i]
                let keep = ColourMath.smoothstep(0, detailEdge, abs(l - smooth[i]))
                region.lightness[i] = l + (smooth[i] - l) * gain * (1 - keep)
            }
            clampLightness(&region)
        }
        if params.color != 0 {
            let radius = model.noiseColourRadiusPx * scale * (0.5 + params.colorSmoothness / 100)
            let weight = Float(params.color / 100)
            let blurredA = gaussianBlur(region.a, width: region.width, height: region.height, sigma: radius, frameLongEdge: frameLongEdge)
            let blurredB = gaussianBlur(region.b, width: region.width, height: region.height, sigma: radius, frameLongEdge: frameLongEdge)
            for i in region.a.indices {
                region.a[i] += (blurredA[i] - region.a[i]) * weight
                region.b[i] += (blurredB[i] - region.b[i]) * weight
            }
        }
    }

    // MARK: - S2 clarity and texture (calibrated, not validated)

    /// `largeBlur`: the clarity Gaussian of L for this region, sampled from the frame proxy.
    static func clarityAndTexture(_ region: inout LabRegion, clarity: Double, texture: Double, largeBlur: [Float]?,
                                  frameLongEdge: Int, model: DevelopModel) {
        let original = region.lightness
        var out = original
        if clarity != 0, let largeBlur {
            let k = Float(model.kClarity * clarity / 100)
            for i in out.indices {
                let l = original[i]
                out[i] += k * 4 * l * (1 - l) * (l - largeBlur[i])
            }
        }
        if texture != 0 {
            let blurred = gaussianBlur(original, width: region.width, height: region.height,
                                       sigma: model.radiusTexture * Double(frameLongEdge), frameLongEdge: frameLongEdge)
            let k = Float(model.kTexture * texture / 100)
            for i in out.indices { out[i] += k * (original[i] - blurred[i]) }
        }
        region.lightness = out
        clampLightness(&region)
    }

    // MARK: - S3 sharpening (provisional)

    static func sharpening(_ region: inout LabRegion, _ params: PresetRecipe.Sharpening, frameLongEdge: Int, model: DevelopModel) {
        guard params.amount != 0 else { return }
        let ratio = Double(frameLongEdge) / model.referenceLongEdgePx
        let blurred = gaussianBlur(region.lightness, width: region.width, height: region.height,
                                   sigma: params.radius * ratio, frameLongEdge: frameLongEdge)
        let threshold = Float((1 - params.detail / 100) * model.sharpenDetailThreshold)
        var detail = zip(region.lightness, blurred).map { l, s -> Float in
            let d = l - s
            return d * abs(d) / (abs(d) + threshold + 1e-12)
        }
        if params.edgeMasking != 0 {
            let width = region.width, height = region.height
            let edgeLimit = Float(params.edgeMasking / 100 * model.sharpenEdgeScale)
            for row in 0..<height {
                for column in 0..<width {
                    let gx = gradient(blurred, index: column, count: width) { row * width + $0 }
                    let gy = gradient(blurred, index: row, count: height) { $0 * width + column }
                    let edge = (gx * gx + gy * gy).squareRoot() * Float(ratio)
                    detail[row * width + column] *= ColourMath.smoothstep(0, edgeLimit, edge)
                }
            }
        }
        let k = Float(model.kSharpen * params.amount / 100)
        for i in region.lightness.indices { region.lightness[i] += k * detail[i] }
        clampLightness(&region)
    }

    /// `np.gradient` along one axis: central differences inside, one-sided at the ends.
    @inline(__always)
    private static func gradient(_ plane: [Float], index: Int, count: Int, at position: (Int) -> Int) -> Float {
        guard count > 1 else { return 0 }
        if index == 0 { return plane[position(1)] - plane[position(0)] }
        if index == count - 1 { return plane[position(count - 1)] - plane[position(count - 2)] }
        return (plane[position(index + 1)] - plane[position(index - 1)]) / 2
    }

    private static func clampLightness(_ region: inout LabRegion) {
        for i in region.lightness.indices { region.lightness[i] = min(max(region.lightness[i], 0), 1) }
    }

    // MARK: - Finishing: F1 vignette and F2 grain (experimental, uncalibrated)

    /// Per-pixel vignette at frame pixel (x, y) of a W × H frame (`reference_model.apply_vignette`).
    struct VignetteEvaluator: Sendable {
        let params: PresetRecipe.Vignette
        let amount: Double
        let frameWidth: Int
        let frameHeight: Int
        let k: Double

        init?(_ params: PresetRecipe.Vignette, strength: Double, frameWidth: Int, frameHeight: Int, model: DevelopModel) {
            amount = params.amount / 100 * strength
            guard amount != 0 else { return nil }
            self.params = params
            self.frameWidth = frameWidth
            self.frameHeight = frameHeight
            k = model.vignetteK
        }

        func apply(_ rgb: SIMD3<Float>, x: Int, y: Int) -> SIMD3<Float> {
            var px = frameWidth > 1 ? -1 + 2 * Double(x) / Double(frameWidth - 1) : 0
            let py = frameHeight > 1 ? -1 + 2 * Double(y) / Double(frameHeight - 1) : 0
            let roundness = params.roundness / 100
            if roundness > 0 { px *= 1 + roundness * (Double(frameWidth) / Double(frameHeight) - 1) }
            let power = 2 + max(0, -roundness) * 6
            let radius = pow(pow(abs(px), power) + pow(abs(py), power), 1 / power) / pow(2, 1 / power)
            let centre = 0.25 + 0.65 * params.midpoint / 100
            let width = 0.05 + 0.6 * params.feather / 100
            let t = ColourMath.smoothstep(centre - width / 2, centre + width / 2, radius)
            switch params.style {
            case 3:
                let target: Float = amount < 0 ? 0 : 1
                let weight = Float(min(max(abs(amount) * k * t, 0), 1))
                return simdClamp(rgb * (1 - weight) + SIMD3(repeating: target * weight))
            case 2:
                let gain = 1 + k * amount * t
                var lab = ColourMath.oklab(fromEncoded: rgb)
                lab.x = min(max(lab.x * Float(pow(max(gain, 0), 1.0 / 3)), 0), 1)
                return ColourMath.encoded(fromOKLab: lab)
            default:
                var gain = 1 + k * amount * t
                let linear = ColourMath.linear(fromEncoded: rgb)
                let highlightContrast = params.highlightContrast / 100
                if amount < 0, highlightContrast != 0 {
                    let luma = Double(min(max(ColourMath.luma(linear), 0), 1))
                    gain = 1 + (gain - 1) * (1 - highlightContrast * ColourMath.smoothstep(0.35, 0.9, luma))
                }
                return simdClamp(ColourMath.encoded(fromLinear: linear * Float(max(gain, 0))))
            }
        }
    }

    /// Per-pixel grain for a W × H frame (`reference_model.apply_grain`, portable random field).
    ///
    /// v3 differs from v2 on purpose (rendering-v2 revision 1, contract fixes 1 §3):
    /// - the lightness change keeps chromaticity: OKLab (L', a·L'/L, b·L'/L), so grain no longer
    ///   colours skin (fixed a, b made darkened cells more saturated);
    /// - with fewer than 2 frame pixels per grain cell, the noise is evaluated at s = ceil(2·cells /
    ///   longEdge) times the size and box-averaged over s × s, as the reference does.
    struct GrainEvaluator: Sendable {
        let amount: Double
        let roughness: Double
        let frameWidth: Int
        let frameHeight: Int
        let grainK: Double
        let supersampling: Int
        let fine: (field: [Double], rows: Int, cols: Int)
        let coarse: (field: [Double], rows: Int, cols: Int)

        init?(_ params: PresetRecipe.Grain, strength: Double, frameWidth: Int, frameHeight: Int, model: DevelopModel) {
            let scaledAmount = params.amount / 100 * strength
            guard scaledAmount != 0 else { return nil }
            self.init(seed: params.seed, size: params.size, roughness: params.roughness, amount: scaledAmount,
                      frameWidth: frameWidth, frameHeight: frameHeight, grainK: model.grainK,
                      referenceLongEdge: model.grainReferenceLongEdge)
        }

        init(seed: UInt32, size sizePercent: Double, roughness roughnessPercent: Double, amount: Double,
             frameWidth: Int, frameHeight: Int, grainK: Double, referenceLongEdge: Double) {
            self.amount = amount
            self.frameWidth = frameWidth
            self.frameHeight = frameHeight
            roughness = roughnessPercent / 100
            self.grainK = grainK
            let size = sizePercent / 100
            let longEdge = Double(max(frameWidth, frameHeight))
            let cellsLong = max(8, Int((referenceLongEdge / (1 + 4 * size)).rounded(.toNearestOrEven)))
            let rows = max(2, Int((Double(cellsLong) * Double(frameHeight) / longEdge).rounded(.toNearestOrEven)))
            let cols = max(2, Int((Double(cellsLong) * Double(frameWidth) / longEdge).rounded(.toNearestOrEven)))
            supersampling = max(1, Int((2 * Double(cellsLong) / longEdge).rounded(.up)))
            fine = (PortableRandom.gaussianField(seed: seed, layer: 0, rows: rows, cols: cols), rows, cols)
            let coarseRows = max(2, rows / 3), coarseCols = max(2, cols / 3)
            coarse = (PortableRandom.gaussianField(seed: seed, layer: 1, rows: coarseRows, cols: coarseCols), coarseRows, coarseCols)
        }

        /// Half-pixel-centre bilinear sample of a field at pixel (x, y) of an outW × outH grid.
        private func sample(_ grid: (field: [Double], rows: Int, cols: Int), x: Int, y: Int, outW: Int, outH: Int) -> Double {
            func axis(_ out: Int, _ inCount: Int, _ position: Int) -> (Int, Int, Double) {
                let source = min(max((Double(position) + 0.5) * Double(inCount) / Double(out) - 0.5, 0), Double(inCount - 1))
                let lower = Int(source.rounded(.down))
                return (lower, min(lower + 1, inCount - 1), source - Double(lower))
            }
            let (y0, y1, fy) = axis(outH, grid.rows, y)
            let (x0, x1, fx) = axis(outW, grid.cols, x)
            let top = grid.field[y0 * grid.cols + x0] * (1 - fx) + grid.field[y0 * grid.cols + x1] * fx
            let bottom = grid.field[y1 * grid.cols + x0] * (1 - fx) + grid.field[y1 * grid.cols + x1] * fx
            return top * (1 - fy) + bottom * fy
        }

        /// The unit grain field n at frame pixel (x, y) (`reference_model.grain_noise`).
        func noise(x: Int, y: Int) -> Double {
            let s = supersampling
            let outW = frameWidth * s, outH = frameHeight * s
            let norm = ((1 - roughness) * (1 - roughness) + roughness * roughness).squareRoot()
            var total = 0.0
            for sy in 0..<s {
                for sx in 0..<s {
                    let px = x * s + sx, py = y * s + sy
                    let fineValue = sample(fine, x: px, y: py, outW: outW, outH: outH) / (2.0 / 3)
                    let coarseValue = sample(coarse, x: px, y: py, outW: outW, outH: outH) / (2.0 / 3)
                    total += ((1 - roughness) * fineValue + roughness * coarseValue) / norm
                }
            }
            return total / Double(s * s)
        }

        func apply(_ rgb: SIMD3<Float>, x: Int, y: Int) -> SIMD3<Float> {
            let n = noise(x: x, y: y)
            var lab = ColourMath.oklab(fromEncoded: rgb)
            let l = Double(lab.x)
            let target = min(max(l + grainK * amount * n * (4 * l * (1 - l) + 0.2), 0), 1)
            let ratio = Float(target / max(l, 1e-6))
            lab = SIMD3(Float(target), lab.y * ratio, lab.z * ratio)
            return ColourMath.encoded(fromOKLab: lab)
        }
    }

    @inline(__always)
    static func simdClamp(_ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(min(max(v.x, 0), 1), min(max(v.y, 0), 1), min(max(v.z, 0), 1))
    }
}

/// Float32 colour helpers for the pixel stages (the same equations as `DevelopGlobalProgram`).
enum ColourMath {
    private static let m1 = DevelopGlobalProgram.oklabM1
    private static let m2 = DevelopGlobalProgram.oklabM2
    private static let m1Inverse = DevelopGlobalProgram.oklabM1Inverse
    private static let m2Inverse = DevelopGlobalProgram.oklabM2Inverse

    @inline(__always) static func linear(fromEncoded e: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(toLinear(e.x), toLinear(e.y), toLinear(e.z))
    }

    @inline(__always) static func toLinear(_ e: Float) -> Float {
        e <= 0.04045 ? e / 12.92 : powf((max(e, 0.04045) + 0.055) / 1.055, 2.4)
    }

    @inline(__always) static func toEncoded(_ value: Float) -> Float {
        let l = max(value, 0)
        return l <= 0.0031308 ? l * 12.92 : 1.055 * powf(max(l, 0.0031308), 1 / 2.4) - 0.055
    }

    @inline(__always) static func encoded(fromLinear l: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(toEncoded(l.x), toEncoded(l.y), toEncoded(l.z))
    }

    @inline(__always) static func luma(_ linear: SIMD3<Float>) -> Float {
        0.2126 * linear.x + 0.7152 * linear.y + 0.0722 * linear.z
    }

    @inline(__always) static func oklab(fromEncoded e: SIMD3<Float>) -> SIMD3<Float> {
        let linear = SIMD3<Double>(linear(fromEncoded: DevelopPixelOperators.simdClamp(e)))
        let lms = simd_max(m1 * linear, SIMD3(repeating: 1e-7))
        return SIMD3<Float>(m2 * SIMD3(cbrt(lms.x), cbrt(lms.y), cbrt(lms.z)))
    }

    /// OKLab → encoded sRGB, clamped to [0, 1].
    @inline(__always) static func encoded(fromOKLab lab: SIMD3<Float>) -> SIMD3<Float> {
        let lms = m2Inverse * SIMD3<Double>(lab)
        let linear = SIMD3<Float>(m1Inverse * (lms * lms * lms))
        return DevelopPixelOperators.simdClamp(encoded(fromLinear: linear))
    }

    @inline(__always) static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    @inline(__always) static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
