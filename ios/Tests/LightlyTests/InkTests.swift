import CryptoKit
import Foundation
import XCTest
@testable import Lightly

/// Effects › Ink (owner-approved 2026-10-31, docs/ui/proposals/ink-2026-10-31; rendering-v2 revision 10 §Ink,
/// edit-recipe-v1 `effects.ink`): the recipe codec, the renderer, the bundled ink pack and the session's choices.
@MainActor
final class InkTests: XCTestCase {

    private typealias Ink = EditRecipe.Effects.Ink
    /// Dry Sweep, the shared fixture's ink.
    private static let dryInkID = "ink-cbfae4259a79"

    // MARK: - Codec

    /// The writer always writes `text` (revision 7), which this older-schema fixture leaves out, so the ink object is
    /// compared as written rather than the whole file.
    func testTheSharedFixtureReadsAndWritesTheInk() throws {
        let data = try Data(contentsOf: DevelopParityTests.fixture("shared/fixtures/edit-recipe/effects-ink.json"))
        let recipe = try EditRecipeCodec.decode(data)
        XCTAssertEqual(recipe.tools.effects.ink, Ink(id: Self.dryInkID, x: 46, y: 52, size: 120, rotation: -15, paper: "#1F2328", intensity: 60))
        let ink = ##""ink":{"id":"ink-cbfae4259a79","x":46,"y":52,"size":120,"rotation":-15,"paper":"#1F2328","intensity":60}"##
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(ink))
        let written = EditRecipeCodec.encode(recipe)
        XCTAssertTrue(String(decoding: written, as: UTF8.self).contains(ink))
        XCTAssertEqual(try EditRecipeCodec.decode(written), recipe)
    }

    func testNoInkWritesNoKeySoEarlierReadersSeeNoChange() throws {
        let data = try Data(contentsOf: DevelopParityTests.fixture("shared/fixtures/edit-recipe/border-solid.json"))
        let recipe = try EditRecipeCodec.decode(data)
        XCTAssertNil(recipe.tools.effects.ink)
        XCTAssertFalse(String(decoding: EditRecipeCodec.encode(recipe), as: UTF8.self).contains("\"ink\""))
    }

    func testMalformedInksAreRefused() throws {
        let good = String(decoding: try Data(contentsOf: DevelopParityTests.fixture("shared/fixtures/edit-recipe/effects-ink.json")), as: UTF8.self)
        for (from, to) in [("\"ink-cbfae4259a79\"", "\"leak-cbfae4259a79\""), ("\"size\":120", "\"size\":151"),
                           ("\"paper\":\"#1F2328\"", "\"paper\":\"#1f2328\""), ("\"intensity\":60", "\"intensity\":101")] {
            XCTAssertThrowsError(try EditRecipeCodec.decode(Data(good.replacingOccurrences(of: from, with: to).utf8)), to)
        }
    }

    // MARK: - Renderer

    private static func mask(_ width: Int, _ height: Int, value: UInt8) -> InkImage {
        InkImage(width: width, height: height, grey: [UInt8](repeating: value, count: width * height))
    }

    private static func stroke(size: Double = 100, x: Double = 50, y: Double = 50, rotation: Double = 0, paper: String = "#FF0000") -> Ink {
        Ink(id: dryInkID, x: x, y: y, size: size, rotation: rotation, paper: paper, intensity: 60)
    }

    func testAStrokeShowsThePhotoInsideAndPaperOutside() throws {
        // A full mask 200 × 100 on a 100 × 100 frame: fitted at 0.88 × 100 wide, so 44 px tall, centred.
        let evaluator = try XCTUnwrap(InkEvaluator(Self.stroke(), kind: .stroke, image: Self.mask(200, 100, value: 255), frameWidth: 100, frameHeight: 100))
        let photo = SIMD3<Float>(0.2, 0.4, 0.6)
        XCTAssertEqual(evaluator.apply(photo, x: 50, y: 50), photo, "centre: the photo")
        XCTAssertEqual(evaluator.apply(photo, x: 50, y: 10), SIMD3(1, 0, 0), "above the stroke: paper")
        XCTAssertEqual(evaluator.apply(photo, x: 2, y: 50), SIMD3(1, 0, 0), "the 6 % margin: paper")
        XCTAssertEqual(evaluator.apply(photo, x: 10, y: 50), photo, "inside the fitted stroke")
    }

    func testSizeScalesTheStrokeAndRotationTurnsIt() throws {
        let mask = Self.mask(200, 100, value: 255)
        let photo = SIMD3<Float>(0.5, 0.5, 0.5), paper = SIMD3<Float>(1, 0, 0)
        let small = try XCTUnwrap(InkEvaluator(Self.stroke(size: 50), kind: .stroke, image: mask, frameWidth: 100, frameHeight: 100))
        XCTAssertEqual(small.apply(photo, x: 10, y: 50), paper, "half size: x = 10 is outside")
        let turned = try XCTUnwrap(InkEvaluator(Self.stroke(rotation: 90), kind: .stroke, image: mask, frameWidth: 100, frameHeight: 100))
        XCTAssertEqual(turned.apply(photo, x: 50, y: 10), photo, "turned upright: above the centre is inside")
        XCTAssertEqual(turned.apply(photo, x: 10, y: 50), paper, "…and the side is paper")
    }

    func testAPortraitFrameTurnsTheStrokeWithThePhoto() throws {
        // rendering-v2 §Ink φ: H > W turns the landscape mask upright, so the stroke runs down the photo.
        let evaluator = try XCTUnwrap(InkEvaluator(Self.stroke(), kind: .stroke, image: Self.mask(200, 100, value: 255), frameWidth: 100, frameHeight: 200))
        let photo = SIMD3<Float>(0.5, 0.5, 0.5)
        XCTAssertEqual(evaluator.apply(photo, x: 50, y: 20), photo)
        XCTAssertEqual(evaluator.apply(photo, x: 5, y: 100), SIMD3(1, 0, 0))
    }

    func testMovingTheStrokeMovesWhereThePhotoShows() throws {
        let evaluator = try XCTUnwrap(InkEvaluator(Self.stroke(size: 50, x: 25, y: 25), kind: .stroke, image: Self.mask(200, 100, value: 255),
                                                   frameWidth: 100, frameHeight: 100))
        let photo = SIMD3<Float>(0.5, 0.5, 0.5)
        XCTAssertEqual(evaluator.apply(photo, x: 25, y: 25), photo)
        XCTAssertEqual(evaluator.apply(photo, x: 75, y: 75), SIMD3(1, 0, 0))
    }

    func testAnOverlayMultipliesByIntensity() throws {
        var ink = Self.stroke(); ink.intensity = 50
        let evaluator = try XCTUnwrap(InkEvaluator(ink, kind: .overlay, image: Self.mask(10, 10, value: 0), frameWidth: 40, frameHeight: 40))
        // g = 0, k = 0.5: out = in · 0.5.
        let out = evaluator.apply(SIMD3(0.8, 0.4, 0.2), x: 20, y: 20)
        XCTAssertEqual(out.x, 0.4, accuracy: 1e-6); XCTAssertEqual(out.y, 0.2, accuracy: 1e-6); XCTAssertEqual(out.z, 0.1, accuracy: 1e-6)
        ink.intensity = 0
        XCTAssertNil(InkEvaluator(ink, kind: .overlay, image: Self.mask(10, 10, value: 0), frameWidth: 40, frameHeight: 40), "no intensity, no ink")
    }

    func testInkRunsBeforeTheLeakAndAnInkThisBuildLacksDrawsNothing() throws {
        var effects = EditRecipe.Tools.neutral(grainSeed: 1).effects
        effects.ink = Self.stroke(paper: "#000000")
        let pixels = [UInt8](repeating: 200, count: 8 * 8 * 4)
        let model = try EditorTestSupport.model()
        let missing = EffectsStage(effects: effects, presetFinishing: .init(), presetStrength: 0, frameWidth: 8, frameHeight: 8, model: model,
                                   inkImages: { _ in nil })
        XCTAssertNil(missing.ink)
        XCTAssertEqual(missing.apply(pixels, width: 8, height: 8), pixels)
        let blank = EffectsStage(effects: effects, presetFinishing: .init(), presetStrength: 0, frameWidth: 8, frameHeight: 8, model: model,
                                 inkImages: { _ in (.stroke, Self.mask(4, 2, value: 0)) })
        XCTAssertEqual(blank.apply(pixels, width: 8, height: 8), [UInt8](repeating: 0, count: 8 * 8 * 4).enumerated().map { $0.offset % 4 == 3 ? 200 : 0 },
                       "an empty mask is all paper")
    }

    // MARK: - Pack

    func testAManifestOfAnotherFormatOrWithAMalformedInkLoadsNothing() {
        let other = Data(#"{"format":"lightly-leak-pack","formatVersion":1,"inks":[]}"#.utf8)
        XCTAssertThrowsError(try InkPackLoader.read(other))
        let badKind = Data(#"{"format":"lightly-ink-pack","formatVersion":1,"inks":[{"id":"ink-000000000001","name":"A","kind":"brush","image":"img/a.png","thumbnail":"thumb/a.png","imageSha256":"0000000000000000000000000000000000000000000000000000000000000000","width":1,"height":1}]}"#.utf8)
        XCTAssertThrowsError(try InkPackLoader.read(badKind))
        let escaping = Data(#"{"format":"lightly-ink-pack","formatVersion":1,"inks":[{"id":"ink-000000000001","name":"A","kind":"stroke","image":"../a.png","thumbnail":"thumb/a.png","imageSha256":"0000000000000000000000000000000000000000000000000000000000000000","width":1,"height":1}]}"#.utf8)
        XCTAssertThrowsError(try InkPackLoader.read(escaping))
    }

    /// The bundled pack (scripts/bundle_ink_pack.sh): the approved 18 inks in the proposal's order, every image's SHA-256
    /// and size as the manifest says, and the shared cache decoding them for the renderer.
    func testTheBundledPackIsCompleteAndMatchesItsManifest() throws {
        let (pack, problem) = InkPackLoader.loadBundled()
        if problem == .missing { throw XCTSkip("This build carries no ink pack (shared/ink/out was not built).") }
        XCTAssertNil(problem)
        XCTAssertEqual(pack.inks.map(\.name), ["Dry Sweep", "Dry Vertical", "Bold Strokes", "Stacked", "Double Stroke", "Torn Stroke",
                                               "Dry Block", "Three Arcs", "Grey Wash", "Thin Arc", "Ink Edge", "Bloom", "Soft Bloom",
                                               "Deep Bloom", "Cloud Bloom", "Ink Wash", "Splatter", "Speckle"])
        XCTAssertEqual(pack.inks.filter { $0.kind == .overlay }.map(\.name), ["Splatter", "Speckle"])
        XCTAssertEqual(pack.inks.first?.id, Self.dryInkID)
        for ink in pack.inks {
            let imageURL = try XCTUnwrap(pack.imageURL(ink)), thumbnailURL = try XCTUnwrap(pack.thumbnailURL(ink))
            let data = try Data(contentsOf: imageURL)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), ink.imageSha256, ink.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path), ink.id)
            let image = try XCTUnwrap(InkPackLoader.decode(imageURL))
            XCTAssertEqual([image.width, image.height], [ink.width, ink.height], ink.id)
            if ink.kind == .stroke { XCTAssertGreaterThanOrEqual(ink.width, ink.height, "masks are stored landscape: \(ink.name)") }
        }
        XCTAssertNotNil(InkImageCache.bundled.image(for: Self.dryInkID))
        XCTAssertNil(InkImageCache.bundled.image(for: "ink-000000000000"))
    }

    // MARK: - Session

    func testChoosingAnInkIsOneUndoStepAndKeepsItsSettingsWhenSwitching() async throws {
        let session = try await EditorTestSupport.readySession(library: try EditorTestSupport.library())
        defer { session.close() }
        let before = session.recipe
        XCTAssertNil(before.tools.effects.ink)
        session.chooseInk(Self.dryInkID)
        XCTAssertEqual(session.recipe.tools.effects.ink, Ink.starting(Self.dryInkID))
        XCTAssertEqual(session.recipe.tools.effects.ink?.paper, "#F4F1EC", "Warm white")
        session.undo()
        XCTAssertEqual(session.recipe.tools, before.tools, "one undo step")
        session.redo()

        session.commitEffects { $0.ink?.size = 130; $0.ink?.paper = "#1F2328" }
        session.chooseInk("ink-000000000002")
        XCTAssertEqual(session.recipe.tools.effects.ink?.id, "ink-000000000002")
        XCTAssertEqual(session.recipe.tools.effects.ink?.size, 130, "switching keeps Size")
        XCTAssertEqual(session.recipe.tools.effects.ink?.paper, "#1F2328", "…and the paper")
        session.chooseInk(nil)
        XCTAssertNil(session.recipe.tools.effects.ink, "None: no ink")
        session.resetEdits(section: "effects", adjustment: "ink")
        XCTAssertNil(session.recipe.tools.effects.ink)
    }

    /// Device check 2026-10-31: Size then Paper colour are two undo steps; Undo after the paper restores the paper only.
    func testSizeThenPaperAreTwoUndoSteps() async throws {
        let session = try await EditorTestSupport.readySession(library: try EditorTestSupport.library())
        defer { session.close() }
        guard InkPack.bundled.ink(id: Self.dryInkID) != nil else { throw XCTSkip("no bundled ink pack") }
        session.chooseInk(Self.dryInkID)
        session.pinchInk(from: try XCTUnwrap(session.recipe.tools.effects.ink), scale: 1.43, turnDegrees: 116, final: false)
        session.pinchInk(from: try XCTUnwrap(session.recipe.tools.effects.ink), scale: 1.43, turnDegrees: 116, final: true)
        session.changeInk(final: false) { $0.size = 70 }
        session.changeInk(final: true) { $0.size = 70 }
        session.changeInk(final: false) { $0.paper = "#1F2328" }
        session.changeInk(final: true) { $0.paper = "#1F2328" }
        XCTAssertEqual(session.recipe.tools.effects.ink.map { [$0.size, $0.rotation] }, [70, 116])
        session.undo()
        XCTAssertEqual(session.recipe.tools.effects.ink?.paper, "#F4F1EC", "undo: the paper only")
        XCTAssertEqual(session.recipe.tools.effects.ink?.size, 70, "…Size stays")
        session.undo()
        XCTAssertEqual(session.recipe.tools.effects.ink?.size, 143)
    }

    func testMovingAndPinchingChangeOnlyAChosenStrokeInk() async throws {
        let session = try await EditorTestSupport.readySession(library: try EditorTestSupport.library())
        defer { session.close() }
        let couldUndo = session.canUndo
        session.moveInk(x: 30, y: 30, final: true)
        XCTAssertNil(session.recipe.tools.effects.ink, "None: dragging does nothing")
        XCTAssertEqual(session.canUndo, couldUndo)
        guard InkPack.bundled.ink(id: Self.dryInkID) != nil else { throw XCTSkip("no bundled ink pack") }
        session.chooseInk(Self.dryInkID)
        session.moveInk(x: 30, y: 120, final: true)
        XCTAssertEqual(session.recipe.tools.effects.ink.map { [$0.x, $0.y] }, [30, 100], "clamped to the frame")
        let start = try XCTUnwrap(session.recipe.tools.effects.ink)
        session.pinchInk(from: start, scale: 2, turnDegrees: 200, final: true)
        XCTAssertEqual(session.recipe.tools.effects.ink?.size, 150, "Size stops at 150")
        XCTAssertEqual(session.recipe.tools.effects.ink?.rotation, -160, "Rotation wraps into −180…180")
    }
}
