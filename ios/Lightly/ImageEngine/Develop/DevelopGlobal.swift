import Foundation
import simd

/// Stage `develop.global` of rendering contract v2 for one preset: a port of
/// `shared/look-pack/reference_model.develop_global`, statement for statement, in double precision.
///
/// The recipe is compiled once into the per-recipe terms (calibration matrix, white-balance gains,
/// tone response, curve tables, HSL and grading weights) so that evaluating a colour, and baking a
/// 33³ LUT from it, does only per-pixel work. Where the prose contract and the reference differ in
/// wording, the reference is followed: it is the executable specification the golden vectors
/// (`shared/fixtures/look-pack/golden.json`) were generated from.
struct DevelopGlobalProgram: Sendable {

    // MARK: Constants shared by every recipe

    static let luma = SIMD3<Double>(0.2126, 0.7152, 0.0722)
    static let hslCentresDegrees: [Double] = [29, 55, 105, 142, 195, 264, 300, 328]
    /// OKLab M1 (linear sRGB → LMS) and M2 (LMS^⅓ → Lab), as rows.
    static let oklabM1 = simd_double3x3(rows: [
        SIMD3(0.4122214708, 0.5363325363, 0.0514459929),
        SIMD3(0.2119034982, 0.6806995451, 0.1073969566),
        SIMD3(0.0883024619, 0.2817188376, 0.6299787005)])
    static let oklabM2 = simd_double3x3(rows: [
        SIMD3(0.2104542553, 0.7936177850, -0.0040720468),
        SIMD3(1.9779984951, -2.4285922050, 0.4505937099),
        SIMD3(0.0259040371, 0.7827717662, -0.8086757660)])
    static let oklabM1Inverse = oklabM1.inverse
    static let oklabM2Inverse = oklabM2.inverse

    // MARK: Compiled recipe

    private let calibrationMatrix: simd_double3x3?
    private let whiteBalanceGains: SIMD3<Double>
    private let exposureGain: Double
    private let shadowTintGreenGain: Double
    private let tone: PresetRecipe.ToneSliders
    private let dehazeAmount: Double
    /// 0.1·Σ_rows (A·s + B·s²) for the non-zero sliders: the hat-basis response, 12 knots.
    private let toneHatResponse: [Double]?
    private let veil: Double
    private let parametric: PresetRecipe.ParametricCurve?
    private let curveMaster: ToneCurveTable?
    private let curveRed: ToneCurveTable?
    private let curveGreen: ToneCurveTable?
    private let curveBlue: ToneCurveTable?
    /// Per band: k_hue·hue^·hue_band, k_hsl_sat·sat^·sat_band, k_hsl_lum·lum^·lum_band.
    private let hslHue: SIMD8<Double>?
    private let hslSaturation: SIMD8<Double>?
    private let hslLuminance: SIMD8<Double>?
    private let vibrance: Double
    private let saturation: Double
    private let grading: Grading?
    private let grayscaleMix: SIMD8<Double>?
    private let model: DevelopModel

    private struct Grading: Sendable {
        let balance: Double
        let blend: Double
        /// shadows, midtones, highlights, global: (a gain, b gain, L gain) per zone, or nil when the
        /// zone's saturation and luminance are both zero (the reference skips such zones).
        let zones: [(a: Double, b: Double, l: Double)?]
    }

    // swiftlint:disable:next function_body_length
    init(recipe: PresetRecipe.Global, model: DevelopModel) {
        self.model = model
        if let calibration = recipe.calibration {
            calibrationMatrix = Self.calibrationMatrix(calibration, model: model)
        } else {
            calibrationMatrix = nil
        }
        let t = (recipe.whiteBalance?.temperature ?? 0) * model.kTemp
        let u = (recipe.whiteBalance?.tint ?? 0) * model.kTint
        let gains = SIMD3(exp(t), exp(-u), exp(-t))
        whiteBalanceGains = gains / simd_dot(gains, Self.luma)
        exposureGain = pow(2.0, recipe.exposureEV ?? 0)
        shadowTintGreenGain = exp(-(recipe.shadowTint ?? 0) * model.kShadowTint * 10)

        tone = recipe.toneSliders ?? PresetRecipe.ToneSliders()
        dehazeAmount = recipe.dehaze ?? 0
        let sliders = [tone.contrast, tone.highlights, tone.shadows, tone.whites, tone.blacks, dehazeAmount].map { $0 / 100 }
        var response = [Double](repeating: 0, count: 12)
        var anyResponse = false
        for (row, s) in sliders.enumerated() where s != 0 {
            anyResponse = true
            for j in 0..<12 { response[j] += (model.toneA[row][j] * s + model.toneB[row][j] * s * s) * 0.1 }
        }
        // The reference adds each row's response separately, (basis·rowResponse)·0.1; a single
        // summed vector is the same sum regrouped (well inside the 5e-4 probe tolerance).
        toneHatResponse = anyResponse ? response : nil
        veil = model.kDehaze * dehazeAmount / 100 * model.dehazeAir * 0.05

        parametric = recipe.parametricCurve
        let curves = recipe.toneCurve
        curveMaster = curves?.master.map(ToneCurveTable.init(points:))
        curveRed = curves?.red.map(ToneCurveTable.init(points:))
        curveGreen = curves?.green.map(ToneCurveTable.init(points:))
        curveBlue = curves?.blue.map(ToneCurveTable.init(points:))

        if let hsl = recipe.hsl {
            hslHue = SIMD8((0..<8).map { model.kHue * (hsl.hue[$0] / 100 * model.hueBand[$0]) })
            hslSaturation = SIMD8((0..<8).map { model.kHSLSaturation * (hsl.saturation[$0] / 100 * model.saturationBand[$0]) })
            hslLuminance = SIMD8((0..<8).map { model.kHSLLuminance * (hsl.luminance[$0] / 100 * model.luminanceBand[$0]) })
        } else {
            hslHue = nil; hslSaturation = nil; hslLuminance = nil
        }
        vibrance = recipe.vibranceSaturation?.vibrance ?? 0
        saturation = recipe.vibranceSaturation?.saturation ?? 0

        if let cg = recipe.colourGrading {
            let zones = [cg.shadows, cg.midtones, cg.highlights, cg.global].enumerated().map { index, zone
                -> (a: Double, b: Double, l: Double)? in
                guard zone.saturation != 0 || zone.luminance != 0 else { return nil }
                let angle = (zone.hue + 25) * .pi / 180
                let strength = model.kGrade * model.gradeZone[index] * zone.saturation / 100
                return (strength * cos(angle), strength * sin(angle), model.kGradeLuminance * zone.luminance / 100 * 0.5)
            }
            grading = Grading(balance: cg.balance / 100, blend: 0.15 + 0.35 * cg.blending / 100, zones: zones)
        } else {
            grading = nil
        }
        grayscaleMix = recipe.grayscaleMix.map { SIMD8($0.map { $0 / 100 }) }
    }

    // MARK: Evaluation

    /// develop.global for one sRGB-encoded colour. Output is clamped to [0, 1].
    // swiftlint:disable:next function_body_length
    func evaluate(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        var linear = Self.srgbToLinear(rgb)

        // 1 calibration (clip: rotated primaries can go below zero)
        if let calibrationMatrix {
            linear = simd_max(calibrationMatrix * linear, .zero)
        } else {
            linear = simd_max(linear, .zero)
        }
        // 2 white balance, 3 exposure
        linear = linear * whiteBalanceGains
        linear = linear * exposureGain
        // 4 shadow tint; this luma is reused by step 5
        let luma = max(simd_dot(linear, Self.luma), 1e-6)
        let shadowWeight = 1 - Self.smoothstep(0, 0.25, luma)
        linear.y *= pow(shadowTintGreenGain, shadowWeight)

        // 5 basic tone + dehaze response, applied as a luminance ratio
        let encoded = Self.linearToSRGB(luma)
        var delta = model.kContrast * tone.contrast / 100 * (encoded - 0.5) * 4 * encoded * (1 - encoded)
        let highlightTerm = (encoded - model.centreHighlights) / model.widthHighlights
        delta += model.kHighlights * tone.highlights / 100 * exp(-(highlightTerm * highlightTerm)) * encoded
        let shadowTerm = (encoded - model.centreShadows) / model.widthShadows
        delta += model.kShadows * tone.shadows / 100 * exp(-(shadowTerm * shadowTerm)) * (1 - encoded)
        delta += model.kWhites * tone.whites / 100 * pow(encoded, 4)
        delta += model.kBlacks * tone.blacks / 100 * pow(1 - encoded, 4)
        if let toneHatResponse {
            for j in 0..<12 {
                let hat = max(1 - abs(encoded - Double(j) / 11) * 11, 0)
                if hat > 0 { delta += hat * toneHatResponse[j] }
            }
        }
        linear = Self.applyLuminance(linear, target: Self.srgbToLinear(max(encoded + delta, 0)))
        linear = (linear - veil) / (1 - veil)

        var channels = Self.linearToSRGB(linear)
        // 7 parametric curve (per channel, not clamped)
        if let p = parametric {
            let s1 = p.shadowSplit / 100, s2 = p.midtoneSplit / 100, s3 = p.highlightSplit / 100
            for c in 0..<3 {
                let x = channels[c]
                let regions = p.shadows * Self.bump(x, -s1, s1 * 2) + p.darks * Self.bump(x, s1 - (s2 - s1), s2)
                    + p.lights * Self.bump(x, s2, s3 + (s3 - s2)) + p.highlights * Self.bump(x, s3 - (1 - s3), 1 + (1 - s3))
                channels[c] = x + model.kParametric * regions / 100 * 0.25
            }
        }
        // 8 point curves: master on every channel, then per channel
        if let curveMaster {
            channels = SIMD3(curveMaster.apply(channels.x), curveMaster.apply(channels.y), curveMaster.apply(channels.z))
        }
        if let curveRed { channels.x = curveRed.apply(channels.x) }
        if let curveGreen { channels.y = curveGreen.apply(channels.y) }
        if let curveBlue { channels.z = curveBlue.apply(channels.z) }

        // 9-12 perceptual colour in OKLCh
        let lab = Self.linearToOKLab(Self.srgbToLinear(simd_clamp(channels, .zero, .one)))
        var lightness = lab.x
        var chroma = (lab.y * lab.y + lab.z * lab.z + 1e-9).squareRoot()
        var hue = Self.floorMod(atan2(lab.z, lab.y + 1e-9) * 180 / .pi, 360)
        let band = Self.hslBandWeights(hue)
        let colourful = min(max(chroma / 0.08, 0), 1)
        if let hslHue, let hslSaturation, let hslLuminance {
            hue += (band * hslHue).sum() * colourful
            chroma *= max(1 + (band * hslSaturation).sum(), 0)
            lightness += (band * hslLuminance).sum() * colourful * lightness
        }
        chroma *= max(1 + model.kVibrance * vibrance / 100 * (1 - min(max(chroma / 0.25, 0), 1)), 0)
        chroma *= max(1 + model.kSaturation * saturation / 100, 0)
        let hueRadians = hue * .pi / 180
        var a = chroma * cos(hueRadians)
        var b = chroma * sin(hueRadians)
        if let grading {
            let wHigh = Self.smoothstep(0.5 + 0.25 * grading.balance - grading.blend,
                                        0.5 + 0.25 * grading.balance + grading.blend, lightness)
            let wShadow = 1 - wHigh
            let weights = SIMD4(wShadow, 1 - abs(wShadow - wHigh), wHigh, 1)
            for index in 0..<4 {
                guard let zone = grading.zones[index] else { continue }
                a += zone.a * weights[index]
                b += zone.b * weights[index]
                lightness += zone.l * weights[index]
            }
        }
        if let grayscaleMix {
            lightness *= 1 + 0.3 * (band * grayscaleMix).sum() * colourful
            a = 0
            b = 0
        }
        return simd_clamp(Self.linearToSRGB(Self.okLabToLinear(SIMD3(lightness, a, b))), .zero, .one)
    }

    // MARK: Baking

    /// Samples the stage on an N³ grid (`linspace(0,1,N)` per axis), contract layout `[b][g][r]`
    /// with red fastest, as float32 RGB triples. Slices of constant blue are evaluated in parallel.
    func bakeRGB(dimension: Int) -> [Float] {
        let n = dimension
        let step = 1.0 / Double(n - 1)
        let axis = (0..<n).map { $0 == n - 1 ? 1.0 : Double($0) * step }
        var output = [Float](repeating: 0, count: n * n * n * 3)
        output.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: n) { bIndex in
                var offset = bIndex * n * n * 3
                for gIndex in 0..<n {
                    for rIndex in 0..<n {
                        let value = evaluate(SIMD3(axis[rIndex], axis[gIndex], axis[bIndex]))
                        base[offset] = Float(value.x)
                        base[offset + 1] = Float(value.y)
                        base[offset + 2] = Float(value.z)
                        offset += 3
                    }
                }
            }
        }
        return output
    }

    /// The 33³ bake as a `LUT3D` (RGBA, alpha 1) for the Metal LUT path.
    func bakeLUT(dimension: Int = LUT3D.contractDimension) -> LUT3D {
        let rgb = bakeRGB(dimension: dimension)
        var rgba = [Float](repeating: 1, count: dimension * dimension * dimension * 4)
        for node in 0..<(dimension * dimension * dimension) {
            rgba[node * 4] = rgb[node * 3]
            rgba[node * 4 + 1] = rgb[node * 3 + 1]
            rgba[node * 4 + 2] = rgb[node * 3 + 2]
        }
        // Size is correct by construction.
        return try! LUT3D(dimension: dimension, values: rgba)
    }

    // MARK: Colour helpers (reference_model)

    @inline(__always) static func srgbToLinear(_ e: Double) -> Double {
        e <= 0.04045 ? e / 12.92 : pow((max(e, 0.04045) + 0.055) / 1.055, 2.4)
    }

    @inline(__always) static func srgbToLinear(_ e: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(srgbToLinear(e.x), srgbToLinear(e.y), srgbToLinear(e.z))
    }

    @inline(__always) static func linearToSRGB(_ value: Double) -> Double {
        let l = max(value, 0)
        return l <= 0.0031308 ? l * 12.92 : 1.055 * pow(max(l, 0.0031308), 1 / 2.4) - 0.055
    }

    @inline(__always) static func linearToSRGB(_ l: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(linearToSRGB(l.x), linearToSRGB(l.y), linearToSRGB(l.z))
    }

    /// The 1e-7 floor matches the reference: the cube root's slope is infinite at 0.
    @inline(__always) static func linearToOKLab(_ linear: SIMD3<Double>) -> SIMD3<Double> {
        let lms = simd_max(oklabM1 * linear, SIMD3(repeating: 1e-7))
        let cube = SIMD3(pow(lms.x, 1.0 / 3), pow(lms.y, 1.0 / 3), pow(lms.z, 1.0 / 3))
        return oklabM2 * cube
    }

    @inline(__always) static func okLabToLinear(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let lms = oklabM2Inverse * lab
        return oklabM1Inverse * (lms * lms * lms)
    }

    @inline(__always) static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Python's `%`: the result takes the sign of the divisor.
    @inline(__always) static func floorMod(_ x: Double, _ m: Double) -> Double {
        let r = fmod(x, m)
        return r < 0 ? r + m : r
    }

    @inline(__always) private static func bump(_ x: Double, _ lower: Double, _ upper: Double) -> Double {
        let t = min(max((x - lower) / max(upper - lower, 1e-3), 0), 1)
        let s = sin(Double.pi * t)
        return s * s
    }

    /// Piecewise-linear partition of unity over the 8 HSL bands (circular).
    static func hslBandWeights(_ hue: Double) -> SIMD8<Double> {
        var weights = SIMD8<Double>.zero
        for i in 0..<8 {
            let offset = floorMod(hue - hslCentresDegrees[i] + 180, 360) - 180
            weights[i] = offset < 0
                ? min(max(1 + offset / hslSpansBelow[i], 0), 1)
                : min(max(1 - offset / hslSpansAbove[i], 0), 1)
        }
        return weights / max(weights.sum(), 1e-6)
    }

    /// (centre − previous centre) mod 360 and (next centre − centre) mod 360, per band.
    private static let hslSpansBelow: [Double] = (0..<8).map {
        floorMod(hslCentresDegrees[$0] - hslCentresDegrees[($0 + 7) % 8], 360)
    }
    private static let hslSpansAbove: [Double] = (0..<8).map {
        floorMod(hslCentresDegrees[($0 + 1) % 8] - hslCentresDegrees[$0], 360)
    }

    /// Scale to the target luminance keeping hue; overflow past 1 is filled with neutral.
    @inline(__always) static func applyLuminance(_ linear: SIMD3<Double>, target: Double) -> SIMD3<Double> {
        let luma = max(simd_dot(linear, Self.luma), 1e-6)
        let scaled = linear * (target / luma)
        guard scaled.max() > 1 else { return scaled }
        let peak = linear.max()
        let k = max((1 - target) / max(peak - luma, 1e-9), 0)
        return linear * k + (target - k * luma)
    }

    /// Camera Calibration primaries: rotate each primary toward its neighbour and scale its
    /// saturation; each row then sums to 1 so white stays white.
    static func calibrationMatrix(_ calibration: PresetRecipe.Calibration, model: DevelopModel) -> simd_double3x3 {
        let hues = [calibration.redHue, calibration.greenHue, calibration.blueHue]
        let saturations = [calibration.redSaturation, calibration.greenSaturation, calibration.blueSaturation]
        let eye: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
        var columns: [SIMD3<Double>] = []
        for i in 0..<3 {
            var primary = eye[i]
            let following = eye[(i + 1) % 3], preceding = eye[(i + 2) % 3]
            let hueShift = hues[i] / 100 * model.kCalibrationHue * model.calibrationHue[i]
            primary = primary + max(hueShift, 0) * following + max(-hueShift, 0) * preceding
            let saturationScale = 1 + saturations[i] / 100 * model.kCalibrationSaturation * model.calibrationSaturation[i]
            let grey = SIMD3(repeating: primary.sum() / 3)
            columns.append(grey + saturationScale * (primary - grey))
        }
        // simd matrices are column-major: these are the reference's columns.
        var matrix = simd_double3x3(columns: (columns[0], columns[1], columns[2]))
        // Normalise each ROW by its sum.
        let transposed = matrix.transpose
        let rows = [transposed.columns.0, transposed.columns.1, transposed.columns.2].map { $0 / $0.sum() }
        matrix = simd_double3x3(rows: rows)
        return matrix
    }
}

/// Trilinear lookup in a contract-layout RGB LUT (`reference_model.apply_lut_trilinear`), used by
/// the parity tests and CPU paths.
enum TrilinearLookup {
    static func apply(rgb lut: [Float], dimension n: Int, to colour: SIMD3<Double>) -> SIMD3<Double> {
        let position = simd_clamp(colour, .zero, .one) * Double(n - 1)
        let cell = SIMD3<Int>(
            min(max(Int(position.x.rounded(.down)), 0), n - 2),
            min(max(Int(position.y.rounded(.down)), 0), n - 2),
            min(max(Int(position.z.rounded(.down)), 0), n - 2))
        let f = position - SIMD3(Double(cell.x), Double(cell.y), Double(cell.z))
        var out = SIMD3<Double>.zero
        for db in 0...1 {
            let wb = db == 1 ? f.z : 1 - f.z
            for dg in 0...1 {
                let wg = dg == 1 ? f.y : 1 - f.y
                for dr in 0...1 {
                    let wr = dr == 1 ? f.x : 1 - f.x
                    let index = (((cell.z + db) * n + (cell.y + dg)) * n + (cell.x + dr)) * 3
                    out += SIMD3(Double(lut[index]), Double(lut[index + 1]), Double(lut[index + 2])) * (wb * wg * wr)
                }
            }
        }
        return out
    }
}
