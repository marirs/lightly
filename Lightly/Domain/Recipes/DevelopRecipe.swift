import Foundation

/// A non-destructive description of how a photograph should be rendered
/// (spec §5).
///
/// The recipe is the only thing Develop produces. It never contains pixels, and
/// applying it never mutates the original — that is what makes the whole edit
/// model reversible (spec §2.6, §27).
///
/// Values are normalised: `0` means "no change" for every adjustment except
/// white balance, which is expressed in Adobe-style temperature/tint units so
/// that converted presets (§6) map onto the same type.
struct DevelopRecipe: Equatable, Codable, Sendable {

    /// White balance shift.
    struct WhiteBalance: Equatable, Codable, Sendable {
        /// Kelvin-style offset. Positive is warmer.
        var temperature: Double
        /// Green/magenta offset. Positive is magenta.
        var tint: Double

        static let neutral = WhiteBalance(temperature: 0, tint: 0)
    }

    var whiteBalance: WhiteBalance
    var exposure: Double
    var highlights: Double
    var shadows: Double
    var contrast: Double
    var vibrance: Double
    var clarity: Double
    var dehaze: Double
    var sharpening: Double
    var noiseReduction: Double

    /// The identity recipe: renders the photograph unchanged.
    static let unmodified = DevelopRecipe(
        whiteBalance: .neutral,
        exposure: 0,
        highlights: 0,
        shadows: 0,
        contrast: 0,
        vibrance: 0,
        clarity: 0,
        dehaze: 0,
        sharpening: 0,
        noiseReduction: 0
    )

    /// Whether this recipe would visibly change the photograph.
    ///
    /// Used to decide whether a developed result is meaningfully different from
    /// the original, which in turn gates whether Compare is worth offering.
    var isIdentity: Bool {
        self == .unmodified
    }
}
