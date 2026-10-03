import Foundation

/// How this iOS port renders each Develop operator of a recipe, beyond what the pack itself
/// records (`approximated`, `unsupported`, `notApplied`). Used for the review evidence
/// (docs/v1/slice2-ios.md) and the DevelopCoverage log; never shown in the UI.
enum DevelopCoverage {

    /// Port-level notes for the operators a recipe uses. Global-stage operators are exact ports of
    /// `reference_model.develop_global` (parity within the golden tolerances), so they add nothing.
    static func portApproximations(for recipe: PresetRecipe) -> [String] {
        var notes: [String] = []
        if recipe.spatial.clarity != nil {
            notes.append("clarity: large Gaussian on a 256 px proxy of the developed photo, sampled back bilinearly")
        }
        if !recipe.spatial.isEmpty {
            notes.append("spatial: one OKLab conversion for the whole spatial stage (reference re-encodes and clips between operators)")
        }
        if recipe.spatial.noiseReduction != nil || recipe.spatial.texture != nil || recipe.spatial.sharpening != nil {
            notes.append("noise reduction / texture / sharpening: direct separable Gaussians as in the reference, float32")
        }
        if recipe.finishing.vignette != nil || recipe.finishing.grain != nil {
            notes.append("finishing (vignette, grain): evaluated after the spatial stage on the uncropped frame (slice 2 has no geometry)")
        }
        return notes
    }
}
