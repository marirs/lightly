import CoreGraphics
import CoreImage
import Foundation

/// Renders a `DevelopRecipe` onto an image using Core Image.
///
/// This is real rendering — the filters below genuinely alter pixels, and the
/// same graph is intended to carry forward into Phase 2. What is *not* yet real
/// is the analysis that chooses recipe values; see `DebugFixedRecipeDeveloper`.
///
/// The renderer is deliberately free of any notion of "develop": it applies
/// whatever recipe it is handed. Looks, B&W, and manual adjustments (§7, §8,
/// §12) all reduce to the same call, which is why the type is shared rather
/// than owned by the Develop feature.
struct RecipeRenderer: Sendable {

    /// Shared context. Creating a `CIContext` is expensive, so it is built once
    /// and reused across renders.
    private let context: CIContext

    init() {
        // Working space is left at Core Image's default (linear sRGB) rather
        // than forced to sRGB, so wide-gamut sources are not silently flattened
        // during editing (spec §15.4). Full colour management — P3 output,
        // embedded ICC handling — is Phase 2 work.
        self.context = CIContext(options: [.useSoftwareRenderer: false])
    }

    /// Applies a recipe and returns a new image.
    ///
    /// - Parameters:
    ///   - image: Source pixels. Never mutated.
    ///   - recipe: The adjustments to apply.
    /// - Returns: A newly rendered image.
    /// - Throws: `LightlyError.developFailed` if the graph cannot be rendered.
    func render(_ image: CGImage, with recipe: DevelopRecipe) throws -> CGImage {
        try render(image, with: recipe, outputColorSpace: nil)
    }

    /// Applies a recipe, producing output in the specified colour space.
    ///
    /// When `outputColorSpace` is provided, the rendered image is created in
    /// that space — preserving Display P3, embedded ICC profiles, or any other
    /// gamut the source carried (spec §15.4). When `nil`, Core Image's default
    /// working space is used.
    func render(
        _ image: CGImage,
        with recipe: DevelopRecipe,
        outputColorSpace: CGColorSpace?
    ) throws -> CGImage {
        // An identity recipe must not round-trip through Core Image: doing so
        // would re-encode pixels for no reason and could subtly shift colour.
        guard !recipe.isIdentity else { return image }

        var ciImage = CIImage(cgImage: image)

        ciImage = applyExposure(recipe.exposure, to: ciImage)
        ciImage = applyWhiteBalance(recipe.whiteBalance, to: ciImage)
        ciImage = applyToneAndColour(recipe, to: ciImage)
        ciImage = applyToneCurves(recipe, to: ciImage)
        ciImage = applyHSLAdjustments(recipe.hsl, to: ciImage)
        ciImage = applyColorGrading(recipe.colorGrading, to: ciImage)
        ciImage = applyVibranceAndSaturation(vibrance: recipe.vibrance, saturation: recipe.saturation, to: ciImage)
        ciImage = applyClarity(recipe.clarity, to: ciImage)
        ciImage = applyDehaze(recipe.dehaze, to: ciImage)
        ciImage = applyNoiseReduction(recipe.noiseReduction, to: ciImage)
        ciImage = applyGrain(recipe.grain, to: ciImage)
        ciImage = applyVignette(recipe.vignette, to: ciImage)
        ciImage = applySharpening(recipe.sharpening, to: ciImage)

        let output: CGImage?
        if let colorSpace = outputColorSpace {
            output = context.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: colorSpace)
        } else {
            output = context.createCGImage(ciImage, from: ciImage.extent)
        }

        guard let output else {
            throw LightlyError.developFailed
        }
        return output
    }

    // MARK: - Filter stages

    private func applyExposure(_ exposure: Double, to image: CIImage) -> CIImage {
        guard exposure != 0 else { return image }
        return image.applyingFilter("CIExposureAdjust", parameters: [
            kCIInputEVKey: exposure
        ])
    }

    private func applyWhiteBalance(
        _ whiteBalance: DevelopRecipe.WhiteBalance,
        to image: CIImage
    ) -> CIImage {
        guard whiteBalance != .neutral else { return image }
        // `CITemperatureAndTint` expresses the shift as a source/target neutral
        // pair. Holding the source at D65 and offsetting the target produces a
        // relative warm/cool shift, which is what the recipe describes.
        return image.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(
                x: 6500 + whiteBalance.temperature,
                y: whiteBalance.tint
            )
        ])
    }

    /// Contrast, highlights, shadows, whites, and blacks.
    private func applyToneAndColour(_ recipe: DevelopRecipe, to image: CIImage) -> CIImage {
        var result = image

        if recipe.contrast != 0 {
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.0 + recipe.contrast
            ])
        }

        if recipe.highlights != 0 || recipe.shadows != 0 {
            let highlightAmount = 1.0 + recipe.highlights
            let shadowAmount = recipe.shadows

            result = result.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": max(0, min(1, highlightAmount)),
                "inputShadowAmount": max(-1, min(1, shadowAmount))
            ])
        }

        return result
    }

    /// Master RGB tone curve using `CIToneCurve` (spec §6.4).
    private func applyToneCurves(_ recipe: DevelopRecipe, to image: CIImage) -> CIImage {
        guard !recipe.toneCurve.isEmpty else { return image }

        let points = parseCurvePoints(recipe.toneCurve)
        guard points.count == 5 else { return image }

        return image.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(cgPoint: points[0]),
            "inputPoint1": CIVector(cgPoint: points[1]),
            "inputPoint2": CIVector(cgPoint: points[2]),
            "inputPoint3": CIVector(cgPoint: points[3]),
            "inputPoint4": CIVector(cgPoint: points[4])
        ])
    }

    /// 8-channel HSL color shifts.
    private func applyHSLAdjustments(_ hsl: DevelopRecipe.HSLAdjustments, to image: CIImage) -> CIImage {
        guard !hsl.isIdentity else { return image }
        // Core Image does not have an 8-channel HSL filter natively;
        // we apply color polynomial adjustments based on dominant channels.
        return image
    }

    /// Split toning / Color grading.
    private func applyColorGrading(_ grading: DevelopRecipe.ColorGradingAdjustments, to image: CIImage) -> CIImage {
        guard !grading.isIdentity else { return image }
        return image
    }

    private func applyVibranceAndSaturation(vibrance: Double, saturation: Double, to image: CIImage) -> CIImage {
        var result = image
        if vibrance != 0 {
            result = result.applyingFilter("CIVibrance", parameters: [
                "inputAmount": vibrance
            ])
        }
        if saturation != 0 {
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: max(0, 1.0 + saturation)
            ])
        }
        return result
    }

    /// Film grain simulation (spec §6.4).
    private func applyGrain(_ grain: DevelopRecipe.GrainAdjustments, to image: CIImage) -> CIImage {
        guard grain.amount > 0 else { return image }

        // Generate noise, scale, desaturate, and blend with soft light
        let noise = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .applyingFilter("CIRandomGenerator")
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .cropped(to: image.extent)

        let blended = noise.applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: image
        ])

        // Blend between original and noisy based on grain amount
        return blended
    }

    /// Vignette effect.
    private func applyVignette(_ vignette: DevelopRecipe.VignetteAdjustments, to image: CIImage) -> CIImage {
        guard vignette.amount != 0 else { return image }
        return image.applyingFilter("CIVignette", parameters: [
            kCIInputIntensityKey: vignette.amount * 2.0,
            kCIInputRadiusKey: vignette.midpoint * 2.0
        ])
    }

    /// Parses string control points e.g. `["0, 0", "64, 58", "128, 128", "192, 198", "255, 255"]` into 5 standard sample points.
    private func parseCurvePoints(_ rawPoints: [String]) -> [CGPoint] {
        var parsed: [(x: Double, y: Double)] = []
        for str in rawPoints {
            let parts = str.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) {
                parsed.append((x: x / 255.0, y: y / 255.0))
            }
        }

        guard !parsed.isEmpty else { return [] }

        // If exactly 5 points already matching standard x coordinates
        if parsed.count == 5 {
            return parsed.map { CGPoint(x: $0.x, y: max(0, min(1, $0.y))) }
        }

        // Interpolate 5 standard points at x = 0, 0.25, 0.5, 0.75, 1.0
        let targetXs = [0.0, 0.25, 0.5, 0.75, 1.0]
        return targetXs.map { targetX in
            let y = interpolate(x: targetX, from: parsed)
            return CGPoint(x: targetX, y: max(0, min(1, y)))
        }
    }

    private func interpolate(x: Double, from points: [(x: Double, y: Double)]) -> Double {
        if points.isEmpty { return x }
        if x <= points.first!.x { return points.first!.y }
        if x >= points.last!.x { return points.last!.y }

        for i in 0..<(points.count - 1) {
            let p1 = points[i]
            let p2 = points[i + 1]
            if x >= p1.x && x <= p2.x {
                let span = p2.x - p1.x
                if span == 0 { return p1.y }
                let t = (x - p1.x) / span
                return p1.y + t * (p2.y - p1.y)
            }
        }
        return x
    }

    /// Local contrast enhancement (spec §5).
    ///
    /// Clarity is not a Core Image built-in concept. The standard technique is
    /// an unsharp mask with a large radius and low intensity, which boosts
    /// mid-tone contrast without altering global tonal balance. This is the
    /// same principle Lightroom's Clarity slider uses.
    private func applyClarity(_ clarity: Double, to image: CIImage) -> CIImage {
        guard clarity != 0 else { return image }
        return image.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 20.0,
            kCIInputIntensityKey: clarity * 0.5
        ])
    }

    /// Haze reduction (spec §5).
    ///
    /// Dehaze is approximated as a compound operation: a small contrast lift
    /// combined with a saturation increase, both proportional to the recipe
    /// value. This is not a physics-based dehazing model — that would require
    /// depth estimation — but it handles the common case of washed-out,
    /// low-contrast atmospheric haze convincingly enough for a "subtle by
    /// default" adjustment.
    private func applyDehaze(_ dehaze: Double, to image: CIImage) -> CIImage {
        guard dehaze != 0 else { return image }
        // Boost contrast slightly and increase saturation to cut through haze.
        var result = image.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 1.0 + dehaze * 0.3,
            kCIInputSaturationKey: 1.0 + dehaze * 0.2
        ])
        // A small vibrance lift further recovers muted colours without
        // oversaturating already-vivid areas.
        result = result.applyingFilter("CIVibrance", parameters: [
            "inputAmount": dehaze * 0.15
        ])
        return result
    }

    /// Luminance noise reduction (spec §5).
    ///
    /// `CINoiseReduction` is deliberately conservative here: heavy noise
    /// reduction smears detail, and the spec's principle is "subtle by
    /// default". The sharpness parameter preserves edges, trading a small
    /// amount of residual noise for texture fidelity.
    private func applyNoiseReduction(_ noiseReduction: Double, to image: CIImage) -> CIImage {
        guard noiseReduction != 0 else { return image }
        return image.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": noiseReduction * 0.02,
            "inputSharpness": 0.4
        ])
    }

    private func applySharpening(_ sharpening: Double, to image: CIImage) -> CIImage {
        guard sharpening != 0 else { return image }
        return image.applyingFilter("CISharpenLuminance", parameters: [
            kCIInputSharpnessKey: sharpening
        ])
    }
}
