import Foundation
import simd

/// `effects.selectiveColour` (rendering-v2 revision 4, §6): the kept colours stay, everything else is blended
/// towards its linear luminance by Strength. Matching is by hue in OKLCh, gated by saturation
/// s = C / max(L, 0.05) relative to the pick, symmetric in the ratio. Lightness does not count, so the
/// shadowed parts of a red dress stay red. Colour matching only: it does not know what an object is (picking
/// red keeps red lips too). Reference: shared/look-pack/reference_model.py `apply_selective_colour`.
struct SelectiveColourEvaluator: Sendable {
    /// s = C / max(L, this): near-black pixels have no reliable hue.
    static let minimumLightness = 0.05
    /// A pick less saturated than this keeps only near-neutral pixels.
    static let neutralPick = 0.04

    private let pickSaturation: [Double]
    private let pickHue: [Double]
    private let hueWindow: Double
    private let gateStart: Double
    private let gateFull: Double
    private let outsideColourfulness: Double

    /// Nil when there is nothing to keep: the operator then does nothing.
    init?(_ selective: EditRecipe.Effects.SelectiveColour) {
        guard !selective.colours.isEmpty else { return nil }
        pickSaturation = selective.colours.map { Self.saturation($0.oklab) }
        pickHue = selective.colours.map { Self.hue($0.oklab) }
        hueWindow = 6 + 0.5 * selective.range
        gateStart = 0.65 - 0.0055 * selective.range
        gateFull = gateStart + 0.25
        outsideColourfulness = 1 - selective.strength / 100
    }

    @inline(__always) static func saturation(_ lab: SIMD3<Double>) -> Double { hypot(lab.y, lab.z) / max(lab.x, minimumLightness) }
    @inline(__always) static func hue(_ lab: SIMD3<Double>) -> Double {
        DevelopGlobalProgram.floorMod(atan2(lab.z, lab.y) * 180 / .pi, 360)
    }

    /// The 'stays in colour' weight of a pixel with OKLab `lab`.
    func keep(_ lab: SIMD3<Double>) -> Double {
        let saturation = Self.saturation(lab)
        let hue = Self.hue(lab)
        var keep = 0.0
        for i in pickSaturation.indices {
            let match: Double
            if pickSaturation[i] < Self.neutralPick {
                match = 1 - DevelopGlobalProgram.smoothstep(Self.neutralPick, 2 * Self.neutralPick, saturation)
            } else {
                let hueDistance = abs(DevelopGlobalProgram.floorMod(hue - pickHue[i] + 180, 360) - 180)
                let byHue = min(max((hueWindow - hueDistance) / (0.5 * hueWindow), 0), 1)
                let ratio = saturation / pickSaturation[i]
                // Symmetric: far less saturated (greys, pale skin for a red) and far more saturated (a red sign
                // for a picked skin tone) are both left out.
                match = byHue * DevelopGlobalProgram.smoothstep(gateStart, gateFull, min(ratio, 1 / max(ratio, 1e-6)))
            }
            keep = max(keep, match)
        }
        return keep
    }

    /// sRGB-encoded colour in [0, 1] in and out.
    func apply(_ colour: SIMD3<Float>) -> SIMD3<Float> {
        let linear = DevelopGlobalProgram.srgbToLinear(SIMD3<Double>(colour))
        let keep = keep(DevelopGlobalProgram.linearToOKLab(linear))
        let colourfulness = keep + (1 - keep) * outsideColourfulness
        let luminance = 0.2126 * linear.x + 0.7152 * linear.y + 0.0722 * linear.z
        let out = SIMD3<Double>(repeating: luminance) + (linear - SIMD3<Double>(repeating: luminance)) * colourfulness
        return SIMD3<Float>(DevelopGlobalProgram.linearToSRGB(out))
    }

    /// The kept colour for a tap at (`xFraction`, `yFraction`) of a frame (this stage's input): OKLab of the mean
    /// linear colour over a square of side max(3, round(1 % of the long edge)) px centred on the tapped pixel,
    /// clipped to the frame. `linearAt(x, y)` gives the linear colour of a pixel.
    static func sample(width: Int, height: Int, xFraction: Double, yFraction: Double,
                       linearAt: (Int, Int) -> SIMD3<Double>) -> SIMD3<Double> {
        let side = max(3, Int((0.01 * Double(max(width, height))).rounded()))
        let half = side / 2
        let cx = min(width - 1, max(0, Int(xFraction * Double(width))))
        let cy = min(height - 1, max(0, Int(yFraction * Double(height))))
        var sum = SIMD3<Double>.zero
        var n = 0.0
        for y in max(0, cy - half)...min(height - 1, cy + half) {
            for x in max(0, cx - half)...min(width - 1, cx + half) { sum += linearAt(x, y); n += 1 }
        }
        return DevelopGlobalProgram.linearToOKLab(sum / n)
    }

    /// As `sample` on an RGBA8 sRGB frame.
    static func sample(_ pixels: [UInt8], width: Int, height: Int, xFraction: Double, yFraction: Double) -> SIMD3<Double> {
        sample(width: width, height: height, xFraction: xFraction, yFraction: yFraction) { x, y in
            let o = (y * width + x) * 4
            return DevelopGlobalProgram.srgbToLinear(SIMD3<Double>(Double(pixels[o]), Double(pixels[o + 1]), Double(pixels[o + 2])) / 255)
        }
    }
}
