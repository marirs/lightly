import Foundation

/// The production implementation of the Develop engine.
///
/// Unlike the debug engine, this genuinely analyses the photograph and builds
/// an adaptive recipe based on its technical characteristics (spec §5). It
/// applies the "subtle by default" constraint (spec §2.7) independently of
/// the analyser, which simply provides raw measurements.
///
/// Progress is reported per stage as that stage's work genuinely completes
/// (spec §4.4), without fabricated delays.
struct AnalysingDeveloper: PhotoDeveloping {

    /// The stateless analyser used to measure the photograph's characteristics.
    let analyser: ImageAnalysing

    let implementationKind: DevelopImplementationKind = .production

    /// The engine performs all stages based on real analysis.
    let performedStages: [DevelopStage] = DevelopStage.allCases

    init(analyser: ImageAnalysing) {
        self.analyser = analyser
    }

    func develop(
        _ photo: SelectedPhoto,
        onStageCompleted: @escaping @Sendable (DevelopStage) -> Void
    ) async throws -> DevelopRecipe {
        // Spec §5: Analyse the photograph's technical characteristics
        let analysis = try await analyser.analyse(photo.image)
        try Task.checkCancellation()

        var recipe = DevelopRecipe.unmodified

        // 1. White Balance
        recipe.whiteBalance.temperature = clamp(-analysis.colorTemperatureOffset * 0.6, min: -300, max: 300)
        recipe.whiteBalance.tint = clamp(-analysis.tintOffset * 0.6, min: -20, max: 20)
        onStageCompleted(.whiteBalance)
        try Task.checkCancellation()

        // 2. Exposure
        let lum = Double(analysis.meanLuminance)
        if lum < 0.35 {
            recipe.exposure = min(0.5, (0.42 - lum) * 2.5)
        } else if lum > 0.55 {
            recipe.exposure = max(-0.3, (0.42 - lum) * 2.0)
        } else {
            recipe.exposure = 0
        }
        onStageCompleted(.exposure)
        try Task.checkCancellation()

        // 3. Highlights
        let hc = Double(analysis.highlightClippingRatio)
        if hc > 0.02 {
            recipe.highlights = -min(0.6, hc * 10.0)
        } else {
            recipe.highlights = 0
        }
        onStageCompleted(.highlights)
        try Task.checkCancellation()

        // 4. Shadows
        let sc = Double(analysis.shadowClippingRatio)
        if sc > 0.03 {
            recipe.shadows = min(0.4, sc * 8.0)
        } else {
            recipe.shadows = 0
        }
        onStageCompleted(.shadows)
        try Task.checkCancellation()

        // 5. Colour (Vibrance)
        let cs = Double(analysis.contrastSpread)
        if cs > 0.28 {
            recipe.vibrance = 0.03
        } else {
            recipe.vibrance = 0.08
        }
        onStageCompleted(.colour)
        try Task.checkCancellation()

        // 6. Detail (Sharpening & Noise Reduction)
        let nl = Double(analysis.noiseLevel)
        if nl > 0.3 {
            recipe.sharpening = 0.03
        } else {
            recipe.sharpening = 0.08
        }

        if nl > 0.15 {
            recipe.noiseReduction = min(0.20, nl * 0.5)
        } else {
            recipe.noiseReduction = 0
        }
        onStageCompleted(.detail)
        try Task.checkCancellation()

        // 7. Clarity (Contrast, Clarity, Dehaze)
        if cs < 0.15 {
            recipe.contrast = min(0.10, (0.15 - cs) * 0.5)
        } else if cs > 0.30 {
            recipe.contrast = 0
        } else {
            recipe.contrast = 0.03
        }

        if nl > 0.3 {
            recipe.clarity = 0
        } else {
            recipe.clarity = 0.05
        }

        if cs < 0.12 && lum > 0.45 {
            recipe.dehaze = 0.04
        } else {
            recipe.dehaze = 0
        }
        onStageCompleted(.clarity)

        return recipe
    }

    private func clamp(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        return Swift.max(minValue, Swift.min(maxValue, value))
    }
}
