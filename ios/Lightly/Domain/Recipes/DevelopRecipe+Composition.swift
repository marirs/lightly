import Foundation

extension DevelopRecipe {

    /// Scales every adjustment toward the identity recipe.
    ///
    /// Backs the Looks intensity slider. Intensity is kept *separate* from the
    /// Look's stored recipe (spec §7), so this never mutates the preset — the
    /// scaled value is computed at render time and the original recipe survives
    /// intact for the next intensity change.
    ///
    /// - Parameter factor: `0` yields no change, `1` yields the full recipe.
    func scaled(by factor: Double) -> DevelopRecipe {
        let clamped = max(0, min(1, factor))

        // Scale HSL shifts
        let scaledHSL = HSLAdjustments(
            hue: scaleChannelSet(hsl.hue, by: clamped),
            saturation: scaleChannelSet(hsl.saturation, by: clamped),
            luminance: scaleChannelSet(hsl.luminance, by: clamped)
        )

        // Scale Color Grading
        let scaledGrading = ColorGradingAdjustments(
            shadowHue: colorGrading.shadowHue,
            shadowSat: colorGrading.shadowSat * clamped,
            highlightHue: colorGrading.highlightHue,
            highlightSat: colorGrading.highlightSat * clamped,
            balance: colorGrading.balance * clamped
        )

        // Scale Grain & Vignette
        let scaledGrain = GrainAdjustments(
            amount: grain.amount * clamped,
            size: grain.size,
            frequency: grain.frequency
        )

        let scaledVignette = VignetteAdjustments(
            amount: vignette.amount * clamped,
            midpoint: vignette.midpoint
        )

        return DevelopRecipe(
            whiteBalance: .init(
                temperature: whiteBalance.temperature * clamped,
                tint: whiteBalance.tint * clamped
            ),
            exposure: exposure * clamped,
            highlights: highlights * clamped,
            shadows: shadows * clamped,
            whites: whites * clamped,
            blacks: blacks * clamped,
            contrast: contrast * clamped,
            vibrance: vibrance * clamped,
            saturation: saturation * clamped,
            clarity: clarity * clamped,
            dehaze: dehaze * clamped,
            sharpening: sharpening * clamped,
            noiseReduction: noiseReduction * clamped,
            toneCurve: clamped > 0.05 ? toneCurve : [],
            toneCurveRed: clamped > 0.05 ? toneCurveRed : [],
            toneCurveGreen: clamped > 0.05 ? toneCurveGreen : [],
            toneCurveBlue: clamped > 0.05 ? toneCurveBlue : [],
            hsl: scaledHSL,
            colorGrading: scaledGrading,
            grain: scaledGrain,
            vignette: scaledVignette
        )
    }

    /// Stacks another recipe on top of this one.
    ///
    /// Used to combine the Develop result with an applied Look.
    func combined(with other: DevelopRecipe) -> DevelopRecipe {
        let combinedHSL = HSLAdjustments(
            hue: combineChannelSets(hsl.hue, other.hsl.hue),
            saturation: combineChannelSets(hsl.saturation, other.hsl.saturation),
            luminance: combineChannelSets(hsl.luminance, other.hsl.luminance)
        )

        let combinedGrading = other.colorGrading.isIdentity ? colorGrading : other.colorGrading
        let combinedGrain = other.grain.isIdentity ? grain : other.grain
        let combinedVignette = other.vignette.isIdentity ? vignette : other.vignette

        return DevelopRecipe(
            whiteBalance: .init(
                temperature: whiteBalance.temperature + other.whiteBalance.temperature,
                tint: whiteBalance.tint + other.whiteBalance.tint
            ),
            exposure: exposure + other.exposure,
            highlights: highlights + other.highlights,
            shadows: shadows + other.shadows,
            whites: whites + other.whites,
            blacks: blacks + other.blacks,
            contrast: contrast + other.contrast,
            vibrance: vibrance + other.vibrance,
            saturation: saturation + other.saturation,
            clarity: clarity + other.clarity,
            dehaze: dehaze + other.dehaze,
            sharpening: sharpening + other.sharpening,
            noiseReduction: noiseReduction + other.noiseReduction,
            toneCurve: other.toneCurve.isEmpty ? toneCurve : other.toneCurve,
            toneCurveRed: other.toneCurveRed.isEmpty ? toneCurveRed : other.toneCurveRed,
            toneCurveGreen: other.toneCurveGreen.isEmpty ? toneCurveGreen : other.toneCurveGreen,
            toneCurveBlue: other.toneCurveBlue.isEmpty ? toneCurveBlue : other.toneCurveBlue,
            hsl: combinedHSL,
            colorGrading: combinedGrading,
            grain: combinedGrain,
            vignette: combinedVignette
        )
    }

    // MARK: - Helpers

    private func scaleChannelSet(_ set: HSLAdjustments.ChannelSet, by factor: Double) -> HSLAdjustments.ChannelSet {
        HSLAdjustments.ChannelSet(
            red: set.red * factor,
            orange: set.orange * factor,
            yellow: set.yellow * factor,
            green: set.green * factor,
            aqua: set.aqua * factor,
            blue: set.blue * factor,
            purple: set.purple * factor,
            magenta: set.magenta * factor
        )
    }

    private func combineChannelSets(_ a: HSLAdjustments.ChannelSet, _ b: HSLAdjustments.ChannelSet) -> HSLAdjustments.ChannelSet {
        HSLAdjustments.ChannelSet(
            red: a.red + b.red,
            orange: a.orange + b.orange,
            yellow: a.yellow + b.yellow,
            green: a.green + b.green,
            aqua: a.aqua + b.aqua,
            blue: a.blue + b.blue,
            purple: a.purple + b.purple,
            magenta: a.magenta + b.magenta
        )
    }
}
