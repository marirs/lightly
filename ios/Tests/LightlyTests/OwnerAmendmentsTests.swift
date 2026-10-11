import CoreGraphics
import SwiftUI
import XCTest
@testable import Lightly

/// The owner amendments of 2026-10-11 below the interface: the recipe's two new keys (`tools.text`, `faceEdit.smile`),
/// Portrait › Smile's warp (rendering-v2 §7.3), the Text stage's layout (§7.4), the theme cycle and the dock's fade.
final class OwnerAmendmentsTests: XCTestCase {

    // MARK: - Recipe codec

    private func neutralFixture() throws -> EditRecipe {
        try EditRecipeCodec.decode(Data(contentsOf: DevelopParityTests.fixture("shared/fixtures/edit-recipe/neutral.json")))
    }

    private func layer(id: String = "0a1b2c3d", text: String = "Summer in Lisbon", size: Double = 42,
                       centre: EditRecipe.Point = .init(x: 0.5, y: 0.5), rotation: Double = 0) -> EditRecipe.TextLayer {
        EditRecipe.TextLayer(id: id, text: text, font: .playfairDisplay, size: size, colour: "#FFFFFF", opacity: 100,
                             centre: centre, rotation: rotation)
    }

    func testRecipesWithoutTheNewKeysReadAsNoTextAndNoSmile() throws {
        let recipe = try neutralFixture()
        XCTAssertEqual(recipe.tools.text, .none)
        let faces = try EditRecipeCodec.decode(Data(contentsOf: DevelopParityTests.fixture("shared/fixtures/edit-recipe/portrait-two-faces.json")))
        XCTAssertFalse(faces.tools.portrait.faces.isEmpty)
        XCTAssertTrue(faces.tools.portrait.faces.allSatisfy { $0.smile.amount == 0 })
    }

    func testTextAndSmileAreAlwaysWrittenAndRoundTrip() throws {
        var recipe = try neutralFixture()
        let written = String(decoding: EditRecipeCodec.encode(recipe), as: UTF8.self)
        XCTAssertTrue(written.hasSuffix(",\"text\":{\"layers\":[]}}}"), "an empty text tool is still written")

        recipe.tools.text.layers = [layer(), layer(id: "ffffffff", text: "2026\nLisbon", size: 10, centre: .init(x: 0, y: 1), rotation: -12.5)]
        recipe.tools.portrait.faces = [PortraitPanelModel.neutral(for: nil)]
        recipe.tools.portrait.faces[0].face.box = .init(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        recipe.tools.portrait.faces[0].smile.amount = -35
        let bytes = EditRecipeCodec.encode(recipe)
        let json = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(json.contains("\"teeth\":{\"brighten\":0},\"smile\":{\"amount\":-35},\"hair\":"), "smile in schema order")
        XCTAssertTrue(json.contains("{\"id\":\"0a1b2c3d\",\"text\":\"Summer in Lisbon\",\"font\":\"Playfair Display\",\"size\":42,\"colour\":\"#FFFFFF\",\"opacity\":100,\"centre\":[0.5,0.5],\"rotation\":0}"))
        XCTAssertEqual(try EditRecipeCodec.decode(bytes), recipe)
    }

    func testInvalidTextLayersAreRefused() throws {
        var recipe = try neutralFixture()
        recipe.tools.text.layers = [layer()]
        let good = String(decoding: EditRecipeCodec.encode(recipe), as: UTF8.self)
        for (bad, why) in [("\"id\":\"0A1B2C3D\"", "upper-case id"), ("\"size\":9", "size below 10"), ("\"size\":42.5", "size not an integer"),
                           ("\"text\":\"\"", "empty text"), ("\"font\":\"Lora\"", "not a Text font"), ("\"rotation\":181", "rotation past 180")] {
            let key = String(bad.prefix { $0 != ":" })
            // Only inside the text layers (the watermark and the light leak have keys of the same names).
            let layers = try XCTUnwrap(good.range(of: "\"layers\":["))
            let original = try XCTUnwrap(good.range(of: "\(key):[^,]*", options: .regularExpression, range: layers.upperBound..<good.endIndex), why)
            let broken = good.replacingCharacters(in: original, with: bad)
            XCTAssertThrowsError(try EditRecipeCodec.decode(Data(broken.utf8)), why)
        }
    }

    // MARK: - Smile warp (rendering-v2 §7.3)

    /// White with a dark three-pixel line along the mouth, y 99…101, corners at x 70 and 130 of 200.
    private func mouthLine() -> FloatImage {
        var image = FloatImage(width: 200, height: 200, channels: 3, repeating: 1)
        for y in 99...101 { for x in 40...160 { for c in 0..<3 { image.data[(y * 200 + x) * 3 + c] = 0 } } }
        return image
    }

    private let left = CGPoint(x: 70.0 / 200, y: 100.5 / 200), right = CGPoint(x: 130.0 / 200, y: 100.5 / 200)

    private func value(_ image: FloatImage, _ x: Int, _ y: Int) -> Float { image.data[(y * image.width + x) * 3] }

    func testSmileAmountZeroLeavesEveryPixelExactlyUnchanged() {
        let input = mouthLine()
        var output = input
        PortraitRenderer.warpSmile(&output, amount: 0, leftCorner: left, rightCorner: right)
        XCTAssertEqual(output.data, input.data)
    }

    func testPositiveSmileLiftsTheCornersAndLeavesTheRestUnchanged() {
        let input = mouthLine()
        var output = input
        PortraitRenderer.warpSmile(&output, amount: 100, leftCorner: left, rightCorner: right)
        // 0.10 × 60 px = 6 px up at the corners: the line now reaches above them.
        XCTAssertEqual(value(input, 70, 95), 1)
        XCTAssertLessThan(value(output, 70, 95), 0.5, "the left corner is lifted")
        XCTAssertLessThan(value(output, 130, 95), 0.5, "the right corner is lifted")
        // Outside both 27 px discs (r = 0.45 × 60): the mouth's middle, and far away, exactly unchanged.
        XCTAssertEqual(value(output, 100, 95), value(input, 100, 95))
        XCTAssertEqual(value(output, 100, 100), value(input, 100, 100))
        XCTAssertEqual(value(output, 10, 10), value(input, 10, 10))
        XCTAssertEqual(value(output, 70, 140), value(input, 70, 140))
    }

    func testNegativeSmileLowersTheCorners() {
        var output = mouthLine()
        PortraitRenderer.warpSmile(&output, amount: -100, leftCorner: left, rightCorner: right)
        XCTAssertLessThan(value(output, 70, 106), 0.5, "the corner is lowered")
        XCTAssertEqual(value(output, 70, 95), 1, "and not lifted")
    }

    func testMouthCornersAreTheOuterLipsExtremePoints() {
        let lips = [CGPoint(x: 0.5, y: 0.6), CGPoint(x: 0.42, y: 0.62), CGPoint(x: 0.5, y: 0.64), CGPoint(x: 0.58, y: 0.61)]
        let face = DetectedFace(box: .init(x: 0.3, y: 0.3, width: 0.4, height: 0.4), faceContour: [], leftEye: [], rightEye: [],
                                leftEyebrow: [], rightEyebrow: [], outerLips: lips, innerLips: [], quality: 1)
        let corners = face.mouthCorners
        XCTAssertEqual(corners?.left, CGPoint(x: 0.42, y: 0.62))
        XCTAssertEqual(corners?.right, CGPoint(x: 0.58, y: 0.61))
        let noMouth = DetectedFace(box: face.box, faceContour: [], leftEye: [], rightEye: [], leftEyebrow: [], rightEyebrow: [],
                                   outerLips: [], innerLips: [], quality: 1)
        XCTAssertNil(noMouth.mouthCorners)
    }

    func testSmileCountsAsAPortraitChange() {
        var edit = PortraitPanelModel.neutral(for: nil)
        XCTAssertFalse(PortraitRenderer.hasChanges(edit))
        edit.smile.amount = -1
        XCTAssertTrue(PortraitRenderer.hasChanges(edit))
        XCTAssertFalse(PortraitRenderer.hasRetouch(edit), "a smile alone runs no tonal operator")
    }

    // MARK: - Text layout (rendering-v2 §7.4)

    func testTextFontsAreAllBundled() {
        XCTAssertTrue(TextFonts.allBundled)
    }

    func testFontSizeIsAFractionOfTheShortEdgeAndTheBlockIsCentred() {
        let frame = CGSize(width: 1_200, height: 800)
        let layout = TextStage.layout(layer(size: 42, centre: .init(x: 0.25, y: 0.75)), frameSize: frame)
        XCTAssertEqual(layout.fontSize, 0.42 * 0.25 * 800, accuracy: 1e-9)
        XCTAssertEqual(layout.centre, CGPoint(x: 300, y: 600))
        XCTAssertGreaterThan(layout.blockSize.width, 0)
        XCTAssertEqual(layout.blockSize.height, layout.lineHeight, accuracy: 1e-9, "one line")
        XCTAssertTrue(layout.contains(CGPoint(x: 300, y: 600)))
        XCTAssertFalse(layout.contains(CGPoint(x: 300 + layout.blockSize.width / 2 + 2, y: 600)))
    }

    func testTheLayoutCoversTheSamePartOfTheFrameAtAnyResolution() {
        let text = layer(text: "Summer in Lisbon\n2026", size: 60, centre: .init(x: 0.4, y: 0.3), rotation: 20)
        let small = TextStage.layout(text, frameSize: CGSize(width: 400, height: 300))
        let large = TextStage.layout(text, frameSize: CGSize(width: 4_000, height: 3_000))
        // Within 0.5 % of the short edge (§7.4).
        XCTAssertEqual(large.blockSize.width / 10, small.blockSize.width, accuracy: 0.005 * 300)
        XCTAssertEqual(large.blockSize.height / 10, small.blockSize.height, accuracy: 0.005 * 300)
        XCTAssertEqual(small.blockSize.height, 2 * small.lineHeight, accuracy: 1e-9, "two lines")
    }

    func testTurnedBlocksAreHitClockwise() {
        // A long single line turned 90° clockwise stands upright: a point below the centre is on it, one beside is not.
        let turned = TextStage.layout(layer(text: "WWWWWWWWWW", size: 20, rotation: 90), frameSize: CGSize(width: 1_000, height: 1_000))
        XCTAssertTrue(turned.contains(CGPoint(x: 500, y: 500 + turned.blockSize.width / 2 - 5)))
        XCTAssertFalse(turned.contains(CGPoint(x: 500 + turned.blockSize.width / 2 - 5, y: 500)))
    }

    func testTheStageDrawsInsideTheBlockAndNowhereElse() {
        let width = 300, height = 200
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        let text = layer(text: "HHHH", size: 50, centre: .init(x: 0.5, y: 0.5))
        TextStage.apply(.init(layers: [text]), pixels: &pixels, width: width, height: height)
        let box = TextStage.layout(text, frameSize: CGSize(width: width, height: height))
        var inside = 0, outside = 0
        for y in 0..<height { for x in 0..<width where pixels[(y * width + x) * 4] > 0 {
            if box.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), slop: 1) { inside += 1 } else { outside += 1 }
        } }
        XCTAssertGreaterThan(inside, 100, "white glyphs are drawn")
        XCTAssertEqual(outside, 0, "nothing outside the text block")
        var untouched = [UInt8](repeating: 9, count: 16)
        TextStage.apply(.none, pixels: &untouched, width: 2, height: 2)
        XCTAssertEqual(untouched, [UInt8](repeating: 9, count: 16), "no layers: unchanged")
    }

    // MARK: - Theme cycle and dock

    func testDoubleTapCyclesSystemLightDarkSystem() {
        XCTAssertEqual(AppearancePreference.system.next, .light)
        XCTAssertEqual(AppearancePreference.light.next, .dark)
        XCTAssertEqual(AppearancePreference.dark.next, .system)
        XCTAssertEqual(AppearancePreference.allCases.map(\.cycleToast), ["System theme", "Light theme", "Dark theme"])
    }

    func testTheDockFadesTowardsTheHiddenTools() {
        var dock = DockOverflow(content: CGRect(x: 0, y: 0, width: 8 * 58 + 12, height: 62), viewportWidth: 390)
        XCTAssertEqual(dock.maskStops.map(\.location), [0.91, 1], "more to the right: the trailing fade")
        dock.content.origin.x = 390 - dock.content.width
        XCTAssertEqual(dock.maskStops.map(\.location), [0, 0.12], "scrolled to the end: the leading fade")
        dock = DockOverflow(content: CGRect(x: 0, y: 0, width: 7 * 58 + 12, height: 62), viewportWidth: 430)
        XCTAssertEqual(dock.maskStops.map(\.color), [.black, .black], "everything in view: no fade")
        XCTAssertEqual(ToolNavigation.itemWidth, 58)
    }

    func testTheTextIconIsTheMockupPath() {
        guard case .path(let data, _)? = ApprovedIcon.text.elements.first else { return XCTFail("a stroked path") }
        XCTAssertEqual(data, "M5 7V5h14v2M12 5v14M9 19h6")
    }

    func testTheSelectedTabPillColoursAreTheMockups() {
        XCTAssertEqual(ApprovedColor.pill.light, 0xCFF26B); XCTAssertEqual(ApprovedColor.pill.lightAlpha, 0.45)
        XCTAssertEqual(ApprovedColor.pill.darkAlpha, 0.17)
        XCTAssertEqual(ApprovedColor.pillInk.light, 0x141513); XCTAssertEqual(ApprovedColor.pillInk.dark, 0xE2F99F)
        XCTAssertEqual(L2Tabs<Int>.leadingPull, 12)
    }
}

/// The Text panel's model on a real editor session: each change is one undo step.
@MainActor
final class TextPanelModelTests: XCTestCase {
    private var library: DevelopLibrary!

    override func setUp() async throws { library = try EditorTestSupport.library() }

    func testAddEditDeleteAndMoveAreOneUndoStepEach() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let model = TextPanelModel(session: session)
        XCTAssertFalse(session.canUndo)

        // Add: the sheet's Done; blank text adds nothing.
        model.openAdd()
        XCTAssertEqual(model.sheet, .add)
        model.finishSheet(with: "   \n ")
        XCTAssertTrue(model.layers.isEmpty)
        XCTAssertNil(model.sheet)
        model.openAdd()
        model.finishSheet(with: " Summer in Lisbon ")
        let added = try XCTUnwrap(model.layers.first)
        XCTAssertEqual(added.text, "Summer in Lisbon")
        XCTAssertEqual(added.font, .playfairDisplay); XCTAssertEqual(added.size, 42); XCTAssertEqual(added.colour, "#FFFFFF")
        XCTAssertEqual(added.opacity, 100); XCTAssertEqual(added.centre, .init(x: 0.5, y: 0.5)); XCTAssertEqual(added.rotation, 0)
        XCTAssertNotNil(added.id.range(of: "^[0-9a-f]{8}$", options: .regularExpression))
        XCTAssertEqual(model.selectedLayer?.id, added.id)
        XCTAssertTrue(session.canUndo)

        // Edit the words.
        model.openEditSelected()
        XCTAssertEqual(model.sheetInitialText, "Summer in Lisbon")
        model.finishSheet(with: "Lisbon")
        XCTAssertEqual(model.layers.first?.text, "Lisbon")
        session.undo()
        XCTAssertEqual(model.layers.first?.text, "Summer in Lisbon", "one step back to the old words")
        session.redo()

        // Move: many finger updates, one step.
        model.beginGesture(on: added.id)
        for step in 1...10 { model.moveDraft(byFraction: CGSize(width: 0.02 * Double(step), height: -0.01 * Double(step))) }
        XCTAssertEqual(model.layers.first?.centre, .init(x: 0.5, y: 0.5), "previewed, not committed, while moving")
        model.endGesture()
        let moved = try XCTUnwrap(model.layers.first?.centre)
        XCTAssertEqual(moved.x, 0.7, accuracy: 1e-9); XCTAssertEqual(moved.y, 0.4, accuracy: 1e-9)
        session.undo()
        XCTAssertEqual(model.layers.first?.centre, .init(x: 0.5, y: 0.5), "the whole move is one step")
        session.redo()

        // Pinch and turn, then the handle: each gesture one step; size stays within 10…100.
        model.beginGesture(on: added.id)
        model.transformDraft(scale: 3, degrees: 200)
        model.endTransform(); model.endGesture()
        XCTAssertEqual(model.layers.first?.size, 100)
        XCTAssertEqual(model.layers.first?.rotation, -160)
        session.undo()
        XCTAssertEqual(model.layers.first?.size, 42)
        session.redo()

        // A moved centre is clamped to the frame.
        model.beginGesture(on: added.id)
        model.moveDraft(byFraction: CGSize(width: 5, height: -5))
        model.endGesture()
        XCTAssertEqual(model.layers.first?.centre, .init(x: 1, y: 0))

        // Delete.
        model.deleteLayer(added.id)
        XCTAssertTrue(model.layers.isEmpty)
        session.undo()
        XCTAssertEqual(model.layers.first?.id, added.id, "Undo brings the layer back with its id")
        XCTAssertEqual(model.selectedLayer?.id, added.id)
        session.close()
    }

    /// Owner report 2026-10-11 (resizing "wasn't smooth"): a gesture renders the photo once at touch-down (without the
    /// layer) and once at the end, never per finger update; the stage draws the layer meanwhile and until the
    /// committed render is on screen. The size follows the finger unrounded and is a whole number once committed.
    func testAGestureRendersTwiceAndTheStageDrawsTheLayerUntilTheCommitIsShown() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let model = TextPanelModel(session: session)
        model.addLayer(text: "Summer")
        let layer = try XCTUnwrap(model.layers.first)
        await session.settleRendering()
        XCTAssertNil(model.liveLayer, "no gesture: the rendered photo shows the text")

        let beforeGesture = session.latestRenderGeneration
        model.beginGesture(on: layer.id)
        XCTAssertEqual(session.latestRenderGeneration, beforeGesture + 1, "one render without the layer at touch-down")
        for step in 1...30 {
            model.transformDraft(handleFrom: CGPoint(x: 110, y: 110), to: CGPoint(x: 110 + Double(step), y: 110 + Double(step)),
                                 centre: CGPoint(x: 100, y: 100))
        }
        XCTAssertEqual(session.latestRenderGeneration, beforeGesture + 1, "finger updates never re-render the photo")
        let live = try XCTUnwrap(model.liveLayer, "the stage draws the layer under the finger")
        XCTAssertEqual(live.size, 100, "the distance ratio (40 / 10 × 42) clamped to the largest size")
        model.endTransform(); model.endGesture()
        XCTAssertEqual(session.latestRenderGeneration, beforeGesture + 2, "one render of the committed edit")
        XCTAssertEqual(model.layers.first?.size, 100)
        await session.settleRendering()
        XCTAssertNil(model.liveLayer, "the committed render is on screen: the stage stops drawing the layer")
        session.close()
    }

    func testTheResizeTracksTheFingerUnroundedAndCommitsAWholeSize() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let model = TextPanelModel(session: session)
        model.addLayer(text: "Summer")
        let layer = try XCTUnwrap(model.layers.first)
        model.beginGesture(on: layer.id)
        model.transformDraft(scale: 1.01, degrees: 0)
        XCTAssertEqual(try XCTUnwrap(model.liveLayer).size, 42.42, accuracy: 1e-9, "no whole-number steps while resizing")
        model.endTransform(); model.endGesture()
        XCTAssertEqual(model.layers.first?.size, 42, "the recipe keeps whole sizes")
        session.close()
    }

    /// A touch the system cancels never reports its end: the marks finish the open gesture, committing it once.
    func testCancelledTouchesStillCommitTheGestureOnce() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let model = TextPanelModel(session: session)
        model.addLayer(text: "Summer")
        let layer = try XCTUnwrap(model.layers.first)
        model.beginGesture(on: layer.id)
        model.beginGesture(on: layer.id)
        model.moveDraft(byFraction: CGSize(width: 0.1, height: 0))
        XCTAssertTrue(model.isGestureActive)
        model.endAllGestures()
        XCTAssertFalse(model.isGestureActive)
        XCTAssertEqual(try XCTUnwrap(model.layers.first?.centre.x), 0.6, accuracy: 1e-9)
        session.undo()
        XCTAssertEqual(model.layers.first?.centre, .init(x: 0.5, y: 0.5), "one undo step")
        model.endGesture()
        XCTAssertEqual(model.layers.first?.centre, .init(x: 0.5, y: 0.5), "a late end changes nothing")
        session.close()
    }

    func testResetAllClearsTheTexts() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let model = TextPanelModel(session: session)
        model.addLayer(text: "One")
        model.addLayer(text: "Two")
        XCTAssertEqual(model.layers.map(\.text), ["One", "Two"])
        XCTAssertEqual(model.selectedLayer?.text, "Two", "the new layer is selected")
        XCTAssertTrue(session.canReset(section: "all"))
        session.resetEdits()
        XCTAssertTrue(model.layers.isEmpty)
        session.close()
    }

    func testTheTextIsInTheSavedCopy() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        let before = try await session.exportedData()
        TextPanelModel(session: session).addLayer(text: "HHHH")
        await session.settleRendering()
        let after = try await session.exportedData()
        XCTAssertNotEqual(before, after, "stage 11 draws into the export")
        session.close()
    }
}

/// The ✕ and corner handle of the selected text (owner report 2026-10-11, "did not see the handle properly").
@MainActor
final class TextHandlePlacementTests: XCTestCase {
    private let canvas = CGSize(width: 300, height: 400)

    func testKnobsSitOnTheTurnedOutlinesCorners() {
        let upright = TextLayerMarks.knobCentre(corner: CGPoint(x: 50, y: 20), centre: CGPoint(x: 150, y: 200), rotation: 0, canvas: canvas)
        XCTAssertEqual(upright.x, 200, accuracy: 1e-9); XCTAssertEqual(upright.y, 220, accuracy: 1e-9)
        // A quarter turn clockwise (y down): the bottom-trailing corner goes to the bottom-leading side.
        let turned = TextLayerMarks.knobCentre(corner: CGPoint(x: 50, y: 20), centre: CGPoint(x: 150, y: 200), rotation: .pi / 2, canvas: canvas)
        XCTAssertEqual(turned.x, 130, accuracy: 1e-9); XCTAssertEqual(turned.y, 250, accuracy: 1e-9)
    }

    func testKnobsPastTheStageStayWhollyVisible() {
        // A text at the top-leading corner: its ✕ would sit outside the stage; it is kept 3 pt inside the canvas
        // (the stage reaches 8 pt past it, the knob's radius is 11 pt).
        let delete = TextLayerMarks.knobCentre(corner: CGPoint(x: -80, y: -30), centre: CGPoint(x: 10, y: 5), rotation: 0, canvas: canvas)
        XCTAssertEqual(delete, CGPoint(x: 3, y: 3))
        let handle = TextLayerMarks.knobCentre(corner: CGPoint(x: 80, y: 30), centre: CGPoint(x: 290, y: 395), rotation: 0, canvas: canvas)
        XCTAssertEqual(handle, CGPoint(x: 297, y: 397))
    }
}

/// Edit › Remove (owner report 2026-10-11, "the brush is still present on the top").
@MainActor
final class RemoveStrokeMarkTests: XCTestCase {
    func testOnlyTheStrokeUnderTheFingerIsDrawn() {
        XCTAssertTrue(RemoveStrokesMark.strokesShown(brushing: [], brushRadius: 0.03).isEmpty,
                      "no finger down: nothing over the photo, whatever has been removed")
        let brushing: [EditRecipe.Point] = [.init(x: 0.2, y: 0.3), .init(x: 0.4, y: 0.3)]
        let shown = RemoveStrokesMark.strokesShown(brushing: brushing, brushRadius: 0.03)
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(shown.first?.points, brushing)
        XCTAssertEqual(shown.first?.radius, 0.03)
    }
}
