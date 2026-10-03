import CoreGraphics
import XCTest
@testable import Lightly

/// Portrait (stage 9): per-face edits change only their own regions and never the colour of
/// eyes or skin.
final class PortraitRenderingTests: XCTestCase {

    private func face() -> DetectedFace {
        // A face box in the middle of a 200 × 200 frame, with simple landmark polygons.
        func poly(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> [CGPoint] {
            (0..<12).map { k in let a = Double(k) / 12 * 2 * .pi; return CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a)) }
        }
        return DetectedFace(box: .init(x: 0.3, y: 0.25, width: 0.4, height: 0.5),
                            faceContour: [], leftEye: poly(0.42, 0.42, 0.04, 0.015), rightEye: poly(0.58, 0.42, 0.04, 0.015),
                            leftEyebrow: poly(0.42, 0.37, 0.05, 0.01), rightEyebrow: poly(0.58, 0.37, 0.05, 0.01),
                            outerLips: poly(0.5, 0.62, 0.07, 0.025), innerLips: poly(0.5, 0.62, 0.05, 0.012), quality: 0.8)
    }

    /// Skin-coloured frame with noise (pores), a darker red blotch on the cheek, blue irises and
    /// bright teeth.
    private func image() -> FloatImage {
        var image = FloatImage(width: 200, height: 200, channels: 3)
        var seed: UInt32 = 7
        for y in 0..<200 { for x in 0..<200 {
            seed = PortraitRenderingTests.next(seed)
            let noise = Float(seed % 100) / 100 * 0.06 - 0.03
            var rgb = SIMD3<Float>(0.55 + noise, 0.35 + noise, 0.28 + noise)
            let dx = Float(x) - 70, dy = Float(y) - 110
            if dx * dx + dy * dy < 25 { rgb = SIMD3(0.6, 0.22, 0.2) }           // blemish
            for ex in [84, 116] { let ex2 = Float(x - ex), ey = Float(y - 84); if ex2 * ex2 / 49 + ey * ey / 6 < 1 { rgb = SIMD3(0.1, 0.25, 0.6) } }
            let tx = Float(x) - 100, ty = Float(y) - 124
            if tx * tx / 81 + ty * ty / 4 < 1 { rgb = SIMD3(0.75, 0.72, 0.62) }   // teeth
            image.data[(y * 200 + x) * 3] = rgb.x; image.data[(y * 200 + x) * 3 + 1] = rgb.y; image.data[(y * 200 + x) * 3 + 2] = rgb.z
        } }
        return image
    }

    static func next(_ s: UInt32) -> UInt32 { s &* 1_664_525 &+ 1_013_904_223 }

    private func edit(_ change: (inout EditRecipe.FaceEdit) -> Void) -> EditRecipe.FaceEdit {
        var e = PortraitPanelModel.neutral(for: face())
        change(&e)
        return e
    }

    private func lab(_ image: FloatImage, _ x: Int, _ y: Int) -> SIMD3<Float> {
        let i = (y * image.width + x) * 3
        return ColourMath.oklab(fromEncoded: ColourMath.encoded(fromLinear: SIMD3(image.data[i], image.data[i + 1], image.data[i + 2])))
    }

    func testNoChangesIsTheIdentity() {
        let input = image()
        let out = PortraitRenderer.render(input, faces: [.init(detected: face(), edit: edit { _ in })], personMatte: nil)
        XCTAssertEqual(out.data, input.data)
    }

    func testEyesBrightenKeepsEyeColour() {
        let input = image()
        let out = PortraitRenderer.render(input, faces: [.init(detected: face(), edit: edit { $0.eyes.brighten = 100 })], personMatte: nil)
        let before = lab(input, 84, 84), after = lab(out, 84, 84)
        XCTAssertGreaterThan(after.x, before.x, "Lighter")
        let hueBefore = atan2(before.z, before.y), hueAfter = atan2(after.z, after.y)
        XCTAssertEqual(hueAfter, hueBefore, accuracy: 0.05, "Iris hue unchanged")
    }

    func testBlemishesRemoveTheRedMarkButKeepTheSkinTone() {
        let input = image()
        let out = PortraitRenderer.render(input, faces: [.init(detected: face(), edit: edit { $0.skin.blemishes = 100 })], personMatte: nil)
        let blemishBefore = lab(input, 70, 110).y, blemishAfter = lab(out, 70, 110).y
        XCTAssertLessThan(blemishAfter, blemishBefore - 0.01, "Less red")
        let skinBefore = lab(input, 100, 150), skinAfter = lab(out, 100, 150)
        XCTAssertEqual(skinAfter.y, skinBefore.y, accuracy: 0.01)
        XCTAssertEqual(skinAfter.z, skinBefore.z, accuracy: 0.01)
    }

    func testTeethStayWithinANaturalRange() {
        let input = image()
        let out = PortraitRenderer.render(input, faces: [.init(detected: face(), edit: edit { $0.teeth.brighten = 100 })], personMatte: nil)
        let after = lab(out, 100, 124)
        XCTAssertGreaterThan(after.x, lab(input, 100, 124).x)
        XCTAssertLessThanOrEqual(after.x, 0.921)
        XCTAssertEqual(lab(out, 20, 20), lab(input, 20, 20), "Outside the face nothing changes")
    }

    func testSmoothingWithFullTextureKeptStillReducesBlotches() {
        let input = image()
        let smooth = PortraitRenderer.render(input, faces: [.init(detected: face(), edit: edit { $0.skin.smoothing = 100; $0.skin.keepTexture = 0 })], personMatte: nil)
        func variance(_ img: FloatImage) -> Float {
            let values = (130..<150).flatMap { y in (90..<110).map { x in self.lab(img, x, y).x } }
            let mean = values.reduce(0, +) / Float(values.count)
            return values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)
        }
        XCTAssertLessThan(variance(smooth), variance(input) * 0.6)
    }
}
