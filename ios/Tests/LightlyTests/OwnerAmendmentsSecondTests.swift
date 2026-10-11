import CoreGraphics
import CoreText
import SwiftUI
import XCTest
@testable import Lightly

/// The owner amendments of 2026-10-11 (second, docs/ui/proposals/lightly-2-oct11b) below the interface: the text
/// layer's weight in the recipe and the stage, the three further Text fonts and seven watermark signature scripts (bundled,
/// resolving to themselves, missing glyphs from the system font), and Change background's tile order.
final class OwnerAmendmentsSecondTests: XCTestCase {

    private func neutralFixture() throws -> EditRecipe {
        try EditRecipeCodec.decode(Data(contentsOf: DevelopParityTests.fixture("shared/fixtures/edit-recipe/neutral.json")))
    }

    private func layer(font: EditRecipe.TextLayer.Font = .inter, weight: EditRecipe.TextLayer.Weight = .regular,
                       text: String = "Summer in Lisbon") -> EditRecipe.TextLayer {
        EditRecipe.TextLayer(id: "0a1b2c3d", text: text, font: font, weight: weight, size: 42, colour: "#FFFFFF", opacity: 100,
                             centre: .init(x: 0.5, y: 0.5), rotation: 0)
    }

    // MARK: - Recipe: textLayer.weight and the new font names

    func testAMissingWeightReadsAsRegular() throws {
        var recipe = try neutralFixture()
        recipe.tools.text.layers = [layer(weight: .bold)]
        let written = String(decoding: EditRecipeCodec.encode(recipe), as: UTF8.self)
        XCTAssertTrue(written.contains("\"font\":\"Inter\",\"weight\":\"bold\",\"size\":42"), "always written, in schema order")
        let withoutWeight = written.replacingOccurrences(of: "\"weight\":\"bold\",", with: "")
        XCTAssertFalse(withoutWeight.contains("\"weight\":\""))
        let read = try EditRecipeCodec.decode(Data(withoutWeight.utf8))
        XCTAssertEqual(read.tools.text.layers.first?.weight, .regular)
    }

    func testEveryWeightAndNewFontRoundTrips() throws {
        var recipe = try neutralFixture()
        recipe.tools.text.layers = [layer(font: .retroRomance), layer(font: .velomino), layer(font: .vectipedeThin),
                                    layer(font: .montserrat, weight: .thin), layer(font: .playfairDisplay, weight: .bold)]
        for (index, _) in recipe.tools.text.layers.enumerated() { recipe.tools.text.layers[index].id = String(format: "%08x", index) }
        let bytes = EditRecipeCodec.encode(recipe)
        let json = String(decoding: bytes, as: UTF8.self)
        for name in ["Retro Romance", "Velomino", "Vectipede Thin"] { XCTAssertTrue(json.contains("\"font\":\"\(name)\"")) }
        XCTAssertEqual(try EditRecipeCodec.decode(bytes), recipe)
    }

    func testTheSignatureScriptsAreWatermarkFontsAfterLora() throws {
        XCTAssertEqual(EditRecipe.Watermark.Font.allCases.map(\.rawValue),
                       ["Allura", "Cormorant Garamond", "Inter", "Caveat", "Dancing Script", "Lora",
                        "Carpenters", "Sourdough Script", "Jaybird", "Astoria", "Bonskin", "Shareit", "Monttee"])
        XCTAssertEqual(EditRecipe.TextLayer.Font.allCases.map(\.rawValue),
                       ["Inter", "Playfair Display", "Bebas Neue", "Caveat", "Cormorant Garamond", "Montserrat", "Dancing Script",
                        "Space Mono", "Retro Romance", "Velomino", "Vectipede Thin"])
        var recipe = try neutralFixture()
        for font in EditRecipe.Watermark.Font.allCases {
            recipe.tools.watermark.type = .text
            recipe.tools.watermark.text = .init(text: "A. Rivera", font: font)
            XCTAssertEqual(try EditRecipeCodec.decode(EditRecipeCodec.encode(recipe)), recipe, font.rawValue)
        }
    }

    func testSingleWeightFontsAreTheMockupsFive() {
        XCTAssertEqual(EditRecipe.TextLayer.Font.allCases.filter(\.hasSingleWeight),
                       [.bebasNeue, .spaceMono, .retroRomance, .velomino, .vectipedeThin])
        XCTAssertEqual(EditRecipe.TextLayer.Weight.allCases.map(\.axisValue), [200, 400, 700])
    }

    // MARK: - Fonts

    func testEveryTextAndWatermarkFontIsBundledAndResolvesToItself() {
        XCTAssertTrue(TextFonts.allBundled, "all 11 Text fonts")
        XCTAssertTrue(WatermarkFonts.allBundled, "all 13 watermark fonts")
        let systemFamily = CTFontCopyFamilyName(CTFontCreateUIFontForLanguage(.system, 20, nil)!) as String
        for font in EditRecipe.TextLayer.Font.allCases {
            let family = CTFontCopyFamilyName(TextFonts.font(font, size: 20)) as String
            XCTAssertNotEqual(family, systemFamily, "\(font.rawValue) is its own file, not the fallback")
        }
        for font in EditRecipe.Watermark.Font.allCases {
            let family = CTFontCopyFamilyName(WatermarkFonts.font(font, size: 20)) as String
            XCTAssertNotEqual(family, systemFamily, "\(font.rawValue) is its own file, not the fallback")
        }
        // The file names its family "Carpenters Personal Use".
        XCTAssertTrue((CTFontCopyFamilyName(WatermarkFonts.font(.carpenters, size: 20)) as String).hasPrefix("Carpenters"))
    }

    /// Several signature scripts have no "·": the line still draws a real glyph for it, from the system font.
    func testMissingGlyphsFallBackToTheSystemFont() throws {
        for font in EditRecipe.Watermark.Font.allCases {
            let ctFont = WatermarkFonts.font(font, size: 40)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "A · R",
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ctFont]))
            let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
            var glyphs: [CGGlyph] = []
            for run in runs {
                var buffer = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &buffer)
                glyphs += buffer
            }
            XCTAssertEqual(glyphs.count, 5, font.rawValue)
            XCTAssertFalse(glyphs.contains(0), "\(font.rawValue): no .notdef (tofu) glyph")
        }
    }

    // MARK: - Weight in the stage (rendering-v2 §7.4)

    func testBoldIsWiderAndThinNarrowerThanRegularOnAVariableFont() {
        let frame = CGSize(width: 1_000, height: 1_000)
        for font in [EditRecipe.TextLayer.Font.inter, .montserrat] {
            let thin = TextStage.layout(layer(font: font, weight: .thin), frameSize: frame).blockSize.width
            let regular = TextStage.layout(layer(font: font, weight: .regular), frameSize: frame).blockSize.width
            let bold = TextStage.layout(layer(font: font, weight: .bold), frameSize: frame).blockSize.width
            XCTAssertGreaterThan(bold, regular + 1, font.rawValue)
            XCTAssertLessThan(thin, regular - 1, font.rawValue)
        }
    }

    func testBoldInksMorePixelsThanRegular() {
        func inked(_ weight: EditRecipe.TextLayer.Weight) -> Int {
            let width = 400, height = 200
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            TextStage.apply(.init(layers: [layer(font: .playfairDisplay, weight: weight, text: "Lisbon")]), pixels: &pixels, width: width, height: height)
            return stride(from: 0, to: pixels.count, by: 4).reduce(0) { $0 + Int(pixels[$1]) }
        }
        XCTAssertGreaterThan(inked(.bold), inked(.regular) * 11 / 10, "the saved output draws the weight")
    }

    func testASingleWeightFontDrawsItsOneWeightWhateverTheRecipeSays() {
        let frame = CGSize(width: 1_000, height: 1_000)
        let regular = TextStage.layout(layer(font: .bebasNeue, weight: .regular), frameSize: frame).blockSize
        XCTAssertEqual(TextStage.layout(layer(font: .bebasNeue, weight: .bold), frameSize: frame).blockSize, regular)
    }

    // MARK: - Change background › Image

    @MainActor
    func testTheChooseAPhotoTileIsLast() {
        let bundled = BackgroundPanelModel.bundledImages.map(BackgroundPanelModel.ImageTile.bundled)
        XCTAssertEqual(BackgroundPanelModel.imageTiles(hasImportedPhoto: false), bundled + [.choosePhoto])
        XCTAssertEqual(BackgroundPanelModel.imageTiles(hasImportedPhoto: true), bundled + [.imported, .choosePhoto])
        // Owner amendment 2026-10-11 (third): the tiles fill the row, four across (LightLeakImageTests).
        XCTAssertEqual(BackgroundImageGrid<EmptyView>.tileSide(gridWidth: 343), (343 - 24) / 4)
        XCTAssertEqual(BackgroundImageGrid<EmptyView>.rowGap, 10)
        XCTAssertEqual(BackgroundImageGrid<EmptyView>.columnGap, 8)
    }
}

/// The weight row's edits on a real editor session.
@MainActor
final class TextWeightModelTests: XCTestCase {
    private var library: DevelopLibrary!

    override func setUp() async throws { library = try EditorTestSupport.library() }

    func testAWeightIsOneUndoStepAndSingleWeightFontsOnlyTakeRegular() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let model = TextPanelModel(session: session)
        model.addLayer(text: "Summer")
        XCTAssertEqual(model.selectedLayer?.weight, .regular, "new layers are regular")

        model.chooseWeight(.bold)
        XCTAssertEqual(model.selectedLayer?.weight, .bold)
        session.undo()
        XCTAssertEqual(model.selectedLayer?.weight, .regular, "one undo step")
        XCTAssertEqual(model.layers.count, 1, "the add is still there")

        model.chooseWeight(.thin)
        model.chooseFont(.bebasNeue)
        XCTAssertEqual(model.selectedLayer?.font, .bebasNeue)
        XCTAssertEqual(model.selectedLayer?.weight, .regular, "a single-weight font only takes regular")
        model.chooseWeight(.bold)
        XCTAssertEqual(model.selectedLayer?.weight, .regular, "greyed Bold does nothing")
        session.undo()
        XCTAssertEqual(model.selectedLayer?.font, TextPanelModel.newLayerFont)
        XCTAssertEqual(model.selectedLayer?.weight, .thin, "the font change and its weight reset were one step")
        session.close()
    }
}
