import XCTest
@testable import Lightly

/// Rendering-v2 stage 11 against the approved insets (prototype `borderInsets`).
final class BorderStageTests: XCTestCase {

    private func frame(width: Int, height: Int, value: UInt8 = 100) -> [UInt8] {
        [UInt8](repeating: value, count: width * height * 4)
    }

    private func pixel(_ p: [UInt8], _ width: Int, _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * width + x) * 4
        return Array(p[i..<(i + 4)])
    }

    private func border(_ type: EditRecipe.Border.Kind, colour: String = "#111111", width: Double = 5,
                        spacing: Double = 3, mat: String = "#F4F1EC") -> EditRecipe.Border {
        .init(type: type, colour: colour, width: width, spacing: spacing, mat: mat)
    }

    func testNoneReturnsTheFrameUnchanged() {
        let input = frame(width: 10, height: 8)
        let out = BorderStage.apply(border(.none), pixels: input, width: 10, height: 8)
        XCTAssertEqual(out.width, 10); XCTAssertEqual(out.height, 8); XCTAssertEqual(out.pixels, input)
    }

    func testSolidAddsWidthPercentOfTheImageWidthOnEverySide() {
        let out = BorderStage.apply(border(.solid, colour: "#C9A27E", width: 5), pixels: frame(width: 200, height: 100), width: 200, height: 100)
        XCTAssertEqual(out.width, 220); XCTAssertEqual(out.height, 120)
        XCTAssertEqual(pixel(out.pixels, out.width, 0, 0), [0xC9, 0xA2, 0x7E, 255])
        XCTAssertEqual(pixel(out.pixels, out.width, 10, 10), [100, 100, 100, 100], "photo starts at the inset")
        XCTAssertEqual(pixel(out.pixels, out.width, 9, 10), [0xC9, 0xA2, 0x7E, 255])
    }

    func testFrameHasAnOuterBandInTheFrameColourAndAMatInside() {
        // width 3 %, spacing 5 % of 200 px: band 6 px, total inset 16 px.
        let out = BorderStage.apply(border(.frame, colour: "#111111", width: 3, spacing: 5, mat: "#F4F1EC"),
                                    pixels: frame(width: 200, height: 100), width: 200, height: 100)
        XCTAssertEqual(out.width, 232); XCTAssertEqual(out.height, 132)
        XCTAssertEqual(pixel(out.pixels, out.width, 5, 50), [0x11, 0x11, 0x11, 255], "frame band")
        XCTAssertEqual(pixel(out.pixels, out.width, 6, 50), [0xF4, 0xF1, 0xEC, 255], "mat band")
        XCTAssertEqual(pixel(out.pixels, out.width, 16, 16), [100, 100, 100, 100], "photo")
    }

    func testPolaroidKeepsTheLargerBottomMargin() {
        let out = BorderStage.apply(border(.polaroid, colour: "#FFFFFF"), pixels: frame(width: 1000, height: 800), width: 1000, height: 800)
        // side 55, top 55, bottom 240.
        XCTAssertEqual(out.width, 1110); XCTAssertEqual(out.height, 800 + 55 + 240)
        XCTAssertEqual(pixel(out.pixels, out.width, 55, 55), [100, 100, 100, 100])
        XCTAssertEqual(pixel(out.pixels, out.width, 55, 855), [255, 255, 255, 255], "bottom margin below the photo")
    }
    func testPaperIsDeterministicAndKeepsInteriorPixels() {
        let input = frame(width: 400, height: 300)
        for finish in EditRecipe.Border.PaperFinish.allCases {
            var b = border(.paper, colour: "#ECE8DF", width: 8)
            b.paperFinish = finish; b.texture = 70
            let a = BorderStage.apply(b, pixels: input, width: 400, height: 300)
            let repeatRender = BorderStage.apply(b, pixels: input, width: 400, height: 300)
            XCTAssertEqual(a.pixels, repeatRender.pixels)
            XCTAssertEqual(pixel(a.pixels, a.width, 232, 182), [100,100,100,100])
            XCTAssertEqual(a.width, 464); XCTAssertEqual(a.height, 364)
            XCTAssertNotEqual(pixel(a.pixels, a.width, 0, 0), pixel(a.pixels, a.width, 5, 3))
        }
    }

    func testCleanPaperWithoutTextureMatchesSolidAndTornChangesOnlyEdges() {
        let input = frame(width: 600, height: 400)
        var b = border(.paper); b.paperFinish = .clean; b.texture = 0
        XCTAssertEqual(BorderStage.apply(b, pixels: input, width: 600, height: 400).pixels,
                       BorderStage.apply(border(.solid), pixels: input, width: 600, height: 400).pixels)
        b.paperFinish = .torn
        let torn = BorderStage.apply(b, pixels: input, width: 600, height: 400)
        XCTAssertNotEqual(pixel(torn.pixels, torn.width, 30, 30), [100,100,100,100])
        XCTAssertEqual(pixel(torn.pixels, torn.width, 100, 100), [100,100,100,100])
    }

}
