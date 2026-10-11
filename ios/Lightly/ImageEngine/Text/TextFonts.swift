import CoreText
import Foundation
import OSLog

/// The eleven Text-tool fonts (owner amendments 2026-10-11; shared/fonts): Inter, Playfair Display, Bebas Neue, Caveat,
/// Cormorant Garamond, Montserrat, Dancing Script and Space Mono (SIL OFL 1.1), then Retro Romance, Velomino and
/// Vectipede Thin (owner-supplied, each with its licence file). Bundled as resources and read by URL, as
/// `WatermarkFonts` reads the watermark fonts, so nothing depends on font registration or on a system font of the same
/// name.
///
/// Each layer draws at its `weight` (rendering-v2 §7.4): Thin 200, Regular 400, Bold 700 on the variable fonts' `wght`
/// axis (CoreText clamps a value outside a font's axis range to its nearest end, as browsers do for a variable
/// `@font-face`); a single-weight font always draws its one weight.
enum TextFonts {
    private static let log = Logger(subsystem: "com.lightlylabs.lightly", category: "text-fonts")

    /// OpenType 'wght' as a CoreText variation axis identifier.
    private static let weightAxisTag = 0x7767_6874
    /// "Regular weight" in §7.4.
    static let regularWeight = EditRecipe.TextLayer.Weight.regular.axisValue

    /// The bundled file for each font (name and extension) and whether it is a variable font with a `wght` axis.
    static func file(for font: EditRecipe.TextLayer.Font) -> (name: String, fileExtension: String, variable: Bool) {
        switch font {
        case .inter: ("Inter-Variable", "ttf", true)
        case .playfairDisplay: ("PlayfairDisplay-Variable", "ttf", true)
        case .bebasNeue: ("BebasNeue-Regular", "ttf", false)
        case .caveat: ("Caveat-Variable", "ttf", true)
        case .cormorantGaramond: ("CormorantGaramond-Variable", "ttf", true)
        case .montserrat: ("Montserrat-Variable", "ttf", true)
        case .dancingScript: ("DancingScript-Variable", "ttf", true)
        case .spaceMono: ("SpaceMono-Regular", "ttf", false)
        case .retroRomance: ("RetroRomance-Regular", "otf", false)
        case .velomino: ("Velomino-Regular", "otf", false)
        case .vectipedeThin: ("Vectipede-Thin", "otf", false)
        }
    }

    /// One descriptor per font and weight, built once. Single-weight fonts share one descriptor for every weight.
    private struct Key: Hashable { let font: EditRecipe.TextLayer.Font; let weight: EditRecipe.TextLayer.Weight }

    // CTFontDescriptor is immutable and thread-safe; it is only not annotated Sendable. Read once per font and weight.
    nonisolated(unsafe) private static let descriptors: [Key: CTFontDescriptor] = {
        var all: [Key: CTFontDescriptor] = [:]
        for font in EditRecipe.TextLayer.Font.allCases {
            let source = file(for: font)
            guard let base = BundledFontFile.descriptor(name: source.name, fileExtension: source.fileExtension, log: log) else { continue }
            for weight in EditRecipe.TextLayer.Weight.allCases {
                all[Key(font: font, weight: weight)] = source.variable
                    ? CTFontDescriptorCreateCopyWithVariation(base, NSNumber(value: weightAxisTag) as CFNumber, CGFloat(weight.axisValue))
                    : base
            }
        }
        return all
    }()

    /// True when every Text-tool font file is in the bundle (checked by tests).
    static var allBundled: Bool {
        descriptors.count == EditRecipe.TextLayer.Font.allCases.count * EditRecipe.TextLayer.Weight.allCases.count
    }

    /// The font at `size` (any unit: points on screen, pixels in the stage) and `weight`.
    static func font(_ font: EditRecipe.TextLayer.Font, weight: EditRecipe.TextLayer.Weight = .regular, size: CGFloat) -> CTFont {
        guard let descriptor = descriptors[Key(font: font, weight: weight)] else {
            // Only a broken bundle reaches this; the system font keeps the stage working.
            return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}

/// Reads a font file bundled as a resource, with the system font as its explicit fallback for missing glyphs.
///
/// Several owner-supplied fonts (the signature scripts, Retro Romance…) have no "·" or other punctuation. CoreText's
/// implicit fallback depends on the language and can land on LastResort's boxes; the explicit cascade list makes every
/// missing glyph come from the system font instead, in the stage (CTLine) and in SwiftUI `Text` alike.
enum BundledFontFile {
    // CTFontDescriptor is immutable and thread-safe; it is only not annotated Sendable.
    nonisolated(unsafe) private static let systemFallback: CTFontDescriptor = {
        let system = CTFontCreateUIFontForLanguage(.system, 12, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        return CTFontCopyFontDescriptor(system)
    }()

    static func descriptor(name: String, fileExtension: String, log: Logger) -> CTFontDescriptor? {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else {
            log.error("font \(name, privacy: .public).\(fileExtension, privacy: .public) is not in the bundle")
            return nil
        }
        let cascade = [kCTFontCascadeListAttribute as String: [systemFallback]] as CFDictionary
        return CTFontDescriptorCreateCopyWithAttributes(first, cascade)
    }
}
