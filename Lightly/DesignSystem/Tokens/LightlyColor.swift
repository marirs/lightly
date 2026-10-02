import SwiftUI

/// Semantic colour tokens for Lightly.
///
/// Every colour used by the interface must come from this type. Views must not
/// construct ad-hoc `Color` values, because the product depends on a calm,
/// consistent surface treatment across light and dark appearance (spec §2.1,
/// "the photograph is the interface" — chrome must never compete with the image).
///
/// Values are defined in code rather than an asset catalogue so that the palette
/// is reviewable in a diff and unit-testable. Each token resolves against the
/// active `ColorScheme` supplied by the environment.
enum LightlyColor {

    // MARK: - Surfaces

    /// The base canvas behind all content (launch screen, sheets, settings).
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.043, green: 0.043, blue: 0.047) // near-black, warm-neutral
            : Color(red: 0.965, green: 0.961, blue: 0.953) // warm paper white
    }

    /// Raised surfaces such as the source-selection sheet.
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.102, green: 0.102, blue: 0.110)
            : Color(red: 0.988, green: 0.986, blue: 0.980)
    }

    /// Rows and controls resting on top of `surface`.
    static func surfaceElevated(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.149, green: 0.149, blue: 0.157)
            : Color(red: 0.933, green: 0.929, blue: 0.918)
    }

    // MARK: - Content

    /// Primary text and iconography.
    static func textPrimary(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.949, green: 0.945, blue: 0.937)
            : Color(red: 0.090, green: 0.090, blue: 0.098)
    }

    /// Supporting copy: taglines, sheet subtitles, captions.
    static func textSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.635, green: 0.631, blue: 0.624)
            : Color(red: 0.400, green: 0.396, blue: 0.388)
    }

    /// Deliberately low-emphasis content such as the idle swipe affordance.
    static func textTertiary(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.435, green: 0.431, blue: 0.427)
            : Color(red: 0.576, green: 0.572, blue: 0.565)
    }

    // MARK: - Accent

    /// The restrained warm accent from the brand mark (spec §32: warm centre,
    /// never a fully warm surface). Used sparingly — the Develop spark, a
    /// selected Look border. It must not become a general-purpose tint.
    static func accentWarm(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.847, green: 0.706, blue: 0.522)
            : Color(red: 0.678, green: 0.529, blue: 0.353)
    }

    // MARK: - Control boundaries

    /// Outline of a control that sits on `background` rather than over the
    /// photograph (accessibility text sizes in the editor).
    ///
    /// Chosen for WCAG 1.4.11 non-text contrast: ≥ 3:1 against `background`
    /// in both appearances (≈5.2:1 light, ≈7.5:1 dark), so the control's
    /// bounded shape is visible without the photo behind it. `line` is too
    /// faint for this (≈1.4:1) by design — it is decoration, not a boundary.
    static func controlBoundary(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.635, green: 0.631, blue: 0.624)
            : Color(red: 0.400, green: 0.396, blue: 0.388)
    }

    // MARK: - Lines

    /// Hairline separators and the mountain line artwork.
    static func line(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.239, green: 0.239, blue: 0.247)
            : Color(red: 0.812, green: 0.804, blue: 0.788)
    }
}
