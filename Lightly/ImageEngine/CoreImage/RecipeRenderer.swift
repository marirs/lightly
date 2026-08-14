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
        // An identity recipe must not round-trip through Core Image: doing so
        // would re-encode pixels for no reason and could subtly shift colour.
        guard !recipe.isIdentity else { return image }

        var ciImage = CIImage(cgImage: image)

        ciImage = applyExposure(recipe.exposure, to: ciImage)
        ciImage = applyWhiteBalance(recipe.whiteBalance, to: ciImage)
        ciImage = applyToneAndColour(recipe, to: ciImage)
        ciImage = applyVibrance(recipe.vibrance, to: ciImage)
        ciImage = applySharpening(recipe.sharpening, to: ciImage)

        guard let output = context.createCGImage(ciImage, from: ciImage.extent) else {
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

    private func applySharpening(_ sharpening: Double, to image: CIImage) -> CIImage {
        guard sharpening != 0 else { return image }
        return image.applyingFilter("CISharpenLuminance", parameters: [
            kCIInputSharpnessKey: sharpening
        ])
    }
}
