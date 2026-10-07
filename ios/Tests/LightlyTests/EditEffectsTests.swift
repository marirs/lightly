import CoreGraphics
import ImageIO
import XCTest
@testable import Lightly

/// Slice 4: Edit (geometry, Adjust, Remove) and Effects — the stage maths, Remove's patches with a
/// stand-in model, and the editing session (whole-recipe undo, preview and export of one recipe).
@MainActor
final class EditEffectsStageTests: XCTestCase {

    private func neutral() -> EditRecipe.Tools { .neutral(grainSeed: 7) }

    /// A W × H RGBA8 image whose red channel encodes x and green y (each 0…255 across the image).
    private func ramp(_ width: Int, _ height: Int) -> [UInt8] {
        var p = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                p[o] = UInt8(x * 255 / max(width - 1, 1)); p[o + 1] = UInt8(y * 255 / max(height - 1, 1)); p[o + 2] = 128
            }
        }
        return p
    }

    // MARK: Geometry

    func testNeutralGeometryIsTheIdentity() {
        let t = GeometryTransform(neutral().edit.geometry, sourceWidth: 30, sourceHeight: 20)
        XCTAssertTrue(t.isIdentity)
        let pixels = ramp(30, 20)
        XCTAssertEqual(t.render(pixels, width: 30, height: 20).pixels, pixels)
    }

    func testAQuarterTurnRightSwapsTheSidesAndPutsTheLeftEdgeOnTop() {
        var g = neutral().edit.geometry
        g.quarterTurns = 1
        let t = GeometryTransform(g, sourceWidth: 40, sourceHeight: 20)
        XCTAssertEqual(t.frameWidth, 20); XCTAssertEqual(t.frameHeight, 40)
        // Source top-left goes to the frame's top-right after a clockwise turn.
        let p = t.frame(fromSource: CGPoint(x: 0, y: 0))
        XCTAssertEqual(p.x, 1, accuracy: 1e-9); XCTAssertEqual(p.y, 0, accuracy: 1e-9)
        let out = t.render(ramp(40, 20), width: 40, height: 20)
        XCTAssertEqual(out.width, 20); XCTAssertEqual(out.height, 40)
        // Top row of the frame: source x = 0 (red 0) along the top, so its red is small everywhere.
        XCTAssertLessThan(out.pixels[0], 10)
        XCTAssertGreaterThan(out.pixels[(39 * 20) * 4], 245, "Bottom-left of the frame is the source's right edge")
    }

    func testFlipHorizontalMirrors() {
        var g = neutral().edit.geometry
        g.flipHorizontal = true
        let out = GeometryTransform(g, sourceWidth: 32, sourceHeight: 8).render(ramp(32, 8), width: 32, height: 8)
        XCTAssertGreaterThan(out.pixels[0], 245, "The left edge now shows the source's right edge")
    }

    func testStraightenZoomIsTheSmallestThatLeavesNoEmptyCorner() {
        // 3:2 at −3°: cos 3° + 1.5 · sin 3°.
        let zoom = GeometryTransform.straightenZoom(degrees: -3, width: 1600, height: 1067)
        XCTAssertEqual(zoom, cos(3 * .pi / 180) + 1600.0 / 1067 * sin(3 * .pi / 180), accuracy: 1e-9)
        var g = neutral().edit.geometry
        g.straighten = -3
        let t = GeometryTransform(g, sourceWidth: 1600, sourceHeight: 1067)
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)] {
            let s = t.source(fromFrame: corner)
            XCTAssertTrue((-1e-9...1 + 1e-9).contains(s.x) && (-1e-9...1 + 1e-9).contains(s.y), "corner \(corner) maps inside the photo")
        }
    }

    func testPerspectiveLeavesNoEmptyAreaAndNarrowsTheTop() {
        var g = neutral().edit.geometry
        g.perspectiveVertical = 18
        let t = GeometryTransform(g, sourceWidth: 1200, sourceHeight: 1600)
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)] {
            let s = t.source(fromFrame: corner)
            XCTAssertTrue((-1e-6...1 + 1e-6).contains(s.x) && (-1e-6...1 + 1e-6).contains(s.y), "corner \(corner) inside")
        }
        // The top edge is narrowed: the frame's top corners reach further out in the source than
        // the bottom ones.
        let topLeft = t.source(fromFrame: CGPoint(x: 0, y: 0)), bottomLeft = t.source(fromFrame: CGPoint(x: 0, y: 1))
        XCTAssertLessThan(topLeft.x, bottomLeft.x)
    }

    func testCropAspectIsTheLargestCentredRectAndPointsRoundTrip() {
        let rect = GeometryTransform.centredRect(aspect: 4.0 / 5, width: 1067, height: 1600)
        XCTAssertEqual(rect.width * 1067 / (rect.height * 1600), 0.8, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 1, accuracy: 1e-9)
        var g = neutral().edit.geometry
        g.cropAspect = .fourFive; g.cropRect = rect; g.straighten = 7; g.quarterTurns = 3; g.flipVertical = true
        let t = GeometryTransform(g, sourceWidth: 1067, sourceHeight: 1600)
        let p = CGPoint(x: 0.3, y: 0.6)
        let back = t.frame(fromSource: t.source(fromFrame: p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9); XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
    }

    // MARK: Adjust

    func testAdjustMapsOntoTheDevelopModelAsTheContractStates() throws {
        var a = neutral().edit.adjust
        a.exposure = 50; a.contrast = 10; a.temp = 15; a.tint = -4; a.vibrance = 12; a.sharpness = 30; a.clarity = 15; a.noise = 20
        let global = AdjustStage.colourRecipe(a)
        XCTAssertEqual(global.exposureEV, 1)
        XCTAssertEqual(global.toneSliders?.contrast, 10)
        XCTAssertEqual(global.whiteBalance, .init(temperature: 15, tint: -4))
        XCTAssertEqual(global.vibranceSaturation, .init(vibrance: 12, saturation: 0))
        let spatial = AdjustStage.detailSpatial(a)
        XCTAssertEqual(spatial.sharpening, .init(amount: 30, radius: 1.0, detail: 25, edgeMasking: 0))
        XCTAssertEqual(spatial.clarity, 15)
        XCTAssertEqual(spatial.noiseReduction?.luminance, 20); XCTAssertEqual(spatial.noiseReduction?.color, 20)
        XCTAssertNil(AdjustStage.colourLUT(neutral().edit.adjust, model: try EditorTestSupport.model()))
        // +1 EV brightens mid-grey.
        let lut = try XCTUnwrap(AdjustStage.colourLUT(.init(exposure: 50, contrast: 0, highlights: 0, shadows: 0, temp: 0, tint: 0,
                                                            saturation: 0, vibrance: 0, sharpness: 0, clarity: 0, noise: 0),
                                                      model: try EditorTestSupport.model()))
        XCTAssertGreaterThan(DevelopFrameRenderer.lookup(lut, SIMD3(0.4, 0.4, 0.4)).x, 0.5)
    }

    // MARK: Effects

    func testUserVignetteDarkensTheCornersAndLeavesTheCentre() throws {
        var fx = neutral().effects
        fx.vignette.enabled = true
        let stage = EffectsStage(effects: fx, presetFinishing: .init(), presetStrength: 0, frameWidth: 101, frameHeight: 101,
                                 model: try EditorTestSupport.model())
        let grey = [UInt8](repeating: 128, count: 101 * 101 * 4)
        let out = stage.apply(grey, width: 101, height: 101)
        XCTAssertEqual(out[(50 * 101 + 50) * 4], 128, "Centre unchanged")
        XCTAssertLessThan(out[0], 120, "Corner darkened")
    }

    func testUserGrainIsAddedOnTopOfThePresetsAndIsRepeatable() throws {
        let model = try EditorTestSupport.model()
        var fx = neutral().effects
        fx.grain.enabled = true
        let preset = PresetRecipe.Finishing(vignette: nil, grain: .init(amount: 30, size: 25, roughness: 50, seed: 99))
        let grey = [UInt8](repeating: 128, count: 64 * 48 * 4)
        let presetOnly = EffectsStage(effects: neutral().effects, presetFinishing: preset, presetStrength: 1, frameWidth: 64, frameHeight: 48, model: model)
        let both = EffectsStage(effects: fx, presetFinishing: preset, presetStrength: 1, frameWidth: 64, frameHeight: 48, model: model)
        XCTAssertNotNil(both.presetGrain, "The preset's grain stays when the person's grain is on")
        XCTAssertNotNil(both.userGrain)
        let a = both.apply(grey, width: 64, height: 48), b = both.apply(grey, width: 64, height: 48)
        XCTAssertEqual(a, b, "The seed is fixed, so every render has the same grain")
        XCTAssertNotEqual(a, presetOnly.apply(grey, width: 64, height: 48))
        XCTAssertEqual(EffectsStage.userGrain(.init(enabled: true, style: .coarse, amount: 30, size: 80, roughness: 50, seed: 1)).size, 100,
                       "Coarse scales size by 1.5, capped at 100")
    }

    func testLightLeakBrightensAroundItsCentreOnly() {
        let leak = EditRecipe.Effects.LightLeak(enabled: true, style: .warm, intensity: 55, x: 18, y: 14, rotation: 0)
        let evaluator = LightLeakEvaluator(leak, frameWidth: 300, frameHeight: 200)!
        let grey = SIMD3<Float>(repeating: 0.3)
        let atCentre = evaluator.apply(grey, x: 54, y: 28)
        XCTAssertGreaterThan(atCentre.x, 0.5); XCTAssertGreaterThan(atCentre.x, atCentre.z, "Warm")
        XCTAssertEqual(evaluator.apply(grey, x: 299, y: 199), grey, "Beyond 55 % of the farthest-corner ray: unchanged")
    }

    // MARK: Remove

    func testARemovePatchChangesOnlyTheBrushAndItsFeather() async throws {
        let width = 900, height = 600
        var source = ramp(width, height)
        let stroke = EditRecipe.RemoveStroke(radius: 0.02, points: [.init(x: 0.5, y: 0.5), .init(x: 0.6, y: 0.52)], status: .applied, patch: nil)
        let patch = try await RemoveEngine.patch(for: stroke, source: source, width: width, height: height, inpainter: FlatInpainter())
        let before = source
        RemoveEngine.composite([patch], into: &source, width: width, height: height)
        let radius = 0.02 * 900.0
        let points = stroke.points.map { SIMD2($0.x * Double(width), $0.y * Double(height)) }
        var changedInside = 0
        for y in 0..<height {
            for x in 0..<width {
                let d = RemoveEngine.distance(SIMD2(Double(x) + 0.5, Double(y) + 0.5), toPolyline: points)
                let o = (y * width + x) * 4
                if d > radius + RemoveEngine.featherPixels + 1 {
                    XCTAssertEqual(source[o..<o + 3], before[o..<o + 3], "(\(x), \(y)) outside the brush changed")
                    if source[o..<o + 3] != before[o..<o + 3] { return }
                } else if d < radius - 1, source[o] == 200 { changedInside += 1 }
            }
        }
        XCTAssertGreaterThan(changedInside, 500, "The brushed area takes the model's pixels")
    }

    func testThePreviewCompositesTheSamePatchScaled() async throws {
        let width = 800, height = 600
        let source = ramp(width, height)
        let stroke = EditRecipe.RemoveStroke(radius: 0.03, points: [.init(x: 0.4, y: 0.4)], status: .applied, patch: nil)
        let patch = try await RemoveEngine.patch(for: stroke, source: source, width: width, height: height, inpainter: FlatInpainter())
        var preview = ramp(400, 300)
        RemoveEngine.composite([patch], into: &preview, width: 400, height: 300)
        let o = (120 * 400 + 160) * 4
        XCTAssertEqual(Int(preview[o]), 200, accuracy: 1, "The stroke's centre at half size shows the patch")
    }

    /// A deterministic, non-smooth test photo (opaque), so every bilinear neighbour matters.
    private func noise(_ width: Int, _ height: Int, seed: Int) -> [UInt8] {
        var p = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let x = i % width, y = i / width
            for c in 0..<3 { p[i * 4 + c] = UInt8((x * 3 + y * 5 + seed * 11 + c * 40 + (x * y) % 7) % 251) }
        }
        return p
    }

    /// The photo as the app holds it: a CGImage, either bitmap-backed or decoded from a JPEG by ImageIO.
    private func photo(_ pixels: [UInt8], _ width: Int, _ height: Int, jpeg: Bool) throws -> CGImage {
        let bitmap = try MetalLUTRenderer.makeImage(rgba8: pixels, width: width, height: height)
        guard jpeg else { return bitmap }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, bitmap, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testRemoveFromBandsOfThePhotoGivesTheWholeBufferPatchByteForByte() async throws {
        let strokes: [[EditRecipe.Point]] = [[.init(x: 0.5, y: 0.5), .init(x: 0.6, y: 0.55)], [.init(x: 0.02, y: 0.03)],
                                             [.init(x: 0.98, y: 0.97), .init(x: 0.9, y: 0.99)], [.init(x: 0.1, y: 0.9), .init(x: 0.9, y: 0.1)]]
        for (width, height) in [(300, 200), (700, 520), (1500, 1100)] {
            for jpeg in [false, true] {
                let image = try photo(noise(width, height, seed: width), width, height, jpeg: jpeg)
                let whole = try MetalLUTRenderer.rgba8Bytes(of: image)
                // An earlier fill under the new stroke: composited into the whole buffer, or into each band.
                let earlier = try await RemoveEngine.patch(for: .init(radius: 0.03, points: [.init(x: 0.52, y: 0.5)], status: .applied, patch: nil),
                                                           source: whole, width: width, height: height, inpainter: FlatInpainter())
                var composited = whole
                RemoveEngine.composite([earlier], into: &composited, width: width, height: height)
                for (k, points) in strokes.enumerated() {
                    let stroke = EditRecipe.RemoveStroke(radius: 12.0 / Double(max(width, height)), points: points, status: .applied, patch: nil)
                    let expected = try await RemoveEngine.patch(for: stroke, source: composited, width: width, height: height, inpainter: InvertingInpainter())
                    let actual = try await RemoveEngine.patch(for: stroke, image: image, earlier: [earlier], inpainter: InvertingInpainter())
                    let label = "\(width)x\(height) jpeg \(jpeg) stroke \(k)"
                    XCTAssertEqual([actual.x, actual.y, actual.width, actual.height], [expected.x, expected.y, expected.width, expected.height], label)
                    XCTAssertTrue(actual.rgba == expected.rgba, "\(label): patch pixels differ")
                }
            }
        }
    }

    func testAMissingModelFailsTheStrokeWithoutAnyFill() async throws {
        let failing = FailingInpainter()
        do {
            _ = try await RemoveEngine.patch(for: .init(radius: 0.02, points: [.init(x: 0.5, y: 0.5)], status: .applied, patch: nil),
                                             source: ramp(100, 100), width: 100, height: 100, inpainter: failing)
            XCTFail("expected a failure")
        } catch { }
    }
}

/// A stand-in model: fills everything with one colour (200, 200, 200).
struct FlatInpainter: Inpainting {
    let model = EditRecipe.ModelRef(id: "test-flat", version: "1")
    func inpaint(image: [Float], mask: [Float], side: Int) async throws -> [Float] {
        [Float](repeating: 200.0 / 255, count: 3 * side * side)
    }
}

/// The inverted input as the fill, so the patch depends on every sampled source pixel.
struct InvertingInpainter: Inpainting {
    let model = EditRecipe.ModelRef(id: "test-invert", version: "1")
    func inpaint(image: [Float], mask: [Float], side: Int) async throws -> [Float] { image.map { 1 - $0 } }
}

struct FailingInpainter: Inpainting {
    let model = EditRecipe.ModelRef(id: "test-failing", version: "1")
    func inpaint(image: [Float], mask: [Float], side: Int) async throws -> [Float] {
        throw RemoveEngine.Failure.modelFailed("test")
    }
}

/// The editing session with Edit and Effects.
@MainActor
final class EditEffectsSessionTests: XCTestCase {

    private var library: DevelopLibrary!

    override func setUp() async throws { library = try EditorTestSupport.library() }

    func testEditAndEffectsAreWholeRecipeUndoSteps() async throws {
        let session = try await EditorTestSupport.readySession(library: library)
        session.commitEdit { $0.adjust.exposure = 20 }
        session.commitEffects { $0.vignette.enabled = true }
        session.setCropAspect(.square)
        XCTAssertEqual(session.recipe.tools.edit.geometry.cropAspect, .square)
        session.undo()
        XCTAssertEqual(session.recipe.tools.edit.geometry.cropAspect, .original)
        XCTAssertTrue(session.recipe.tools.effects.vignette.enabled)
        session.undo()
        XCTAssertFalse(session.recipe.tools.effects.vignette.enabled)
        XCTAssertEqual(session.recipe.tools.edit.adjust.exposure, 20, "Undo restores the whole recipe, one step at a time")
        session.redo(); session.redo()
        XCTAssertEqual(session.recipe.tools.edit.geometry.cropAspect, .square)
        await session.settleRendering()
        XCTAssertEqual(session.displayedImage.width, session.displayedImage.height, "The preview is cropped square")
    }

    func testPreviewAndExportRenderTheSameCommittedRecipe() async throws {
        let session = try await EditorTestSupport.readySession(library: library, previewLongEdge: 640)
        session.setCropAspect(.sixteenNine)
        session.commitEdit { $0.geometry.straighten = 5; $0.adjust.contrast = 30 }
        session.commitEffects { $0.vignette.enabled = true; $0.lightLeak.enabled = true }
        await session.settleRendering()
        let data = try await session.exportedData()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(Double(exported.width) / Double(exported.height), 16.0 / 9, accuracy: 0.01)
        let preview = session.displayedImage
        XCTAssertEqual(Double(preview.width) / Double(preview.height), 16.0 / 9, accuracy: 0.02)
        // Same recipe: the exported photo, scaled down, matches the preview closely.
        let a = EditorTestSupport.mean(preview), b = EditorTestSupport.mean(exported)
        XCTAssertEqual(a.x, b.x, accuracy: 0.02); XCTAssertEqual(a.y, b.y, accuracy: 0.02); XCTAssertEqual(a.z, b.z, accuracy: 0.02)
    }

    /// Selective Colour: a pick keeps the colour sampled before the effect, turns the rest black and white
    /// in the preview and the saved copy alike, and is one undo step.
    func testSelectiveColourPickIsOneStepAndGreysTheRest() async throws {
        let session = try await EditorTestSupport.readySession(library: library, previewLongEdge: 480)
        await session.settleRendering()
        let before = Self.meanChroma(session.displayedImage)
        session.pickSelectiveColour(frameX: 0.5, frameY: 0.5)
        await session.settleRendering()
        let kept = try XCTUnwrap(session.recipe.tools.effects.selectiveColour.colours.first)
        XCTAssertTrue(kept.oklab.x.isFinite && kept.oklab.y.isFinite && kept.oklab.z.isFinite)
        XCTAssertEqual(kept.x, 0.5, accuracy: 1e-9); XCTAssertEqual(kept.y, 0.5, accuracy: 1e-9)
        let after = Self.meanChroma(session.displayedImage)
        XCTAssertLessThan(after, before, "Outside the kept colour the preview is black and white")
        let data = try await session.exportedData()
        let exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil)), 0, nil))
        XCTAssertEqual(Self.meanChroma(exported), after, accuracy: 0.03, "The saved copy matches the preview")
        session.undo()
        XCTAssertTrue(session.recipe.tools.effects.selectiveColour.colours.isEmpty, "One pick is one undo step")
    }

    private func keptColours(_ session: EditorSession) -> [EditRecipe.Effects.SelectiveColour.Kept] {
        session.recipe.tools.effects.selectiveColour.colours
    }

    /// Clear while another pick is still sampling: the late result must not bring Selective Colour back.
    func testClearDuringSamplingDiscardsThePendingPick() async throws {
        let session = try await EditorTestSupport.readySession(library: library, previewLongEdge: 480)
        session.pickSelectiveColour(frameX: 0.5, frameY: 0.5)
        await session.settleRendering()
        XCTAssertEqual(keptColours(session).count, 1)
        session.pickSelectiveColour(frameX: 0.2, frameY: 0.8)   // still sampling…
        session.clearSelectiveColour()                         // …when Clear is tapped
        await session.settleRendering()
        XCTAssertTrue(keptColours(session).isEmpty, "a pick sampled before Clear is discarded")
    }

    /// Undo while a pick is still sampling: the late result must not land on the undone edit.
    func testUndoDuringSamplingDiscardsThePendingPick() async throws {
        let session = try await EditorTestSupport.readySession(library: library, previewLongEdge: 480)
        session.commitEffects { $0.vignette.enabled = true }
        session.pickSelectiveColour(frameX: 0.5, frameY: 0.5)
        session.undo()
        await session.settleRendering()
        XCTAssertTrue(keptColours(session).isEmpty)
        XCTAssertFalse(session.recipe.tools.effects.vignette.enabled, "Undo stays undone")
        XCTAssertTrue(session.canRedo, "the redo step is not destroyed by a late pick")
    }

    /// Moving Range (not released) while a pick is held in sampling: the pick is discarded when it completes and the
    /// slider's preview stays on screen (a committed pick would replace it with the committed Range).
    func testMovingASliderWhileAPickSamplesDiscardsThePickAndKeepsThePreview() async throws {
        let session = try await EditorTestSupport.readySession(library: library, previewLongEdge: 480)
        session.pickSelectiveColour(frameX: 0.5, frameY: 0.5)
        await session.settleRendering()
        XCTAssertEqual(keptColours(session).count, 1)
        let gate = SamplingGate()
        session.pickSamplingGate = { await gate.wait() }
        session.pickSelectiveColour(frameX: 0.2, frameY: 0.8)           // held in sampling
        session.previewEffects { $0.selectiveColour.range = 90 }        // Range moves, finger still down
        await session.settleRenderingExceptPicks()
        let dragged = try MetalLUTRenderer.rgba8Bytes(of: session.displayedImage)
        await gate.open()                                               // sampling completes
        await session.settleRendering()
        XCTAssertEqual(keptColours(session).count, 1, "the stale pick is discarded")
        XCTAssertEqual(session.recipe.tools.effects.selectiveColour.range, 40, "nothing was committed")
        XCTAssertEqual(try MetalLUTRenderer.rgba8Bytes(of: session.displayedImage), dragged, "the slider preview remains on screen")
    }

    /// Rapid picks still land in order when nothing else changes (the slider rule must not break them).
    func testRapidPicksStillLandWhenNoSliderMoves() async throws {
        let session = try await EditorTestSupport.readySession(library: library, previewLongEdge: 480)
        for (x, y) in [(0.1, 0.1), (0.9, 0.9), (0.5, 0.5)] { session.pickSelectiveColour(frameX: x, frameY: y) }
        await session.settleRendering()
        XCTAssertEqual(keptColours(session).map(\.x), [0.1, 0.9, 0.5])
    }

    /// Leaving the photo while a pick is still sampling: nothing lands on the closed session.
    func testClosingDuringSamplingDiscardsThePendingPick() async throws {
        let session = try await EditorTestSupport.readySession(library: library, previewLongEdge: 480)
        let before = session.recipe
        session.pickSelectiveColour(frameX: 0.5, frameY: 0.5)
        session.close()
        await session.settleRendering()
        XCTAssertEqual(session.recipe, before)
    }

    /// Rapid picks: they land in tap order, and picks still sampling count towards the eight-colour limit.
    func testRapidPicksLandInOrderUpToTheLimit() async throws {
        let session = try await EditorTestSupport.readySession(library: library, previewLongEdge: 480)
        for i in 0..<6 {   // six kept already
            session.commitEffects { $0.selectiveColour.colours.append(.init(oklab: SIMD3(0.5, 0.1, Double(i) / 50), x: 0, y: 0)) }
        }
        let taps: [(Double, Double)] = [(0.1, 0.1), (0.9, 0.9), (0.5, 0.5)]
        for (x, y) in taps { session.pickSelectiveColour(frameX: x, frameY: y) }
        await session.settleRendering()
        let kept = keptColours(session)
        XCTAssertEqual(kept.count, EditorSession.maximumKeptColours, "the third rapid pick is refused at the limit")
        XCTAssertEqual(kept[6].x, 0.1, accuracy: 1e-9); XCTAssertEqual(kept[7].x, 0.9, accuracy: 1e-9)   // tap order
        session.undo()
        XCTAssertEqual(keptColours(session).count, 7, "each pick is its own undo step")
    }

    /// Mean of max − min over the channels (0 for black and white), on an 8-bit sRGB copy.
    private static func meanChroma(_ image: CGImage) -> Double {
        let width = 64, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = 0.0
        for p in 0..<(width * height) {
            let r = Double(pixels[p * 4]), g = Double(pixels[p * 4 + 1]), b = Double(pixels[p * 4 + 2])
            total += (max(r, g, b) - min(r, g, b)) / 255
        }
        return total / Double(width * height)
    }

    func testRemoveCommitsOneStepWithItsPatchAndUndoStrokeRemovesIt() async throws {
        let session = try await EditorTestSupport.readySession(library: library, inpainter: FlatInpainter())
        session.removeStroke(points: [.init(x: 0.5, y: 0.5), .init(x: 0.55, y: 0.5)], radius: 0.03)
        XCTAssertEqual(session.removeState, .removing)
        await session.debugAwaitQuiescence()
        XCTAssertEqual(session.removeState, .idle)
        let strokes = session.recipe.tools.edit.remove.strokes
        XCTAssertEqual(strokes.count, 1)
        XCTAssertEqual(strokes.first?.status, .applied)
        let ref = try XCTUnwrap(strokes.first?.patch)
        XCTAssertNotNil(session.removePatches.patch(ref.sha256), "The patch is kept by digest and replayed")
        XCTAssertEqual(ref.model.id, "test-flat")
        XCTAssertTrue(session.canUndo)
        session.undoStroke()
        XCTAssertTrue(session.recipe.tools.edit.remove.strokes.isEmpty)
    }

    func testWithoutAModelRemoveFailsAndChangesNothing() async throws {
        let session = try await EditorTestSupport.readySession(library: library, inpainter: nil)
        let before = session.recipe
        session.removeStroke(points: [.init(x: 0.5, y: 0.5)], radius: 0.03)
        await session.debugAwaitQuiescence()
        XCTAssertEqual(session.removeState, .failed, "The approved failure state, never a substitute fill")
        XCTAssertEqual(session.recipe, before)
        XCTAssertNotNil(session.pendingRemoveStroke, "The stroke stays drawn for Try again")
    }

    func testCancelRemoveChangesNothing() async throws {
        let session = try await EditorTestSupport.readySession(library: library, inpainter: SlowInpainter())
        session.removeStroke(points: [.init(x: 0.5, y: 0.5)], radius: 0.03)
        session.cancelRemove()
        XCTAssertEqual(session.removeState, .idle)
        await session.debugAwaitQuiescence()
        XCTAssertTrue(session.recipe.tools.edit.remove.strokes.isEmpty)
        XCTAssertFalse(session.canUndo)
    }
}

/// A model that must never run: a restored edit replays stored patches, never the model.
final class TrapInpainter: Inpainting, @unchecked Sendable {
    let model = EditRecipe.ModelRef(id: "test-trap", version: "1")
    private(set) var calls = 0
    func inpaint(image: [Float], mask: [Float], side: Int) async throws -> [Float] {
        calls += 1
        XCTFail("The Remove model ran for a restored edit")
        throw RemoveEngine.Failure.modelFailed("trap")
    }
}

/// edit-recipe `derivedRef`: Remove patches are stored beside the edit by digest and survive the
/// app being killed; a missing or corrupt patch is skipped and never recomputed.
@MainActor
final class RemovePatchPersistenceTests: XCTestCase {

    private var library: DevelopLibrary!
    private var directory: URL!

    override func setUp() async throws {
        library = try EditorTestSupport.library()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("patches-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    /// Session A removes a stroke and its recipe is saved; the app is "killed" (both the session
    /// and the in-memory store go). A fresh store over the same folder and a fresh session
    /// restored from the saved recipe render the same fill without running a model.
    private func editWithOneStroke(photo: SelectedPhoto) async throws -> (recipe: Data, export: Data, digest: String) {
        let session = try await EditorTestSupport.readySession(photo: photo, library: library, inpainter: FlatInpainter(),
                                                               removePatches: RemovePatchStore(directory: directory))
        session.removeStroke(points: [.init(x: 0.5, y: 0.5), .init(x: 0.55, y: 0.5)], radius: 0.03)
        await session.debugAwaitQuiescence()
        let digest = try XCTUnwrap(session.recipe.tools.edit.remove.strokes.first?.patch?.sha256)
        let saved = EditRecipeCodec.encode(session.recipe)
        let export = try await session.exportedData()
        session.close()
        return (saved, export, digest)
    }

    private func restoredSession(photo: SelectedPhoto, recipe: Data, trap: TrapInpainter) async throws -> EditorSession {
        let restored = try EditRecipeCodec.decode(recipe)
        let session = try await EditorTestSupport.readySession(photo: photo, library: library, inpainter: trap,
                                                               removePatches: RemovePatchStore(directory: directory))
        session.debugSetInitial { $0.tools = restored.tools }
        await session.settleRendering()
        return session
    }

    func testKillAndRecoverReplaysTheStoredPatchWithoutTheModel() async throws {
        let photo = try await EditorTestSupport.photo()
        let edit = try await editWithOneStroke(photo: photo)
        let file = directory.appendingPathComponent("\(edit.digest).patch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true, "not backed up")
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let trap = TrapInpainter()
        let session = try await restoredSession(photo: photo, recipe: edit.recipe, trap: trap)
        XCTAssertNotNil(session.removePatches.patch(edit.digest), "read back from disk, digest checked")
        let export = try await session.exportedData()
        XCTAssertEqual(export, edit.export, "the restored edit renders the same fill")
        XCTAssertEqual(trap.calls, 0)
    }

    func testACorruptOrMissingPatchIsSkippedNotRecomputed() async throws {
        let photo = try await EditorTestSupport.photo()
        let edit = try await editWithOneStroke(photo: photo)
        let file = directory.appendingPathComponent("\(edit.digest).patch")
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: file)
        let trap = TrapInpainter()
        let corrupt = try await restoredSession(photo: photo, recipe: edit.recipe, trap: trap)
        XCTAssertNil(corrupt.removePatches.patch(edit.digest), "a patch whose bytes do not hash to its name is refused")
        let skipped = try await corrupt.exportedData()
        let plain = try await EditorTestSupport.readySession(photo: photo, library: library).exportedData()
        XCTAssertEqual(skipped, plain, "the stroke renders without its fill")
        XCTAssertEqual(trap.calls, 0, "never recomputed silently")
        try FileManager.default.removeItem(at: file)
        let missing = try await restoredSession(photo: photo, recipe: edit.recipe, trap: trap)
        let missingExport = try await missing.exportedData()
        XCTAssertEqual(missingExport, plain)
        XCTAssertEqual(trap.calls, 0)
    }

    func testChoosingANewPhotoDeletesTheStoredPatches() async throws {
        let photo = try await EditorTestSupport.photo()
        let edit = try await editWithOneStroke(photo: photo)
        let store = RemovePatchStore(directory: directory)
        XCTAssertNotNil(store.patch(edit.digest))
        store.removeAll()
        XCTAssertNil(RemovePatchStore(directory: directory).patch(edit.digest))
        let state = AppState(photoLoader: ImageIOPhotoLoader(), removePatches: RemovePatchStore(directory: directory))
        _ = try await editWithOneStroke(photo: photo)
        await state.openPhoto(source: .photoLibrary) { try TestFixtures.makeTIFFData(for: TestFixtures.makeImage(width: 64, height: 48)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "a new photo deletes the previous edit's patches")
    }
}

struct SlowInpainter: Inpainting {
    let model = EditRecipe.ModelRef(id: "test-slow", version: "1")
    func inpaint(image: [Float], mask: [Float], side: Int) async throws -> [Float] {
        try await Task.sleep(for: .seconds(2))
        return image
    }
}

/// The bundled LaMa model on the field photo with the prototype's stroke: it loads, fills the
/// stroke, and its Simulator timing is recorded (device timing is a separate, pending check).
final class RemoveModelTimingTests: XCTestCase {

    func testBundledLamaRemovesThePrototypeStrokeAndRecordsItsTiming() async throws {
        let loadStart = ContinuousClock.now
        guard let lama = LamaInpainter.loadBundled() else {
            throw XCTSkip("LaMa is not bundled in this build (release gate closed or package missing)")
        }
        let loadTime = ContinuousClock.now - loadStart
        let url = DevelopParityTests.fixture("docs/ui/assets/photos/landscape_03.jpg")
        let photo = try await ImageIOPhotoLoader().loadPhoto(from: Data(contentsOf: url), source: .photoLibrary)
        let pixels = try MetalLUTRenderer.rgba8Bytes(of: photo.image)
        let stroke = DebugScenario.prototypeStroke(width: photo.image.width, height: photo.image.height)
        var times: [Duration] = []
        var patch: RemovePatch?
        for _ in 0..<3 {
            let start = ContinuousClock.now
            patch = try await RemoveEngine.patch(for: .init(radius: stroke.radius, points: stroke.points, status: .applied, patch: nil),
                                                 source: pixels, width: photo.image.width, height: photo.image.height, inpainter: lama)
            times.append(ContinuousClock.now - start)
        }
        let result = try XCTUnwrap(patch)
        XCTAssertGreaterThan(result.width, 0)
        let ms = times.map { Int($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000) }
        let line = "LAMA_TIMING simulator load_ms=\(Int(loadTime.components.seconds * 1000 + loadTime.components.attoseconds / 1_000_000_000_000_000)) stroke_ms=\(ms) photo=\(photo.image.width)x\(photo.image.height)"
        print(line)
        XCTContext.runActivity(named: line) { _ in }
    }
}


/// Holds a pick in sampling until the test opens it.
actor SamplingGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
