import CoreText
import Foundation
import OSLog

/// The four approved watermark fonts (shared/fonts, SIL OFL 1.1), by exact family and weight as
/// the prototype loads them from Google Fonts: Allura (regular), Cormorant Garamond 500,
/// Inter 400 (text) and 700 (the logo's initials), Caveat 500.
///
/// The files are bundled as resources and read by URL, so nothing depends on font registration
/// order or on a system font with the same name. Variable fonts get their weight through the
/// `wght` axis; Inter's optical size follows the CSS px size the prototype would use (Chromium
/// sets `opsz` automatically), so the glyphs match at every output resolution.
enum WatermarkFonts {
    private static let log = Logger(subsystem: "com.lightlylabs.lightly", category: "watermark-fonts")

    /// OpenType axis tags as CoreText axis identifiers: 'wght' and 'opsz'.
    private static let weightAxisTag = 0x7767_6874
    private static let opticalSizeAxisTag = 0x6F70_737A

    private static func descriptor(file: String) -> CTFontDescriptor? {
        guard let url = Bundle.main.url(forResource: file, withExtension: "ttf"),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else {
            log.error("watermark font \(file, privacy: .public) is not in the bundle")
            return nil
        }
        return first
    }

    // CTFontDescriptor is immutable and thread-safe; it is only not annotated Sendable.
    nonisolated(unsafe) private static let allura = descriptor(file: "Allura-Regular")
    nonisolated(unsafe) private static let cormorant = descriptor(file: "CormorantGaramond-Variable")
    nonisolated(unsafe) private static let inter = descriptor(file: "Inter-Variable")
    nonisolated(unsafe) private static let caveat = descriptor(file: "Caveat-Variable")

    nonisolated(unsafe) private static let dancing = descriptor(file: "DancingScript-Variable")
    nonisolated(unsafe) private static let lora = descriptor(file: "Lora-Variable")

    /// True when every approved font file is in the bundle (checked by tests).
    static var allBundled: Bool { allura != nil && cormorant != nil && inter != nil && caveat != nil && dancing != nil && lora != nil }

    /// The watermark text font at `size` (any unit: points or pixels). `cssPixels` is the size the
    /// prototype would draw at (18 px × size/34), used only for Inter's optical size.
    static func font(_ font: EditRecipe.Watermark.Font, size: CGFloat, cssPixels: CGFloat? = nil) -> CTFont {
        switch font {
        case .allura: return make(allura, size: size, weight: nil, opticalSize: nil)
        case .cormorantGaramond: return make(cormorant, size: size, weight: 500, opticalSize: nil)
        case .inter: return make(inter, size: size, weight: 400, opticalSize: cssPixels ?? size)
        case .dancingScript: return make(dancing, size: size, weight: 400, opticalSize: nil)
        case .lora: return make(lora, size: size, weight: 400, opticalSize: nil)
        case .caveat: return make(caveat, size: size, weight: 500, opticalSize: nil)
        }
    }

    /// The default logo's initials: Inter 700 (prototype `LOGO`, `font-weight="700"`).
    static func logoInitials(size: CGFloat, cssPixels: CGFloat) -> CTFont {
        make(inter, size: size, weight: 700, opticalSize: cssPixels)
    }

    private static func make(_ descriptor: CTFontDescriptor?, size: CGFloat, weight: Double?, opticalSize: CGFloat?) -> CTFont {
        guard var descriptor else {
            // Only a broken bundle reaches this; the system font keeps the stage working.
            return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        }
        if let weight { descriptor = CTFontDescriptorCreateCopyWithVariation(descriptor, NSNumber(value: weightAxisTag) as CFNumber, CGFloat(weight)) }
        if let opticalSize {
            // Inter's opsz axis spans 14…32.
            descriptor = CTFontDescriptorCreateCopyWithVariation(descriptor, NSNumber(value: opticalSizeAxisTag) as CFNumber, min(max(opticalSize, 14), 32))
        }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}
