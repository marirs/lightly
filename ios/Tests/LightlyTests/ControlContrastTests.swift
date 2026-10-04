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
                                  (ApprovedColor.inkTertiary, "counts, position, context, tool labels"),
                                  (ApprovedColor.selection, "Amount, quiet buttons")] {
                XCTAssertGreaterThanOrEqual(ratio(token, on: ApprovedColor.background, scheme), 4.5, "\(name) in \(scheme)")
            }
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
            for (token, name) in [(ApprovedColor.ink, "row titles"), (ApprovedColor.inkTertiary, "sub-lines, notes, groups"),
                                  (ApprovedColor.selection, "Cancel, Save, Use"), (ApprovedColor.danger, "Delete saved signature")] {
                XCTAssertGreaterThanOrEqual(ratio(token, on: ApprovedColor.sheet, scheme), 4.5, "\(name) in \(scheme)")
            }
            XCTAssertGreaterThanOrEqual(ratio(ApprovedColor.danger, on: ApprovedColor.background, scheme), 4.5)
        }
    }

    /// `.seg`: the selected label on the raised segment, the others on `--bg2`.
    func testSegmentedControlLabels() {
        for scheme in [ColorScheme.light, .dark] {
            XCTAssertGreaterThanOrEqual(ratio(ApprovedColor.ink, on: ApprovedColor.segmentSelected, scheme), 4.5)
            XCTAssertGreaterThanOrEqual(ratio(ApprovedColor.inkSecondary, on: ApprovedColor.backgroundSecondary, scheme), 4.5)
        }
    }

    /// `.opt.on`: the selection colour on `--selSoft` (8 % light, 14 % dark over the background).
    func testSelectedChipLabelOnItsSoftFill() {
        for (scheme, alpha) in [(ColorScheme.light, 0.08), (.dark, 0.14)] {
            let sel = UIColor(ApprovedColor.selection.resolved(scheme)), bg = UIColor(ApprovedColor.background.resolved(scheme))
            var s = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0)), b = s
            sel.getRed(&s.0, green: &s.1, blue: &s.2, alpha: &s.3)
            bg.getRed(&b.0, green: &b.1, blue: &b.2, alpha: &b.3)
            func mix(_ x: CGFloat, _ y: CGFloat) -> UInt8 { UInt8(((x * alpha + y * (1 - alpha)) * 255).rounded()) }
            let soft = WCAG.luminance(mix(s.0, b.0), mix(s.1, b.1), mix(s.2, b.2))
            XCTAssertGreaterThanOrEqual(WCAG.contrast(WCAG.luminance(of: ApprovedColor.selection.resolved(scheme)), soft), 4.5, "\(scheme)")
        }
    }
}
