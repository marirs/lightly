import SwiftUI
import XCTest
@testable import Lightly

/// WCAG 2.x relative luminance and contrast ratio for 8-bit sRGB.
enum WCAG {
    static func luminance(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Double {
        func linear(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Highest contrast between any pixel in a thin band across a control's
    /// left edge (at mid-height) and the background just outside it.
    static func edgeContrast(
        of frame: CGRect, in pixels: [UInt8], width: Int
    ) -> (ratio: Double, outside: (UInt8, UInt8, UInt8)) {
        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let index = (y * width + x) * 4
            return (pixels[index], pixels[index + 1], pixels[index + 2])
        }
        let y = Int(frame.midY)
        let outside = pixel(max(Int(frame.minX) - 4, 0), y)
        let outsideLuminance = luminance(outside.0, outside.1, outside.2)
        var best = 1.0
        for x in (Int(frame.minX) - 1)...(Int(frame.minX) + 3) {
            let edge = pixel(x, y)
            best = max(best, contrast(luminance(edge.0, edge.1, edge.2), outsideLuminance))
        }
        return (best, outside)
    }

    static func luminance(of color: Color) -> Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return luminance(UInt8((red * 255).rounded()), UInt8((green * 255).rounded()), UInt8((blue * 255).rounded()))
    }
}

/// Contrast of the editor's text and marks with the approved tokens (WCAG 1.4.3 text ≥ 4.5:1,
/// 1.4.11 non-text marks ≥ 3:1), in light and dark. The approved design is flat (icons and text on
/// the plain background), so the pairs are the tokens themselves.
// v3 differs: the M2 editor's control chrome (LightlyColor) was measured on rendered pixels; that
// editor is gone, and its palette with it.
final class ControlContrastTests: XCTestCase {

    private func ratio(_ a: ApprovedColor.Token, on b: ApprovedColor.Token, _ scheme: ColorScheme) -> Double {
        WCAG.contrast(WCAG.luminance(of: a.resolved(scheme)), WCAG.luminance(of: b.resolved(scheme)))
    }

    func testTextOnThePanelBackground() {
        for scheme in [ColorScheme.light, .dark] {
            for (token, name) in [(ApprovedColor.ink, "name, selected tab"), (ApprovedColor.inkSecondary, "tabs, Auto, notice text"),
                                  (ApprovedColor.selection, "Amount, quiet buttons")] {
                XCTAssertGreaterThanOrEqual(ratio(token, on: ApprovedColor.background, scheme), 4.5, "\(name) in \(scheme)")
            }
            assertTertiaryTextContrast(on: ApprovedColor.background, scheme, "unselected tool tabs, counts, font names")
            assertTertiaryTextContrast(on: ApprovedColor.surface, scheme, "two-pane and iPad panel (--surface)")
        }
    }

    /// `--ink3` is small text in the mockup (unselected tabs 14.5 px / 500, font names 10.5 px, notes 12 px), so the
    /// 4.5:1 text criterion applies; none of it is large text and only the `aria-disabled` tabs (opacity 0.4) are exempt.
    /// The approved light value #7D8179 measures 3.57:1 on --bg #F3F3F0 and 3.97:1 on --surface / --sheet #FFFFFF.
    /// That is the mockup's own colour, which the app copies exactly (AGENTS.md: no UX deviations), so the light case is
    /// an expected failure pending an owner decision, not a value to change here. Strict: if the owner darkens --ink3 the
    /// expectation itself fails, and this marker must be removed. The dark value passes and stays a plain assertion.
    private func assertTertiaryTextContrast(on background: ApprovedColor.Token, _ scheme: ColorScheme, _ name: String) {
        let measured = ratio(ApprovedColor.inkTertiary, on: background, scheme)
        if scheme == .light {
            XCTExpectFailure("Mockup --ink3 (light) is below 4.5:1 for text; owner decision pending") {
                XCTAssertGreaterThanOrEqual(measured, 4.5, "\(name) in light")
            }
        } else {
            XCTAssertGreaterThanOrEqual(measured, 4.5, "\(name) in dark")
        }
    }

    func testNoticeTextOnTheNoticeFill() {
        for scheme in [ColorScheme.light, .dark] {
            XCTAssertGreaterThanOrEqual(ratio(ApprovedColor.inkSecondary, on: ApprovedColor.backgroundSecondary, scheme), 4.5)
            XCTAssertGreaterThanOrEqual(ratio(ApprovedColor.selection, on: ApprovedColor.backgroundSecondary, scheme), 4.5)
        }
    }

    func testSaveCopyLabelOnItsFill() {
        for scheme in [ColorScheme.light, .dark] {
            XCTAssertGreaterThanOrEqual(ratio(ApprovedColor.background, on: ApprovedColor.ink, scheme), 4.5)
        }
    }

    func testNeedleAndDisabledIconsAreVisibleMarks() {
        for scheme in [ColorScheme.light, .dark] {
            XCTAssertGreaterThanOrEqual(ratio(ApprovedColor.selection, on: ApprovedColor.background, scheme), 3)
            XCTAssertGreaterThanOrEqual(ratio(ApprovedColor.inkTertiary, on: ApprovedColor.background, scheme), 3)
        }
    }

    /// More pages and sheets (`--sheet`): rows, sub-lines, group labels, Delete, quiet buttons.
    func testTextOnTheSheet() {
        for scheme in [ColorScheme.light, .dark] {
            for (token, name) in [(ApprovedColor.ink, "row titles"), (ApprovedColor.inkSecondary, "sub-lines"),
                                  (ApprovedColor.selection, "Cancel, Save, Use"), (ApprovedColor.danger, "Delete saved signature")] {
                XCTAssertGreaterThanOrEqual(ratio(token, on: ApprovedColor.sheet, scheme), 4.5, "\(name) in \(scheme)")
            }
            assertTertiaryTextContrast(on: ApprovedColor.sheet, scheme, "list-row trailing values, privacy note, JPEG")
            XCTAssertGreaterThanOrEqual(ratio(ApprovedColor.danger, on: ApprovedColor.background, scheme), 4.5)
        }
    }

    /// `seg` / `chips` / dock (Lightly 2): the selected item is an `--on-bg` fill with `--on-ink` text; the others are
    /// `--ink2` on the transparent row over the panel. The earlier test paired `--ink` with the selected fill, which is
    /// the M2 raised white segment; in Lightly 2 that fill is the ink colour itself, so the pair measured 1:1.
    func testSegmentedControlLabels() {
        for scheme in [ColorScheme.light, .dark] {
            XCTAssertGreaterThanOrEqual(ratio(ApprovedColor.onInk, on: ApprovedColor.segmentSelected, scheme), 4.5, "\(scheme)")
            XCTAssertGreaterThanOrEqual(ratio(ApprovedColor.inkSecondary, on: ApprovedColor.background, scheme), 4.5, "\(scheme)")
            XCTAssertGreaterThanOrEqual(ratio(ApprovedColor.inkSecondary, on: ApprovedColor.surface, scheme), 4.5, "\(scheme)")
        }
    }

    /// The selected tab (owner amendment 2026-10-11): `--pill-ink` on `--pill`, lime at 45 % (light) / 17 % (dark) over
    /// the panel. This replaces the M2 `.opt.on` / `--selSoft` check: Lightly 2 has no `--selSoft`, and nothing in the
    /// app draws the selection colour on an 8 % / 14 % tint any more.
    func testSelectedTabLabelOnThePill() {
        for scheme in [ColorScheme.light, .dark] {
            for panel in [ApprovedColor.background, ApprovedColor.surface] {
                let pill = composite(ApprovedColor.pill, over: panel, scheme)
                let ink = WCAG.luminance(of: ApprovedColor.pillInk.resolved(scheme))
                XCTAssertGreaterThanOrEqual(WCAG.contrast(ink, pill), 4.5, "\(scheme)")
            }
        }
    }

    /// Luminance of a translucent token flattened over an opaque one (straight alpha, in 8-bit sRGB like the browser).
    private func composite(_ top: ApprovedColor.Token, over bottom: ApprovedColor.Token, _ scheme: ColorScheme) -> Double {
        let alpha = scheme == .dark ? top.darkAlpha : top.lightAlpha
        let topHex = scheme == .dark ? top.dark : top.light, bottomHex = scheme == .dark ? bottom.dark : bottom.light
        func channel(_ shift: UInt32) -> UInt8 {
            let t = Double((topHex >> shift) & 0xFF), b = Double((bottomHex >> shift) & 0xFF)
            return UInt8((t * alpha + b * (1 - alpha)).rounded())
        }
        return WCAG.luminance(channel(16), channel(8), channel(0))
    }
}

/// Swatch colour names spoken as VoiceOver values, the same as Android's.
@MainActor
final class SwatchNameTests: XCTestCase {
    func testEveryApprovedSwatchHasAName() {
        let all = BorderPanelModel.solidColours + BorderPanelModel.frameColours + BorderPanelModel.matColours
            + BorderPanelModel.polaroidColours + WatermarkPanelModel.colours + BackgroundPanelModel.swatches
        for hex in Set(all) { XCTAssertNotNil(SwatchButton<Color>.name(ofHex: hex), hex) }
        XCTAssertEqual(SwatchButton<Color>.name(ofHex: "#4E6B5A"), "Forest green")
        XCTAssertEqual(SwatchButton<Color>.name(ofHex: "#9AA3A8"), "Blue grey")
    }
}
