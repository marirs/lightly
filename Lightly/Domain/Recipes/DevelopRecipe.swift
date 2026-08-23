import Foundation

/// A non-destructive description of how a photograph should be rendered
/// (spec §5, §6.7).
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

    /// 8-channel HSL (Hue, Saturation, Luminance) shifts (spec §6.4).
    struct HSLAdjustments: Equatable, Codable, Sendable {
        struct ChannelSet: Equatable, Codable, Sendable {
            var red: Double = 0
            var orange: Double = 0
            var yellow: Double = 0
            var green: Double = 0
            var aqua: Double = 0
            var blue: Double = 0
            var purple: Double = 0
            var magenta: Double = 0

            static let zero = ChannelSet()

            var isZero: Bool {
                red == 0 && orange == 0 && yellow == 0 && green == 0 &&
                aqua == 0 && blue == 0 && purple == 0 && magenta == 0
            }
        }

        var hue: ChannelSet = .zero
        var saturation: ChannelSet = .zero
        var luminance: ChannelSet = .zero

        static let identity = HSLAdjustments()

        var isIdentity: Bool {
            hue.isZero && saturation.isZero && luminance.isZero
        }
    }

    /// Split toning & three-way color grading (spec §6.4).
    struct ColorGradingAdjustments: Equatable, Codable, Sendable {
        var shadowHue: Double = 0
        var shadowSat: Double = 0
        var highlightHue: Double = 0
        var highlightSat: Double = 0
        var balance: Double = 0

        static let identity = ColorGradingAdjustments()

        var isIdentity: Bool {
            shadowSat == 0 && highlightSat == 0
        }
    }

    /// Film grain simulation (spec §6.4).
    struct GrainAdjustments: Equatable, Codable, Sendable {
        var amount: Double = 0
        var size: Double = 0.25
        var frequency: Double = 0.50

        static let none = GrainAdjustments(amount: 0)

        var isIdentity: Bool {
            amount == 0
        }
    }

    /// Lens vignette simulation.
    struct VignetteAdjustments: Equatable, Codable, Sendable {
        var amount: Double = 0
        var midpoint: Double = 0.50

        static let none = VignetteAdjustments(amount: 0)

        var isIdentity: Bool {
            amount == 0
        }
    }

    // MARK: - Basic Tone & Colour
    var whiteBalance: WhiteBalance = .neutral
    var exposure: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var contrast: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    var clarity: Double = 0
    var dehaze: Double = 0
    var sharpening: Double = 0
    var noiseReduction: Double = 0

    // MARK: - Advanced Looks Parameters
    /// Master RGB tone curve control points (e.g. `["0, 0", "128, 128", "255, 255"]`).
    var toneCurve: [String] = []
    /// Per-channel red tone curve points.
    var toneCurveRed: [String] = []
    /// Per-channel green tone curve points.
    var toneCurveGreen: [String] = []
    /// Per-channel blue tone curve points.
    var toneCurveBlue: [String] = []

    /// 8-channel HSL color shifts.
    var hsl: HSLAdjustments = .identity
    /// Shadow and highlight split toning.
    var colorGrading: ColorGradingAdjustments = .identity
    /// Film grain adjustments.
    var grain: GrainAdjustments = .none
    /// Vignette adjustments.
    var vignette: VignetteAdjustments = .none

    init(
        whiteBalance: WhiteBalance = .neutral,
        exposure: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        whites: Double = 0,
        blacks: Double = 0,
        contrast: Double = 0,
        vibrance: Double = 0,
        saturation: Double = 0,
        clarity: Double = 0,
        dehaze: Double = 0,
        sharpening: Double = 0,
        noiseReduction: Double = 0,
        toneCurve: [String] = [],
        toneCurveRed: [String] = [],
        toneCurveGreen: [String] = [],
        toneCurveBlue: [String] = [],
        hsl: HSLAdjustments = .identity,
        colorGrading: ColorGradingAdjustments = .identity,
        grain: GrainAdjustments = .none,
        vignette: VignetteAdjustments = .none
    ) {
        self.whiteBalance = whiteBalance
        self.exposure = exposure
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.contrast = contrast
        self.vibrance = vibrance
        self.saturation = saturation
        self.clarity = clarity
        self.dehaze = dehaze
        self.sharpening = sharpening
        self.noiseReduction = noiseReduction
        self.toneCurve = toneCurve
        self.toneCurveRed = toneCurveRed
        self.toneCurveGreen = toneCurveGreen
        self.toneCurveBlue = toneCurveBlue
        self.hsl = hsl
        self.colorGrading = colorGrading
        self.grain = grain
        self.vignette = vignette
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case whiteBalance
        case temperature, tint
        case exposure, highlights, shadows, whites, blacks
        case contrast, vibrance, saturation, clarity, dehaze
        case sharpening, noiseReduction
        case toneCurve, toneCurveRed, toneCurveGreen, toneCurveBlue
        case hsl, colorGrading, grain, vignette
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let wb = try? container.decode(WhiteBalance.self, forKey: .whiteBalance) {
            self.whiteBalance = wb
        } else {
            let temp = (try? container.decode(Double.self, forKey: .temperature)) ?? 0
            let tint = (try? container.decode(Double.self, forKey: .tint)) ?? 0
            self.whiteBalance = WhiteBalance(temperature: temp, tint: tint)
        }

        self.exposure = (try? container.decode(Double.self, forKey: .exposure)) ?? 0
        self.highlights = (try? container.decode(Double.self, forKey: .highlights)) ?? 0
        self.shadows = (try? container.decode(Double.self, forKey: .shadows)) ?? 0
        self.whites = (try? container.decode(Double.self, forKey: .whites)) ?? 0
        self.blacks = (try? container.decode(Double.self, forKey: .blacks)) ?? 0
        self.contrast = (try? container.decode(Double.self, forKey: .contrast)) ?? 0
        self.vibrance = (try? container.decode(Double.self, forKey: .vibrance)) ?? 0
        self.saturation = (try? container.decode(Double.self, forKey: .saturation)) ?? 0
        self.clarity = (try? container.decode(Double.self, forKey: .clarity)) ?? 0
        self.dehaze = (try? container.decode(Double.self, forKey: .dehaze)) ?? 0
        self.sharpening = (try? container.decode(Double.self, forKey: .sharpening)) ?? 0
        self.noiseReduction = (try? container.decode(Double.self, forKey: .noiseReduction)) ?? 0

        self.toneCurve = (try? container.decode([String].self, forKey: .toneCurve)) ?? []
        self.toneCurveRed = (try? container.decode([String].self, forKey: .toneCurveRed)) ?? []
        self.toneCurveGreen = (try? container.decode([String].self, forKey: .toneCurveGreen)) ?? []
        self.toneCurveBlue = (try? container.decode([String].self, forKey: .toneCurveBlue)) ?? []

        self.hsl = (try? container.decode(HSLAdjustments.self, forKey: .hsl)) ?? .identity
        self.colorGrading = (try? container.decode(ColorGradingAdjustments.self, forKey: .colorGrading)) ?? .identity
        self.grain = (try? container.decode(GrainAdjustments.self, forKey: .grain)) ?? .none
        self.vignette = (try? container.decode(VignetteAdjustments.self, forKey: .vignette)) ?? .none
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(whiteBalance, forKey: .whiteBalance)
        try container.encode(exposure, forKey: .exposure)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(shadows, forKey: .shadows)
        try container.encode(whites, forKey: .whites)
        try container.encode(blacks, forKey: .blacks)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(vibrance, forKey: .vibrance)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(clarity, forKey: .clarity)
        try container.encode(dehaze, forKey: .dehaze)
        try container.encode(sharpening, forKey: .sharpening)
        try container.encode(noiseReduction, forKey: .noiseReduction)
        try container.encode(toneCurve, forKey: .toneCurve)
        try container.encode(toneCurveRed, forKey: .toneCurveRed)
        try container.encode(toneCurveGreen, forKey: .toneCurveGreen)
        try container.encode(toneCurveBlue, forKey: .toneCurveBlue)
        try container.encode(hsl, forKey: .hsl)
        try container.encode(colorGrading, forKey: .colorGrading)
        try container.encode(grain, forKey: .grain)
        try container.encode(vignette, forKey: .vignette)
    }

    /// The identity recipe: renders the photograph unchanged.
    static let unmodified = DevelopRecipe()

    /// Whether this recipe would visibly change the photograph.
    var isIdentity: Bool {
        self == .unmodified
    }
}
