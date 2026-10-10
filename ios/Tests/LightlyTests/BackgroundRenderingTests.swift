import CoreGraphics
import ImageIO
import XCTest
@testable import Lightly

/// Background › Focus & Blur and Change background (rendering-v2 stages 7–8, the refocus
/// specification in docs/v1/depth-evaluation.md §6) on synthetic scenes with known depth.
final class BackgroundRenderingTests: XCTestCase {

    /// A 160 × 120 scene: a textured far background (disparity 0.1) and a textured near square
    /// subject in the middle (disparity 0.9), with its matte.
    private func scene(width: Int = 160, height: Int = 120) -> (linear: FloatImage, disparity: FloatImage, matte: FloatImage) {
        var linear = FloatImage(width: width, height: height, channels: 3)
        var disparity = FloatImage(width: width, height: height, channels: 1)
        var matte = FloatImage(width: width, height: height, channels: 1)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let inSubject = x >= 50 && x < 110 && y >= 30 && y < 90
                let checker: Float = ((x / 4 + y / 4) % 2 == 0) ? 0.8 : 0.1
                linear.data[i * 3] = inSubject ? checker : checker * 0.5
                linear.data[i * 3 + 1] = inSubject ? 0.3 : checker
                linear.data[i * 3 + 2] = inSubject ? 0.2 : 0.4
                disparity.data[i] = inSubject ? 0.9 : 0.1
                matte.data[i] = inSubject ? 1 : 0
            }
        }
        return (linear, disparity, matte)
    }

    /// Mean absolute difference between neighbours inside a region: high for sharp texture.
    private func sharpness(_ image: FloatImage, x: Range<Int>, y: Range<Int>) -> Float {
        var total: Float = 0, count: Float = 0
        for yy in y { for xx in x.dropLast() {
            total += abs(image.data[(yy * image.width + xx) * 3] - image.data[(yy * image.width + xx + 1) * 3] )
            count += 1
        } }
        return total / max(count, 1)
    }

    func testBlurZeroIsTheIdentity() {
        let s = scene()
        let built = RefocusRenderer.buildScene(linear: s.linear, disparity: s.disparity, matte: s.matte)
        let out = RefocusRenderer.render(built, .init(targetX: 0.5, targetY: 0.5, blur: 0))
        let worst = zip(out.data, s.linear.data).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 1e-4)
    }

    func testFocusOnTheSubjectKeepsItSharpAndBlursTheBackground() {
        let s = scene()
        let built = RefocusRenderer.buildScene(linear: s.linear, disparity: s.disparity, matte: s.matte)
        for style in EditRecipe.Focus.Style.allCases {
            let out = RefocusRenderer.render(built, .init(targetX: 0.5, targetY: 0.5, blur: 100, focusDepth: 40, style: style))
            let subjectBefore = sharpness(s.linear, x: 60..<100, y: 40..<80), subjectAfter = sharpness(out, x: 60..<100, y: 40..<80)
            let backgroundBefore = sharpness(s.linear, x: 5..<40, y: 5..<25), backgroundAfter = sharpness(out, x: 5..<40, y: 5..<25)
            XCTAssertGreaterThan(subjectAfter, subjectBefore * 0.85, "\(style): the focused subject stays sharp")
            XCTAssertLessThan(backgroundAfter, backgroundBefore * 0.5, "\(style): the far background is blurred")
        }
    }

    func testFocusOnTheBackgroundBlursTheSubjectInstead() {
        let s = scene()
        let built = RefocusRenderer.buildScene(linear: s.linear, disparity: s.disparity, matte: s.matte)
        let out = RefocusRenderer.render(built, .init(targetX: 0.05, targetY: 0.05, blur: 100, focusDepth: 10))
        XCTAssertLessThan(sharpness(out, x: 60..<100, y: 40..<80), sharpness(s.linear, x: 60..<100, y: 40..<80) * 0.6)
        XCTAssertGreaterThan(sharpness(out, x: 5..<40, y: 5..<25), sharpness(s.linear, x: 5..<40, y: 5..<25) * 0.8)
    }

    func testFocusDepthWidensTheSharpBand() {
        var s = scene()
        // A middle-distance band of background at disparity 0.6.
        for y in 0..<20 { for x in 0..<160 { s.disparity.data[y * 160 + x] = 0.6 } }
        let built = RefocusRenderer.buildScene(linear: s.linear, disparity: s.disparity, matte: s.matte)
        let narrow = RefocusRenderer.render(built, .init(targetX: 0.5, targetY: 0.5, blur: 100, focusDepth: 0))
        let wide = RefocusRenderer.render(built, .init(targetX: 0.5, targetY: 0.5, blur: 100, focusDepth: 100))
        XCTAssertGreaterThan(sharpness(wide, x: 5..<150, y: 3..<15), sharpness(narrow, x: 5..<150, y: 3..<15))
    }

    func testHighlightExpansionRoundTrips() {
        var image = FloatImage(width: 4, height: 1, channels: 3)
        image.data = [0.2, 0.5, 0.1, 0.9, 0.95, 0.8, 1, 1, 1, 0.71, 0.3, 0.2]
        let back = RefocusRenderer.compressHighlights(RefocusRenderer.expandHighlights(image))
        for (a, b) in zip(image.data, back.data) { XCTAssertEqual(a, b, accuracy: 1e-5) }
    }

    func testKernelsAreNormalised() {
        for style in EditRecipe.Focus.Style.allCases {
            for bokeh in EditRecipe.Focus.Bokeh.allCases {
                let k = RefocusRenderer.kernel(style: style, bokeh: bokeh, radius: 8, styleAmount: 50)
                XCTAssertEqual(k.taps.reduce(0) { $0 + $1.w }, 1, accuracy: 1e-4, "\(style) \(bokeh)")
                XCTAssertGreaterThan(k.taps.count, 10)
            }
        }
    }

    func testPullPushFillsHolesFromTheirSurroundings() {
        var colour = FloatImage(width: 32, height: 32, channels: 1, repeating: 0.7)
        var coverage = FloatImage(width: 32, height: 32, channels: 1, repeating: 1)
        for y in 10..<20 { for x in 10..<20 { colour.data[y * 32 + x] = 0; coverage.data[y * 32 + x] = 0 } }
        let filled = FloatImage.pullPushFill(premultiplied: colour, coverage: coverage)
        XCTAssertEqual(filled.data[15 * 32 + 15], 0.7, accuracy: 0.02)
    }

    /// After a replacement the same Focus & Blur still works: the new background is blurred,
    /// the subject stays sharp and keeps its own colour.
    func testFocusAndBlurAfterReplacement() {
        let s = scene()
        var replacement = FloatImage(width: 160, height: 120, channels: 3)
        for y in 0..<120 { for x in 0..<160 {
            let v: Float = ((x / 3) % 2 == 0) ? 0.9 : 0.05
            replacement.data[(y * 160 + x) * 3] = v; replacement.data[(y * 160 + x) * 3 + 1] = v; replacement.data[(y * 160 + x) * 3 + 2] = v
        } }
        var built = RefocusRenderer.buildScene(linear: s.linear, disparity: s.disparity, matte: s.matte)
        built = RefocusRenderer.replacingBackground(built, with: replacement, ownDisparity: nil)
        let sharp = RefocusRenderer.render(built, .init(targetX: 0.5, targetY: 0.5, blur: 0))
        let blurred = RefocusRenderer.render(built, .init(targetX: 0.5, targetY: 0.5, blur: 100))
        XCTAssertLessThan(sharpness(blurred, x: 5..<40, y: 5..<25), sharpness(sharp, x: 5..<40, y: 5..<25) * 0.5)
        XCTAssertEqual(sharp.data[(60 * 160 + 80) * 3 + 1], 0.3, accuracy: 0.02, "Subject colour, not the replacement's")
        XCTAssertEqual(sharp.data[(5 * 160 + 5) * 3], replacement.data[(5 * 160 + 5) * 3], accuracy: 0.02, "Background is the replacement")
    }

    func testRefineStrokesAddAndErase() {
        var matte = FloatImage(width: 100, height: 100, channels: 1)
        BackgroundStage.applyRefinements([.init(mode: .add, radius: 0.05, points: [.init(x: 0.5, y: 0.5)])], to: &matte)
        XCTAssertEqual(matte.data[50 * 100 + 50], 1, accuracy: 1e-4)
        XCTAssertEqual(matte.data[5 * 100 + 5], 0)
        BackgroundStage.applyRefinements([.init(mode: .erase, radius: 0.05, points: [.init(x: 0.5, y: 0.5)])], to: &matte)
        XCTAssertEqual(matte.data[50 * 100 + 50], 0, accuracy: 1e-4)
    }

    func testCSSGradientRunsAlongItsAngle() throws {
        let g = BackgroundPanelModel.gradients[1]   // 180deg: top colour to bottom colour
        let pixels = try XCTUnwrap(BackgroundStage.replacementRGBA8(.gradient(angle: g.angle, stops: g.stops), width: 10, height: 100, image: nil))
        XCTAssertEqual(Int(pixels[0]), 0x20, accuracy: 3)           // top: #20242C
        XCTAssertEqual(Int(pixels[(99 * 10) * 4]), 0x5B, accuracy: 3) // bottom: #5B6476
    }

    func testReplacementImageIsPositionedAndScaled() throws {
        // Left half black, right half white: a horizontal position change must show.
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        let image = try XCTUnwrap(context.makeImage())
        let centred = try XCTUnwrap(BackgroundStage.replacementRGBA8(.image(.bundled(id: "x"), x: 50, y: 50, scale: 100), width: 50, height: 50, image: image))
        let left = try XCTUnwrap(BackgroundStage.replacementRGBA8(.image(.bundled(id: "x"), x: 0, y: 50, scale: 100), width: 50, height: 50, image: image))
        XCTAssertNotEqual(centred, left, "x moves the image")
    }

    func testImportedAndBundledImagesUseTheSamePreviewAndExportPath() throws {
        let s = scene()
        let pixels = s.linear.rgba8FromLinear()
        let image = try MetalLUTRenderer.makeImage(rgba8: [UInt8](repeating: 255, count: 4*8*8), width: 8, height: 8)
        let renderer = try MetalLUTRenderer()
        let neutral = EditRecipe.Tools.neutral(grainSeed: 1)
        var cache = SceneCache()
        cache.subject = SubjectMatte(matte: s.matte, model: .init(id: "test", version: "1"))
        cache.replacementImages["sample"] = image
        for cap in [LayeredStages.previewCap, LayeredStages.exportCap] {
            var inputs = LayeredStages.Inputs(background: neutral.background, portrait: neutral.portrait, cache: cache, developLUT: nil, autoLUT: nil)
            inputs.background.replacement = .image(.bundled(id: "sample"), x: 50, y: 50, scale: 100)
            let bundled = try LayeredStages.render(pixels, width: 160, height: 120, inputs: inputs, cap: cap, lutApplier: renderer)
            inputs.background.replacement = .image(.file(sha256: "sample"), x: 50, y: 50, scale: 100)
            let imported = try LayeredStages.render(pixels, width: 160, height: 120, inputs: inputs, cap: cap, lutApplier: renderer)
            XCTAssertEqual(imported, bundled)
            XCTAssertNotEqual(imported, pixels)
        }
    }

    func testDisparityNormalisationUsesPercentiles() {
        var map = FloatImage(width: 100, height: 1, channels: 1)
        for i in 0..<100 { map.data[i] = Float(i) }
        map.data[99] = 10_000   // an outlier must not compress the rest
        let n = DepthEstimator.normalised(map)
        XCTAssertEqual(n.data[0], 0, accuracy: 0.02)
        XCTAssertEqual(n.data[50], 0.5, accuracy: 0.05)
        XCTAssertEqual(n.data[99], 1)
    }
}
