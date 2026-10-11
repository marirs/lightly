import SwiftUI
import UIKit

/// Colour tokens of the approved Lightly 2 design (`docs/ui/directions/lightly-2-concept/index.html`, 2026-10-10):
/// warm light theme, near-black dark theme, lime accent.
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

    // Lightly 2 tokens: `.t-light` / `.t-dark` in docs/ui/directions/lightly-2-concept/index.html (approved 2026-10-10).
    // Values are copied from the mockup's CSS; rgba() values keep their alpha.

    // Surfaces.
    static let background = Token(light: 0xF3F3F0, dark: 0x0D0E10)                // --bg
    static let surface = Token(light: 0xFFFFFF, dark: 0x131518)                   // --surface
    static let backgroundSecondary = Token(light: 0xF4F4F1, dark: 0x1A1C20)       // --card
    static let canvas = Token(light: 0xE6E6E2, dark: 0x0A0B0C)                    // --stage (two-pane and iPad stage)
    static let sheet = Token(light: 0xFFFFFF, dark: 0x17191C)                     // --sheet

    // Ink.
    static let ink = Token(light: 0x141513, dark: 0xF2F3F0)                       // --ink
    static let inkSecondary = Token(light: 0x5A5E57, dark: 0xA6ABA3)              // --ink2
    static let inkTertiary = Token(light: 0x7D8179, dark: 0x7E837B)               // --ink3
    /// Text on an ink fill (`--on-ink`): selected chips, segments, tabs.
    static let onInk = Token(light: 0xFFFFFF, dark: 0x121408)                     // --on-ink

    // Lines and controls.
    static let hairline = Token(light: 0x141513, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.08)   // --line
    static let track = Token(light: 0x141513, dark: 0xFFFFFF, lightAlpha: 0.18, darkAlpha: 0.18)      // --off
    static let chip = Token(light: 0x141513, dark: 0xFFFFFF, lightAlpha: 0.055, darkAlpha: 0.07)      // --chip
    static let knob = Token(light: 0xFFFFFF, dark: 0xF2F3F0)                                          // --knob
    static let glass = Token(light: 0xFFFFFF, dark: 0x0E0F11, lightAlpha: 0.78, darkAlpha: 0.64)      // --glass
    static let glassInk = Token(light: 0x141513, dark: 0xF2F3F0)                                      // --glass-ink
    static let glassLine = Token(light: 0x141513, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.10)  // --glass-line

    // Accent.
    static let accent = Token(light: 0xCFF26B, dark: 0xCFF26B)                    // --accent (lime fills)
    static let onAccent = Token(light: 0x121408, dark: 0x121408)                  // --on-accent
    /// The lime buttons' 1 pt rim (`--accent-edge`).
    static let accentEdge = Token(light: 0x8FAE2E, dark: 0xE4FF9A)
    /// Accent for text, lines, rings and selection (`--accent-ink`).
    static let selection = Token(light: 0x557311, dark: 0xCFF26B)                 // --accent-ink

    /// The selected tab's translucent lime pill (`--pill`, owner amendment 2026-10-11): lime at 45 % (light) / 17 % (dark).
    static let pill = Token(light: 0xCFF26B, dark: 0xCFF26B, lightAlpha: 0.45, darkAlpha: 0.17)
    /// The selected tab's text on the pill (`--pill-ink`).
    static let pillInk = Token(light: 0x141513, dark: 0xE2F99F)

    /// The browsed category on the landscape iPad Develop list (`--browse`; the mockup's `developList` keeps it).
    static let browse = Token(light: 0xC25E00, dark: 0xFF9F43)
    /// Edited-tool dots (`--edited`).
    static let edited = Token(light: 0xC25E00, dark: 0xFF9F43)
    static let danger = Token(light: 0xC7362B, dark: 0xFF8A7A)                    // --danger
    /// The selected segment / chip / tab fill: `--on-bg` (the ink colour), text in `onInk`.
    static let segmentSelected = Token(light: 0x141513, dark: 0xF2F3F0)
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
