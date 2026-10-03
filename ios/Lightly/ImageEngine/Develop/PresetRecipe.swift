import Foundation

/// One preset's recipe from the format-3 pack (`categories[].presets[].recipe`, recipeVersion 1;
/// rendering-v2.md §3): `{global, spatial, finishing}`.
///
/// An operator is present only when it changes pixels, and a present operator carries every one
/// of its parameters. Values keep Lightroom's units; the equations divide by 100 where needed.
/// Reading is strict: an unknown stage, operator or parameter, or a missing parameter, rejects the
/// whole recipe. A preset whose recipe cannot be read is dropped and reported by the loader,
/// never rendered without the part this build does not understand.
struct PresetRecipe: Equatable, Sendable {

    struct Calibration: Equatable, Sendable {
        var redHue = 0.0, redSaturation = 0.0
        var greenHue = 0.0, greenSaturation = 0.0
        var blueHue = 0.0, blueSaturation = 0.0
    }

    struct WhiteBalance: Equatable, Sendable { var temperature = 0.0, tint = 0.0 }

    struct ToneSliders: Equatable, Sendable {
        var contrast = 0.0, highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0
    }

    struct ParametricCurve: Equatable, Sendable {
        var shadows = 0.0, darks = 0.0, lights = 0.0, highlights = 0.0
        var shadowSplit = 25.0, midtoneSplit = 50.0, highlightSplit = 75.0
    }

    /// Point curves, `[[x, y], …]` in 0…255. nil (or empty) = identity for that channel.
    struct ToneCurve: Equatable, Sendable {
        var master: [[Double]]?
        var red: [[Double]]?
        var green: [[Double]]?
        var blue: [[Double]]?
    }

    /// Eight bands, red … magenta.
    struct HSL: Equatable, Sendable {
        var hue: [Double]
        var saturation: [Double]
        var luminance: [Double]
    }

    struct VibranceSaturation: Equatable, Sendable { var vibrance = 0.0, saturation = 0.0 }

    struct ColourGrading: Equatable, Sendable {
        struct Zone: Equatable, Sendable { var hue = 0.0, saturation = 0.0, luminance = 0.0 }
        var shadows = Zone(), midtones = Zone(), highlights = Zone(), global = Zone()
        var balance = 0.0, blending = 50.0
    }

    struct Global: Equatable, Sendable {
        var calibration: Calibration?
        var whiteBalance: WhiteBalance?
        var exposureEV: Double?
        var shadowTint: Double?
        var toneSliders: ToneSliders?
        var dehaze: Double?
        var parametricCurve: ParametricCurve?
        var toneCurve: ToneCurve?
        var hsl: HSL?
        var vibranceSaturation: VibranceSaturation?
        var colourGrading: ColourGrading?
        /// Grayscale mix, eight bands.
        var grayscaleMix: [Double]?
    }

    struct NoiseReduction: Equatable, Sendable {
        var luminance = 0.0, luminanceDetail = 50.0, luminanceContrast = 0.0
        var color = 0.0, colorDetail = 50.0, colorSmoothness = 50.0
    }

    struct Sharpening: Equatable, Sendable { var amount = 0.0, radius = 1.0, detail = 25.0, edgeMasking = 0.0 }

    struct Spatial: Equatable, Sendable {
        var noiseReduction: NoiseReduction?
        var clarity: Double?
        var texture: Double?
        var sharpening: Sharpening?

        var isEmpty: Bool { noiseReduction == nil && clarity == nil && texture == nil && sharpening == nil }
    }

    struct Vignette: Equatable, Sendable {
        var amount = 0.0, midpoint = 50.0, feather = 50.0, roundness = 0.0
        /// 1 highlight priority, 2 colour priority, 3 paint overlay.
        var style = 1
        var highlightContrast = 0.0
    }

    struct Grain: Equatable, Sendable {
        var amount = 0.0, size = 25.0, roughness = 50.0
        var seed: UInt32 = 0
    }

    struct Finishing: Equatable, Sendable {
        var vignette: Vignette?
        var grain: Grain?

        var isEmpty: Bool { vignette == nil && grain == nil }
    }

    var global = Global()
    var spatial = Spatial()
    var finishing = Finishing()

    /// A recipe that changes nothing (no operators at all).
    static let neutral = PresetRecipe()
}

// MARK: - Reading

extension PresetRecipe {

    struct ReadError: Error, Equatable, CustomStringConvertible {
        let path: String
        let problem: String
        var description: String { "\(path): \(problem)" }
    }

    /// Reads a recipe from a `JSONSerialization` object (the pack manifest is parsed that way for
    /// speed: it holds 2,591 recipes).
    init(json: Any) throws {
        let root = try Self.object(json, "recipe")
        try Self.only(["global", "spatial", "finishing"], in: root, "recipe")
        self.init()
        if let global = root["global"] { self.global = try Self.readGlobal(Self.object(global, "global")) }
        if let spatial = root["spatial"] { self.spatial = try Self.readSpatial(Self.object(spatial, "spatial")) }
        if let finishing = root["finishing"] { self.finishing = try Self.readFinishing(Self.object(finishing, "finishing")) }
    }

    private static func readGlobal(_ g: [String: Any]) throws -> Global {
        try only(["calibration", "whiteBalance", "exposure", "shadowTint", "toneSliders", "dehaze", "parametricCurve",
                  "toneCurve", "hsl", "vibranceSaturation", "colorGrading", "grayscale"], in: g, "global")
        var out = Global()
        if let v = g["calibration"] {
            let o = try operatorObject(v, "calibration",
                                       ["redHue", "redSaturation", "greenHue", "greenSaturation", "blueHue", "blueSaturation"])
            out.calibration = Calibration(
                redHue: try number(o, "redHue"), redSaturation: try number(o, "redSaturation"),
                greenHue: try number(o, "greenHue"), greenSaturation: try number(o, "greenSaturation"),
                blueHue: try number(o, "blueHue"), blueSaturation: try number(o, "blueSaturation"))
        }
        if let v = g["whiteBalance"] {
            let o = try operatorObject(v, "whiteBalance", ["temperature", "tint"])
            out.whiteBalance = WhiteBalance(temperature: try number(o, "temperature"), tint: try number(o, "tint"))
        }
        if let v = g["exposure"] { out.exposureEV = try number(operatorObject(v, "exposure", ["ev"]), "ev") }
        if let v = g["shadowTint"] { out.shadowTint = try number(operatorObject(v, "shadowTint", ["amount"]), "amount") }
        if let v = g["toneSliders"] {
            let o = try operatorObject(v, "toneSliders", ["contrast", "highlights", "shadows", "whites", "blacks"])
            out.toneSliders = ToneSliders(
                contrast: try number(o, "contrast"), highlights: try number(o, "highlights"), shadows: try number(o, "shadows"),
                whites: try number(o, "whites"), blacks: try number(o, "blacks"))
        }
        if let v = g["dehaze"] { out.dehaze = try number(operatorObject(v, "dehaze", ["amount"]), "amount") }
        if let v = g["parametricCurve"] {
            let o = try operatorObject(v, "parametricCurve",
                                       ["shadows", "darks", "lights", "highlights", "shadowSplit", "midtoneSplit", "highlightSplit"])
            out.parametricCurve = ParametricCurve(
                shadows: try number(o, "shadows"), darks: try number(o, "darks"), lights: try number(o, "lights"),
                highlights: try number(o, "highlights"), shadowSplit: try number(o, "shadowSplit"),
                midtoneSplit: try number(o, "midtoneSplit"), highlightSplit: try number(o, "highlightSplit"))
        }
        if let v = g["toneCurve"] {
            let o = try object(v, "toneCurve")
            try only(["master", "red", "green", "blue"], in: o, "toneCurve")
            out.toneCurve = ToneCurve(
                master: try curve(o["master"], "toneCurve.master"), red: try curve(o["red"], "toneCurve.red"),
                green: try curve(o["green"], "toneCurve.green"), blue: try curve(o["blue"], "toneCurve.blue"))
        }
        if let v = g["hsl"] {
            let o = try operatorObject(v, "hsl", ["hue", "saturation", "luminance"])
            out.hsl = HSL(hue: try bands(o["hue"], "hsl.hue"), saturation: try bands(o["saturation"], "hsl.saturation"),
                          luminance: try bands(o["luminance"], "hsl.luminance"))
        }
        if let v = g["vibranceSaturation"] {
            let o = try operatorObject(v, "vibranceSaturation", ["vibrance", "saturation"])
            out.vibranceSaturation = VibranceSaturation(vibrance: try number(o, "vibrance"), saturation: try number(o, "saturation"))
        }
        if let v = g["colorGrading"] {
            let o = try operatorObject(v, "colorGrading", ["shadows", "midtones", "highlights", "global", "balance", "blending"])
            func zone(_ key: String) throws -> ColourGrading.Zone {
                let z = try operatorObject(o[key] as Any, "colorGrading.\(key)", ["hue", "saturation", "luminance"])
                return ColourGrading.Zone(hue: try number(z, "hue"), saturation: try number(z, "saturation"), luminance: try number(z, "luminance"))
            }
            out.colourGrading = ColourGrading(
                shadows: try zone("shadows"), midtones: try zone("midtones"), highlights: try zone("highlights"),
                global: try zone("global"), balance: try number(o, "balance"), blending: try number(o, "blending"))
        }
        if let v = g["grayscale"] {
            out.grayscaleMix = try bands(operatorObject(v, "grayscale", ["mix"])["mix"], "grayscale.mix")
        }
        return out
    }

    private static func readSpatial(_ s: [String: Any]) throws -> Spatial {
        try only(["noiseReduction", "clarity", "texture", "sharpening"], in: s, "spatial")
        var out = Spatial()
        if let v = s["noiseReduction"] {
            let o = try operatorObject(v, "noiseReduction",
                                       ["luminance", "luminanceDetail", "luminanceContrast", "color", "colorDetail", "colorSmoothness"])
            out.noiseReduction = NoiseReduction(
                luminance: try number(o, "luminance"), luminanceDetail: try number(o, "luminanceDetail"),
                luminanceContrast: try number(o, "luminanceContrast"), color: try number(o, "color"),
                colorDetail: try number(o, "colorDetail"), colorSmoothness: try number(o, "colorSmoothness"))
        }
        if let v = s["clarity"] { out.clarity = try number(operatorObject(v, "clarity", ["amount"]), "amount") }
        if let v = s["texture"] { out.texture = try number(operatorObject(v, "texture", ["amount"]), "amount") }
        if let v = s["sharpening"] {
            let o = try operatorObject(v, "sharpening", ["amount", "radius", "detail", "edgeMasking"])
            out.sharpening = Sharpening(amount: try number(o, "amount"), radius: try number(o, "radius"),
                                        detail: try number(o, "detail"), edgeMasking: try number(o, "edgeMasking"))
        }
        return out
    }

    private static func readFinishing(_ f: [String: Any]) throws -> Finishing {
        try only(["vignette", "grain"], in: f, "finishing")
        var out = Finishing()
        if let v = f["vignette"] {
            let o = try operatorObject(v, "vignette", ["amount", "midpoint", "feather", "roundness", "style", "highlightContrast"])
            let style = try number(o, "style")
            guard [1.0, 2.0, 3.0].contains(style) else { throw ReadError(path: "vignette.style", problem: "must be 1, 2 or 3") }
            out.vignette = Vignette(amount: try number(o, "amount"), midpoint: try number(o, "midpoint"),
                                    feather: try number(o, "feather"), roundness: try number(o, "roundness"),
                                    style: Int(style), highlightContrast: try number(o, "highlightContrast"))
        }
        if let v = f["grain"] {
            let o = try operatorObject(v, "grain", ["amount", "size", "roughness", "seed"])
            let seed = try number(o, "seed")
            guard seed >= 0, seed <= Double(UInt32.max), seed == seed.rounded() else {
                throw ReadError(path: "grain.seed", problem: "must be a uint32")
            }
            out.grain = Grain(amount: try number(o, "amount"), size: try number(o, "size"),
                              roughness: try number(o, "roughness"), seed: UInt32(seed))
        }
        return out
    }

    // MARK: Helpers

    private static func object(_ value: Any, _ path: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else { throw ReadError(path: path, problem: "not an object") }
        return object
    }

    /// An operator object with exactly `keys` (every parameter written, nothing unknown).
    private static func operatorObject(_ value: Any, _ path: String, _ keys: Set<String>) throws -> [String: Any] {
        let o = try object(value, path)
        guard Set(o.keys) == keys else {
            throw ReadError(path: path, problem: "expected keys \(keys.sorted()), found \(o.keys.sorted())")
        }
        return o
    }

    private static func only(_ allowed: Set<String>, in object: [String: Any], _ path: String) throws {
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else { throw ReadError(path: path, problem: "unknown keys \(unknown.sorted())") }
    }

    private static func number(_ object: [String: Any], _ key: String) throws -> Double {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            throw ReadError(path: key, problem: "not a finite number")
        }
        return number.doubleValue
    }

    private static func bands(_ value: Any?, _ path: String) throws -> [Double] {
        guard let array = value as? [NSNumber], array.count == 8 else { throw ReadError(path: path, problem: "needs 8 numbers") }
        return array.map(\.doubleValue)
    }

    /// nil or an empty list = identity. Points must be sorted with unique x in 0…255 (the
    /// generator normalises them as Lightroom reads them).
    private static func curve(_ value: Any?, _ path: String) throws -> [[Double]]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let points = value as? [[NSNumber]] else { throw ReadError(path: path, problem: "not a point list") }
        if points.isEmpty { return nil }
        let pairs = points.map { $0.map(\.doubleValue) }
        guard pairs.count >= 2, pairs.allSatisfy({ $0.count == 2 }) else {
            throw ReadError(path: path, problem: "needs at least 2 [x, y] points")
        }
        for (previous, next) in zip(pairs, pairs.dropFirst()) where next[0] <= previous[0] {
            throw ReadError(path: path, problem: "x must increase")
        }
        return pairs
    }
}
