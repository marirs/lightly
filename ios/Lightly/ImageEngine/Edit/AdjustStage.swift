import Foundation

/// Stage 5, `edit.adjust` (rendering-v2 §7 and rendering-v2.json `edit.adjust`, provisional
/// mapping): the Adjust sliders mapped onto the calibrated Develop model.
///
/// - Colour (`adjustColour`): `develop.global` with exposure.ev = exposure/50; contrast, highlights,
///   shadows; white balance temperature = temp, tint = tint; saturation and vibrance; every other
///   operator neutral. Baked to a 33³ LUT exactly like a preset.
/// - Detail (`adjustDetail`): `develop.spatial` with noise reduction luminance = colour = noise
///   (other parameters at their defaults), clarity = clarity, sharpening amount = sharpness with
///   radius 1.0, detail 25, edge masking 0.
enum AdjustStage {

    static func hasColour(_ a: EditRecipe.Adjust) -> Bool {
        [a.exposure, a.contrast, a.highlights, a.shadows, a.temp, a.tint, a.saturation, a.vibrance].contains { $0 != 0 }
    }

    static func hasDetail(_ a: EditRecipe.Adjust) -> Bool { a.sharpness != 0 || a.clarity != 0 || a.noise != 0 }

    /// The Develop global recipe the colour sliders map to.
    static func colourRecipe(_ a: EditRecipe.Adjust) -> PresetRecipe.Global {
        var global = PresetRecipe.Global()
        if a.exposure != 0 { global.exposureEV = a.exposure / 50 }
        if a.contrast != 0 || a.highlights != 0 || a.shadows != 0 {
            global.toneSliders = .init(contrast: a.contrast, highlights: a.highlights, shadows: a.shadows, whites: 0, blacks: 0)
        }
        if a.temp != 0 || a.tint != 0 { global.whiteBalance = .init(temperature: a.temp, tint: a.tint) }
        if a.saturation != 0 || a.vibrance != 0 { global.vibranceSaturation = .init(vibrance: a.vibrance, saturation: a.saturation) }
        return global
    }

    /// The spatial operators the Detail sliders map to (empty when all are zero).
    static func detailSpatial(_ a: EditRecipe.Adjust) -> PresetRecipe.Spatial {
        var spatial = PresetRecipe.Spatial()
        if a.noise != 0 {
            spatial.noiseReduction = .init(luminance: a.noise, luminanceDetail: 50, luminanceContrast: 0,
                                           color: a.noise, colorDetail: 50, colorSmoothness: 50)
        }
        if a.clarity != 0 { spatial.clarity = a.clarity }
        if a.sharpness != 0 { spatial.sharpening = .init(amount: a.sharpness, radius: 1.0, detail: 25, edgeMasking: 0) }
        return spatial
    }

    private static let cache = LUTCache()

    /// The colour LUT for these sliders (nil when neutral), cached by value: a slider drag asks for
    /// the same few values many times.
    static func colourLUT(_ a: EditRecipe.Adjust, model: DevelopModel) -> LUT3D? {
        guard hasColour(a) else { return nil }
        let key = [a.exposure, a.contrast, a.highlights, a.shadows, a.temp, a.tint, a.saturation, a.vibrance]
        if let hit = cache.get(key) { return hit }
        let lut = DevelopGlobalProgram(recipe: colourRecipe(a), model: model).bakeLUT()
        cache.put(key, lut)
        return lut
    }

    /// A small most-recently-used cache of baked Adjust LUTs (one bake is a few milliseconds).
    private final class LUTCache: @unchecked Sendable {
        // @unchecked: every access holds `lock`.
        private let lock = NSLock()
        private var entries: [(key: [Double], lut: LUT3D)] = []

        func get(_ key: [Double]) -> LUT3D? {
            lock.withLock { entries.first { $0.key == key }?.lut }
        }

        func put(_ key: [Double], _ lut: LUT3D) {
            lock.withLock {
                entries.removeAll { $0.key == key }
                entries.insert((key, lut), at: 0)
                if entries.count > 16 { entries.removeLast() }
            }
        }
    }
}
