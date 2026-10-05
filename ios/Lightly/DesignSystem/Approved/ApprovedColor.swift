import SwiftUI
import UIKit

/// Colour tokens of the approved Lightly 1.0 design (`docs/ui/app/styles.css`, revision ff5c5ae):
/// neutral light theme, charcoal dark theme, one restrained selection colour.
///
/// Every screen built from slice 1 on uses these. `LightlyColor` (the earlier warm palette)
/// remains only for the legacy editor, which slice 2 replaces.
enum ApprovedColor {

    /// One token's light and dark values.
    struct Token: Sendable {
        let light: UInt32
        let dark: UInt32
        let lightAlpha: Double
        let darkAlpha: Double

        init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
            self.light = light
            self.dark = dark
            self.lightAlpha = lightAlpha
            self.darkAlpha = darkAlpha
        }

        func resolved(_ scheme: ColorScheme) -> Color {
            scheme == .dark ? Color(hex: dark, opacity: darkAlpha) : Color(hex: light, opacity: lightAlpha)
        }

        /// Follows the trait collection by itself, for UIKit and for places where the scheme is
        /// not at hand (sheet backgrounds, the launch-screen check).
        var dynamic: Color {
            Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(hex: dark, alpha: darkAlpha)
                    : UIColor(hex: light, alpha: lightAlpha)
            })
        }
    }

    // Surfaces.
    static let background = Token(light: 0xFFFFFF, dark: 0x1C1C1E)        // --bg
    static let backgroundSecondary = Token(light: 0xF6F6F7, dark: 0x232326) // --bg2
    static let canvas = Token(light: 0xEEEEF0, dark: 0x111113)            // --canvas
    static let sheet = Token(light: 0xFFFFFF, dark: 0x26262A)             // --sheet

    // Ink.
    static let ink = Token(light: 0x121214, dark: 0xF2F2F4)               // --ink
    static let inkSecondary = Token(light: 0x55555C, dark: 0xAEAEB4)      // --ink2
    static let inkTertiary = Token(light: 0x6C6C74, dark: 0x94949C)       // --ink3

    // Lines and controls.
    static let hairline = Token(light: 0xE3E3E6, dark: 0x2E2E32)          // --hair
    static let track = Token(light: 0xDEDEE2, dark: 0x38383D)             // --track
    static let selection = Token(light: 0x2257D2, dark: 0x7AA2FF)         // --sel
    /// The browsed Develop category's underline (owner amendment 2026-10-05, docs/ui/amendments/2026-10-05-develop.md).
    /// Orange, so browsing never reads as the blue "applied" dot; ≥ 3:1 against --bg in both themes.
    static let browse = Token(light: 0xC25E00, dark: 0xFF9F43)
    static let danger = Token(light: 0xC2342B, dark: 0xFF6B5E)            // --danger
    /// The selected segment's fill: --bg in light, #3A3A3F in dark (`.dark .seg .on`).
    static let segmentSelected = Token(light: 0xFFFFFF, dark: 0x3A3A3F)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
