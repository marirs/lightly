import CoreText
import Foundation
import OSLog

/// The eight Text-tool fonts (owner amendment 2026-10-11; shared/fonts, SIL OFL 1.1): Inter, Playfair Display, Bebas
/// Neue, Caveat, Cormorant Garamond, Montserrat, Dancing Script and Space Mono, each at regular weight (rendering-v2
/// §7.4). Bundled as resources and read by URL, as `WatermarkFonts` reads the watermark fonts, so nothing depends on
/// font registration or on a system font of the same name. Variable files get weight 400 through the `wght` axis.
enum TextFonts {
    private static let log = Logger(subsystem: "com.lightlylabs.lightly", category: "text-fonts")

    /// OpenType 'wght' as a CoreText variation axis identifier.
    private static let weightAxisTag = 0x7767_6874
    /// "Regular weight" in §7.4.
    static let regularWeight = 400.0

    /// The bundled file for each font (without the .ttf extension) and whether it is a variable font.
    static func file(for font: EditRecipe.TextLayer.Font) -> (name: String, variable: Bool) {
        switch font {
        case .inter: ("Inter-Variable", true)
        case .playfairDisplay: ("PlayfairDisplay-Variable", true)
        case .bebasNeue: ("BebasNeue-Regular", false)
        case .caveat: ("Caveat-Variable", true)
        case .cormorantGaramond: ("CormorantGaramond-Variable", true)
        case .montserrat: ("Montserrat-Variable", true)
        case .dancingScript: ("DancingScript-Variable", true)
        case .spaceMono: ("SpaceMono-Regular", false)
        }
    }

    private static func descriptor(file: String) -> CTFontDescriptor? {
        guard let url = Bundle.main.url(forResource: file, withExtension: "ttf"),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else {
            log.error("text font \(file, privacy: .public) is not in the bundle")
            return nil
        }
        return first
    }

    // CTFontDescriptor is immutable and thread-safe; it is only not annotated Sendable. Read once per font.
    nonisolated(unsafe) private static let descriptors: [EditRecipe.TextLayer.Font: CTFontDescriptor] = {
        var all: [EditRecipe.TextLayer.Font: CTFontDescriptor] = [:]
        for font in EditRecipe.TextLayer.Font.allCases {
            let source = file(for: font)
            guard var descriptor = descriptor(file: source.name) else { continue }
            if source.variable {
                descriptor = CTFontDescriptorCreateCopyWithVariation(descriptor, NSNumber(value: weightAxisTag) as CFNumber, CGFloat(regularWeight))
            }
            all[font] = descriptor
        }
        return all
    }()

    /// True when every Text-tool font file is in the bundle (checked by tests).
    static var allBundled: Bool { descriptors.count == EditRecipe.TextLayer.Font.allCases.count }

    /// The font at `size` (any unit: points on screen, pixels in the stage).
    static func font(_ font: EditRecipe.TextLayer.Font, size: CGFloat) -> CTFont {
        guard let descriptor = descriptors[font] else {
            // Only a broken bundle reaches this; the system font keeps the stage working.
            return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}
