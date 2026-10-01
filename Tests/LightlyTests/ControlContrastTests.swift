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

    static func luminance(of color: Color) -> Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return luminance(UInt8((red * 255).rounded()), UInt8((green * 255).rounded()), UInt8((blue * 255).rounded()))
    }
}

/// WCAG 1.4.11 non-text contrast: at accessibility sizes the editor's
/// controls sit on the plain background (not over the photo), so each
/// control's boundary must contrast ≥ 3:1 with what surrounds it.
@MainActor
final class ControlContrastTests: XCTestCase {

    private let size = SnapshotAssertion.defaultSize

    private func editor(developed: Bool) async -> EditorViewModel {
        let viewModel = EditorViewModel(original: TestFixtures.makePhoto(), developer: DebugFixedRecipeDeveloper())
        if developed {
            viewModel.develop()
            await viewModel.developTask?.value
        }
        return viewModel
    }

    /// Highest contrast between any pixel in a thin band across the
    /// control's left edge and the background just outside it.
    private func boundaryContrast(
        of frame: CGRect, in pixels: [UInt8], width: Int
    ) -> (ratio: Double, outside: (UInt8, UInt8, UInt8)) {
        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let index = (y * width + x) * 4
            return (pixels[index], pixels[index + 1], pixels[index + 2])
        }
        let y = Int(frame.midY)
        let outside = pixel(max(Int(frame.minX) - 4, 0), y)
        let outsideLuminance = WCAG.luminance(outside.0, outside.1, outside.2)
        var best = 1.0
        for x in (Int(frame.minX) - 1)...(Int(frame.minX) + 3) {
            let edge = pixel(x, y)
            best = max(best, WCAG.contrast(WCAG.luminance(edge.0, edge.1, edge.2), outsideLuminance))
        }
        return (best, outside)
    }

    private func assertControlBoundaries(
        developed: Bool, scheme: ColorScheme, anchors: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let viewModel = await editor(developed: developed)
        let view = EditorView(viewModel: viewModel, onBack: {}).environment(\.dynamicTypeSize, .accessibility3)
        // Frames and pixels from the same host, so samples land on the edge.
        let rendered = try XCTUnwrap(SnapshotAssertion.renderWithAnchors(view, size: size, colorScheme: scheme))
        let pixels = try MetalLUTRenderer.rgba8Bytes(of: rendered.image)
        let image = rendered.image

        for anchor in anchors {
            let frame = try XCTUnwrap(rendered.anchors[anchor], "\(anchor) missing; have \(rendered.anchors.keys.sorted())", file: file, line: line)
            let measured = boundaryContrast(of: frame, in: pixels, width: image.width)
            print("contrast \(anchor) \(scheme): \(String(format: "%.2f", measured.ratio)):1")
            XCTAssertGreaterThanOrEqual(
                measured.ratio, 3.0,
                "\(anchor) boundary contrast \(String(format: "%.2f", measured.ratio)):1 against background \(measured.outside) in \(scheme) at AX3",
                file: file, line: line
            )
        }
    }

    func testPreDevelopDevelopButtonBoundaryLight() async throws {
        try await assertControlBoundaries(developed: false, scheme: .light, anchors: ["editor.develop"])
    }

    func testPreDevelopDevelopButtonBoundaryDark() async throws {
        try await assertControlBoundaries(developed: false, scheme: .dark, anchors: ["editor.develop"])
    }

    private let developedControls = [
        "editor.control.chevron.left", "editor.control.ellipsis", "editor.control.crop",
        "editor.control.compare", "editor.control.square.and.arrow.up"
    ]

    func testDevelopedControlBoundariesLight() async throws {
        try await assertControlBoundaries(developed: true, scheme: .light, anchors: developedControls)
    }

    func testDevelopedControlBoundariesDark() async throws {
        try await assertControlBoundaries(developed: true, scheme: .dark, anchors: developedControls)
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
}
