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
        ciImage = applyVibrance(recipe.vibrance, to: ciImage)
        ciImage = applyClarity(recipe.clarity, to: ciImage)
        ciImage = applyDehaze(recipe.dehaze, to: ciImage)
        ciImage = applyNoiseReduction(recipe.noiseReduction, to: ciImage)
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

    /// Contrast, highlight recovery, and shadow lift.
    ///
    /// Highlights and shadows are handled by `CIHighlightShadowAdjust`, whose
    /// parameters run 0...1 with different neutral points than the recipe's
    /// signed values — hence the remapping rather than a direct pass-through.
    private func applyToneAndColour(_ recipe: DevelopRecipe, to image: CIImage) -> CIImage {
        var result = image

        if recipe.contrast != 0 {
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1.0 + recipe.contrast
            ])
        }

        if recipe.highlights != 0 || recipe.shadows != 0 {
            // Recipe highlights are negative to *recover* detail; the filter
            // treats 1.0 as untouched and lower values as recovery.
            let highlightAmount = 1.0 + recipe.highlights
            // Recipe shadows are positive to *lift*; the filter takes 0 as
            // untouched.
            let shadowAmount = recipe.shadows

            result = result.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": max(0, min(1, highlightAmount)),
                "inputShadowAmount": max(-1, min(1, shadowAmount))
            ])
        }

        return result
    }

    private func applyVibrance(_ vibrance: Double, to image: CIImage) -> CIImage {
        guard vibrance != 0 else { return image }
        return image.applyingFilter("CIVibrance", parameters: [
            "inputAmount": vibrance
        ])
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
