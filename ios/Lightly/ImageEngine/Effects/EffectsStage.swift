import Foundation
import simd

/// Stage 10, `effects` (rendering-v2 §1, §6): on the frame, after geometry, in the contract order
/// light leak → selective colour → preset vignette → user vignette → preset grain → user grain.
///
/// The user's effects are added on top of the preset's own vignette and grain, never replacing
/// them (the approved "added to it, not replaced" notice). The preset's amounts are scaled by the
/// Develop Amount; the user's are not.
struct EffectsStage: Sendable {
    let leak: LightLeakEvaluator?
    /// After the leak, so a coloured leak does not bring colour back (rendering-v2 revision 4).
    let selectiveColour: SelectiveColourEvaluator?
    let presetVignette: DevelopPixelOperators.VignetteEvaluator?
    let userVignette: DevelopPixelOperators.VignetteEvaluator?
    let presetGrain: DevelopPixelOperators.GrainEvaluator?
    let userGrain: DevelopPixelOperators.GrainEvaluator?

    var isEmpty: Bool { leak == nil && selectiveColour == nil && presetVignette == nil && userVignette == nil && presetGrain == nil && userGrain == nil }

    init(effects: EditRecipe.Effects, presetFinishing: PresetRecipe.Finishing, presetStrength: Double,
         frameWidth: Int, frameHeight: Int, model: DevelopModel) {
        leak = effects.lightLeak.enabled
            ? LightLeakEvaluator(effects.lightLeak, frameWidth: frameWidth, frameHeight: frameHeight) : nil
        selectiveColour = SelectiveColourEvaluator(effects.selectiveColour)
        presetVignette = presetFinishing.vignette.flatMap {
            DevelopPixelOperators.VignetteEvaluator($0, strength: presetStrength, frameWidth: frameWidth, frameHeight: frameHeight, model: model)
        }
        userVignette = effects.vignette.enabled
            ? DevelopPixelOperators.VignetteEvaluator(Self.userVignette(effects.vignette), strength: 1,
                                                      frameWidth: frameWidth, frameHeight: frameHeight, model: model)
            : nil
        presetGrain = presetFinishing.grain.flatMap {
            DevelopPixelOperators.GrainEvaluator($0, strength: presetStrength, frameWidth: frameWidth, frameHeight: frameHeight, model: model)
        }
        userGrain = effects.grain.enabled
            ? DevelopPixelOperators.GrainEvaluator(Self.userGrain(effects.grain), strength: 1,
                                                   frameWidth: frameWidth, frameHeight: frameHeight, model: model)
            : nil
    }

    /// [contract] `userVignette`: amount = −amount, midpoint = size, feather = softness,
    /// roundness 0, style 1 (highlight priority), highlight contrast 0.
    static func userVignette(_ v: EditRecipe.Effects.Vignette) -> PresetRecipe.Vignette {
        PresetRecipe.Vignette(amount: -v.amount, midpoint: v.size, feather: v.softness, roundness: 0, style: 1, highlightContrast: 0)
    }

    /// [contract] `userGrain`: size × 0.7 (fine), 1.0 (film), 1.5 (coarse), capped at 100; the
    /// seed fixed when the edit was created.
    static func userGrain(_ g: EditRecipe.Effects.Grain) -> PresetRecipe.Grain {
        let factor: Double = switch g.style { case .fine: 0.7; case .film: 1.0; case .coarse: 1.5 }
        return PresetRecipe.Grain(amount: g.amount, size: min(g.size * factor, 100), roughness: g.roughness, seed: g.seed)
    }

    /// Applies the stage to an RGBA8 sRGB frame.
    func apply(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard !isEmpty else { return pixels }
        var output = pixels
        output.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    var colour = SIMD3<Float>(Float(base[o]) / 255, Float(base[o + 1]) / 255, Float(base[o + 2]) / 255)
                    if let leak { colour = leak.apply(colour, x: x, y: y) }
                    if let selectiveColour { colour = selectiveColour.apply(colour) }
                    if let presetVignette { colour = presetVignette.apply(colour, x: x, y: y) }
                    if let userVignette { colour = userVignette.apply(colour, x: x, y: y) }
                    if let presetGrain { colour = presetGrain.apply(colour, x: x, y: y) }
                    if let userGrain { colour = userGrain.apply(colour, x: x, y: y) }
                    base[o] = DevelopFrameRenderer.encode8(colour.x)
                    base[o + 1] = DevelopFrameRenderer.encode8(colour.y)
                    base[o + 2] = DevelopFrameRenderer.encode8(colour.z)
                }
            }
        }
        return output
    }
}

/// The light leak (rendering-v2 §6, *provisional*, the prototype's design values): a radial glow
/// centred at (x, y) % of the frame, rotated by `rotation` about the frame centre (the prototype
/// rotates the whole overlay), screen-blended in encoded sRGB as CSS `mix-blend-mode: screen`.
/// The core opacity is intensity/130 and the 30 % ring's intensity/400, fading to 0 at 55 % of the
/// farthest-corner distance R (the CSS `circle at x% y%` gradient ray: the largest distance from the
/// centre to a frame corner, rendering-v2 revision 2, C4); between the stops the colour is
/// interpolated premultiplied, as CSS gradients are. Where the rotated overlay does not cover the
/// frame (rotation ≠ 0), nothing is added.
struct LightLeakEvaluator: Sendable {
    let centre: SIMD2<Double>
    let frameCentre: SIMD2<Double>
    let frameSize: SIMD2<Double>
    /// R: the farthest-corner distance from the leak centre, in frame pixels.
    let farthestCorner: Double
    let cosine: Double, sine: Double
    let coreAlpha: Double, ringAlpha: Double
    let style: EditRecipe.Effects.LightLeak.Style

    static let ringStop = 0.30, endStop = 0.55

    init?(_ leak: EditRecipe.Effects.LightLeak, frameWidth: Int, frameHeight: Int) {
        guard leak.intensity > 0 else { return nil }
        centre = SIMD2(leak.x / 100 * Double(frameWidth), leak.y / 100 * Double(frameHeight))
        frameCentre = SIMD2(Double(frameWidth) / 2, Double(frameHeight) / 2)
        frameSize = SIMD2(Double(frameWidth), Double(frameHeight))
        farthestCorner = Self.farthestCorner(centre: centre, width: Double(frameWidth), height: Double(frameHeight))
        let theta = leak.rotation * .pi / 180
        cosine = cos(theta); sine = sin(theta)
        coreAlpha = min(leak.intensity / 130, 1)
        ringAlpha = min(leak.intensity / 400, 1)
        style = leak.style
    }

    /// The core and ring colours (0…255) per style; prism sweeps the hue around the centre.
    static func colours(_ style: EditRecipe.Effects.LightLeak.Style) -> (SIMD3<Double>, SIMD3<Double>) {
        switch style {
        case .warm: (SIMD3(255, 150, 70), SIMD3(255, 90, 60))
        case .amber: (SIMD3(255, 176, 64), SIMD3(230, 120, 40))
        case .rose: (SIMD3(255, 140, 160), SIMD3(220, 90, 120))
        case .prism: (SIMD3(255, 150, 70), SIMD3(255, 90, 60))
        }
    }

    /// A saturated hue at `degrees` with the warm core's lightness and saturation (prism).
    static func prismColour(degrees: Double) -> SIMD3<Double> {
        // HSL(h, 100 %, 64 %) ≈ the warm core's saturation and lightness.
        let h = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let l = 0.64, s = 1.0
        let c = (1 - abs(2 * l - 1)) * s, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = l - c / 2
        let rgb: SIMD3<Double> = switch Int(h) {
        case 0: SIMD3(c, x, 0)
        case 1: SIMD3(x, c, 0)
        case 2: SIMD3(0, c, x)
        case 3: SIMD3(0, x, c)
        case 4: SIMD3(x, 0, c)
        default: SIMD3(c, 0, x)
        }
        return (rgb + m) * 255
    }

    /// The CSS farthest-corner ray: the largest distance from `centre` to a corner of the frame.
    static func farthestCorner(centre: SIMD2<Double>, width: Double, height: Double) -> Double {
        [SIMD2(0, 0), SIMD2(width, 0), SIMD2(0, height), SIMD2(width, height)]
            .map { corner -> Double in let d = corner - centre; return (d.x * d.x + d.y * d.y).squareRoot() }
            .max() ?? 1
    }

    func apply(_ rgb: SIMD3<Float>, x: Int, y: Int) -> SIMD3<Float> {
        guard let premultiplied = premultiplied(x: x, y: y) else { return rgb }
        // Screen with source alpha: Cb + α·Cs·(1 − Cb).
        let base = SIMD3<Double>(rgb)
        return SIMD3<Float>(base + premultiplied * (SIMD3(repeating: 1) - base))
    }

    /// The overlay's premultiplied colour (0…1) at a pixel centre; nil where nothing is added.
    func premultiplied(x: Int, y: Int) -> SIMD3<Double>? {
        // The overlay is rotated about the frame centre: sample the unrotated gradient.
        let p = SIMD2(Double(x) + 0.5, Double(y) + 0.5) - frameCentre
        let q = SIMD2(cosine * p.x + sine * p.y, -sine * p.x + cosine * p.y) + frameCentre
        // The rotated overlay is the frame's own box: outside it the leak does not reach (C4).
        guard q.x >= 0, q.y >= 0, q.x <= frameSize.x, q.y <= frameSize.y else { return nil }
        let delta = q - centre
        let t = (delta.x * delta.x + delta.y * delta.y).squareRoot() / farthestCorner
        guard t < Self.endStop else { return nil }
        var (core, ring) = Self.colours(style)
        if style == .prism {
            let hue = atan2(delta.y, delta.x) * 180 / .pi
            core = Self.prismColour(degrees: hue)
            ring = Self.prismColour(degrees: hue + 40)
        }
        // Premultiplied colour (0…1) along the gradient.
        let premultiplied: SIMD3<Double>
        if t <= Self.ringStop {
            let f = t / Self.ringStop
            premultiplied = (core / 255 * coreAlpha) * (1 - f) + (ring / 255 * ringAlpha) * f
        } else {
            let f = (t - Self.ringStop) / (Self.endStop - Self.ringStop)
            premultiplied = (ring / 255 * ringAlpha) * (1 - f)
        }
        return premultiplied
    }
}
