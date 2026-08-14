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

        return DevelopRecipe(
            whiteBalance: .init(
                temperature: whiteBalance.temperature * clamped,
                tint: whiteBalance.tint * clamped
            ),
            exposure: exposure * clamped,
            highlights: highlights * clamped,
            shadows: shadows * clamped,
            contrast: contrast * clamped,
            vibrance: vibrance * clamped,
            clarity: clarity * clamped,
            dehaze: dehaze * clamped,
            sharpening: sharpening * clamped,
            noiseReduction: noiseReduction * clamped
        )
    }

    /// Stacks another recipe on top of this one.
    ///
    /// Used to combine the Develop result with an applied Look. The combination
    /// is additive on each parameter.
    ///
    /// PHASE 3 DEBT: real preset stacking is not purely additive — Lightroom
    /// composes tone curves and HSL in a defined order, and summing two large
    /// contrast values overshoots. This is adequate for the shell because the
    /// starter recipes are deliberately small, and it must be revisited when
    /// the converted library lands.
    func combined(with other: DevelopRecipe) -> DevelopRecipe {
        DevelopRecipe(
            whiteBalance: .init(
                temperature: whiteBalance.temperature + other.whiteBalance.temperature,
                tint: whiteBalance.tint + other.whiteBalance.tint
            ),
            exposure: exposure + other.exposure,
            highlights: highlights + other.highlights,
            shadows: shadows + other.shadows,
            contrast: contrast + other.contrast,
            vibrance: vibrance + other.vibrance,
            clarity: clarity + other.clarity,
            dehaze: dehaze + other.dehaze,
            sharpening: sharpening + other.sharpening,
            noiseReduction: noiseReduction + other.noiseReduction
        )
    }
}
