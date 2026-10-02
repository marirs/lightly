import CoreGraphics
import Foundation

/// Results of analysing a photograph's technical characteristics.
///
/// These measurements drive the Develop engine's recipe (spec §5). Every field
/// is a measurement, not a recommendation — the mapping from analysis to recipe
/// values belongs to `AnalysingDeveloper`, which can apply the spec's "subtle
/// by default" constraint (§2.7) independently of the analyser.
struct ImageAnalysis: Sendable {
    /// Mean luminance across all pixels (0...1). An 18% gray card reads ~0.18.
    let meanLuminance: Float
    /// Fraction of pixels clipped to pure white (0...1).
    let highlightClippingRatio: Float
    /// Fraction of pixels crushed to pure black (0...1).
    let shadowClippingRatio: Float
    /// Estimated color temperature offset from D65 neutral.
    /// Positive = scene is too warm (needs cooling), negative = too cool.
    let colorTemperatureOffset: Double
    /// Estimated green/magenta tint offset.
    /// Positive = too green (needs magenta), negative = too magenta.
    let tintOffset: Double
    /// Standard deviation of the luminance distribution (0...1).
    /// Low values indicate low contrast; high values indicate high contrast.
    let contrastSpread: Float
    /// Estimated noise level from local variance analysis (0...1).
    /// Higher values mean noisier images.
    let noiseLevel: Float
}

/// Analyses a photograph's technical characteristics without altering it.
///
/// Implementations must be stateless and side-effect-free: an analyser looks at
/// the image, measures it, and returns numbers. It never writes pixels, never
/// mutates the source, and never decides what to do about its findings.
protocol ImageAnalysing: Sendable {
    /// Analyses the given image and returns measurements.
    ///
    /// - Parameter image: The source photograph's pixels. Never mutated.
    /// - Returns: Measurements describing the image's technical state.
    /// - Throws: `LightlyError.developFailed` if analysis cannot complete.
    func analyse(_ image: CGImage) async throws -> ImageAnalysis
}
