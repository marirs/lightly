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

/// WCAG 1.4.11 non-text contrast: the editor's controls sit on the plain
/// background (never over the photo), so each control's boundary must
/// contrast ≥ 3:1 with what surrounds it, at standard and large text.
@MainActor
final class ControlContrastTests: XCTestCase {

    private let size = SnapshotAssertion.defaultSize

    /// Back, every category chip (one of them selected) and every edit
    /// action. A Look is applied first so Undo and Reset are enabled —
    /// disabled controls are exempt from 1.4.11 and drawn faded on purpose.
    private let editorControls = [
        "editor.control.back",
        "editor.category.Natural", "editor.category.Warm", "editor.category.Cool",
        "editor.category.Film", "editor.category.Mono",
        "editor.control.action.undo", "editor.control.action.reset",
        "editor.control.action.compare", "editor.control.action.saveCopy"
    ]

    /// At accessibility sizes the bottom panel scrolls on a phone-sized
    /// canvas, so some controls are below the fold. A control's chrome does
    /// not depend on its position, so those runs use a taller canvas where
    /// every control is drawn and can be sampled.
    private func canvas(for dynamicTypeSize: DynamicTypeSize) -> CGSize {
        dynamicTypeSize.isAccessibilitySize ? CGSize(width: size.width, height: 1_600) : size
    }

    private func assertControlBoundaries(
        scheme: ColorScheme, dynamicTypeSize: DynamicTypeSize,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let viewModel = try await EditorFixtures.readyEditor(lookStop: 1)
        let view = EditorView(viewModel: viewModel, onBack: {}).environment(\.dynamicTypeSize, dynamicTypeSize)
        // Frames and pixels from the same host, so samples land on the edge.
        let rendered = try XCTUnwrap(SnapshotAssertion.renderWithAnchors(view, size: canvas(for: dynamicTypeSize), colorScheme: scheme))
        let pixels = try MetalLUTRenderer.rgba8Bytes(of: rendered.image)

        for anchor in editorControls {
            let frame = try XCTUnwrap(rendered.anchors[anchor], "\(anchor) missing; have \(rendered.anchors.keys.sorted())", file: file, line: line)
            XCTAssertTrue(CGRect(origin: .zero, size: canvas(for: dynamicTypeSize)).insetBy(dx: 4, dy: 0).contains(frame),
                          "\(anchor) at \(frame) is outside the rendered canvas", file: file, line: line)
            guard CGRect(origin: .zero, size: canvas(for: dynamicTypeSize)).insetBy(dx: 4, dy: 0).contains(frame) else { continue }
            let measured = WCAG.edgeContrast(of: frame, in: pixels, width: rendered.image.width)
            print("contrast \(anchor) \(scheme) \(dynamicTypeSize): \(String(format: "%.2f", measured.ratio)):1")
            XCTAssertGreaterThanOrEqual(
                measured.ratio, 3.0,
                "\(anchor) boundary contrast \(String(format: "%.2f", measured.ratio)):1 against background \(measured.outside) in \(scheme) at \(dynamicTypeSize)",
                file: file, line: line
            )
        }
    }

    func testEditorControlBoundariesLight() async throws {
        try await assertControlBoundaries(scheme: .light, dynamicTypeSize: .large)
    }

    func testEditorControlBoundariesDark() async throws {
        try await assertControlBoundaries(scheme: .dark, dynamicTypeSize: .large)
    }

    func testEditorControlBoundariesLightAccessibility3() async throws {
        try await assertControlBoundaries(scheme: .light, dynamicTypeSize: .accessibility3)
    }

    func testEditorControlBoundariesDarkAccessibility3() async throws {
        try await assertControlBoundaries(scheme: .dark, dynamicTypeSize: .accessibility3)
    }

    /// Labels inside the solid control fill stay ≥ 4.5:1 (WCAG 1.4.3).
    func testLabelContrastOnTheControlFill() {
        for scheme in [ColorScheme.light, .dark] {
            let ratio = WCAG.contrast(
                WCAG.luminance(of: LightlyColor.textPrimary(scheme)),
                WCAG.luminance(of: LightlyColor.surfaceElevated(scheme))
            )
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(scheme): \(ratio):1")
        }
    }

    /// A selected chip or toggle inverts: background-coloured text on a
    /// text-coloured fill, also ≥ 4.5:1.
    func testLabelContrastOnASelectedControl() {
        for scheme in [ColorScheme.light, .dark] {
            let ratio = WCAG.contrast(
                WCAG.luminance(of: LightlyColor.background(scheme)),
                WCAG.luminance(of: LightlyColor.textPrimary(scheme))
            )
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(scheme): \(ratio):1")
        }
    }

    /// Notices and status text are secondary or primary text on the plain
    /// background or the elevated notice fill: ≥ 4.5:1.
    func testNoticeAndSecondaryTextContrast() {
        for scheme in [ColorScheme.light, .dark] {
            let pairs: [(Color, Color, String)] = [
                (LightlyColor.textPrimary(scheme), LightlyColor.surfaceElevated(scheme), "notice"),
                (LightlyColor.textSecondary(scheme), LightlyColor.background(scheme), "secondary text")
            ]
            for (text, fill, name) in pairs {
                let ratio = WCAG.contrast(WCAG.luminance(of: text), WCAG.luminance(of: fill))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) in \(scheme): \(ratio):1")
            }
        }
    }
}
