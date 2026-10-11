import CryptoKit
import Foundation
import SwiftUI
import XCTest
@testable import Lightly

/// Light leak images (owner, 2026-10-11; rendering-v2 revision 8, edit-recipe-v1 `lightLeak.style`): the recipe codec,
/// the renderer, the bundled leak pack and the Light Leaks gallery.
@MainActor
final class LightLeakImageTests: XCTestCase {

    private typealias Style = EditRecipe.Effects.LightLeak.Style
    private static let firstLeakID = "leak-edf0a0ecd85d"

    // MARK: - Codec

    private static func fixtureRecipe() throws -> EditRecipe {
        try EditRecipeCodec.decode(Data(contentsOf: DevelopParityTests.fixture("shared/fixtures/edit-recipe/border-solid.json")))
    }

    func testALeakImageStyleRoundTrips() throws {
        var recipe = try Self.fixtureRecipe()
        recipe.tools.effects.lightLeak = .init(enabled: true, style: try XCTUnwrap(Style.leakImage(Self.firstLeakID)),
                                               intensity: 50, x: 30, y: 60, rotation: -45)
        let written = String(decoding: EditRecipeCodec.encode(recipe), as: UTF8.self)
        XCTAssertTrue(written.contains("\"style\":\"\(Self.firstLeakID)\""), written)
        let read = try EditRecipeCodec.decode(Data(written.utf8))
        XCTAssertEqual(read, recipe)
        XCTAssertEqual(read.tools.effects.lightLeak.style.leakImageID, Self.firstLeakID)
        XCTAssertNil(read.tools.effects.lightLeak.style.drawn)
    }

    func testTheFourDrawnStylesStillRoundTrip() throws {
        var recipe = try Self.fixtureRecipe()
        for drawn in Style.Drawn.allCases {
            recipe.tools.effects.lightLeak.style = Style(drawn: drawn)
            let read = try EditRecipeCodec.decode(EditRecipeCodec.encode(recipe))
            XCTAssertEqual(read.tools.effects.lightLeak.style.drawn, drawn)
            XCTAssertNil(read.tools.effects.lightLeak.style.leakImageID)
        }
    }

    func testMalformedLeakStylesAreRefused() throws {
        var recipe = try Self.fixtureRecipe()
        recipe.tools.effects.lightLeak.style = .warm
        let written = String(decoding: EditRecipeCodec.encode(recipe), as: UTF8.self)
        XCTAssertTrue(written.contains("\"style\":\"warm\""))
        for bad in ["leak-EDF0A0ECD85D", "leak-edf0a0ecd85", "leak-edf0a0ecd85d0", "leak-edf0a0ecd8zz", "sunburst", ""] {
            let edited = written.replacingOccurrences(of: "\"style\":\"warm\"", with: "\"style\":\"\(bad)\"")
            XCTAssertThrowsError(try EditRecipeCodec.decode(Data(edited.utf8)), bad)
            XCTAssertNil(Style(rawValue: bad), bad)
        }
    }

    // MARK: - Rendering (rendering-v2 §Light leak, leak images)

    /// An image whose left half is `left` and right half `right`.
    private static func halves(width: Int, height: Int, left: [UInt8], right: [UInt8]) -> LeakImage {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4, c = x < width / 2 ? left : right
                rgba[o] = c[0]; rgba[o + 1] = c[1]; rgba[o + 2] = c[2]
            }
        }
        return LeakImage(width: width, height: height, rgba: rgba)
    }

    private static func uniform(_ c: [UInt8], width: Int = 8, height: Int = 4) -> LeakImage {
        halves(width: width, height: height, left: c, right: c)
    }

    private static func leak(intensity: Double, x: Double = 50, y: Double = 50, rotation: Double = 0) -> EditRecipe.Effects.LightLeak {
        .init(enabled: true, style: Style.leakImage(firstLeakID)!, intensity: intensity, x: x, y: y, rotation: rotation)
    }

    private static func neutralEffects(with leak: EditRecipe.Effects.LightLeak) -> EditRecipe.Effects {
        var effects = EditRecipe.Tools.neutral(grainSeed: 0).effects
        effects.lightLeak = leak
        return effects
    }

    private static func ramp(_ width: Int, _ height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let o = (y * width + x) * 4
            pixels[o] = UInt8(x * 255 / max(1, width - 1)); pixels[o + 1] = UInt8(y * 255 / max(1, height - 1)); pixels[o + 2] = 77
        } }
        return pixels
    }

    func testIntensityZeroLeavesThePhotoUnchanged() throws {
        let image = Self.uniform([255, 200, 120])
        XCTAssertNil(LeakImageEvaluator(Self.leak(intensity: 0), image: image, frameWidth: 40, frameHeight: 30))
        let stage = EffectsStage(effects: Self.neutralEffects(with: Self.leak(intensity: 0)), presetFinishing: .init(), presetStrength: 0,
                                 frameWidth: 40, frameHeight: 30, model: try EditorTestSupport.model(), leakImages: { _ in image })
        XCTAssertTrue(stage.isEmpty)
        let pixels = Self.ramp(40, 30)
        XCTAssertEqual(stage.apply(pixels, width: 40, height: 30), pixels)
    }

    func testABlackLeakImageLeavesThePhotoUnchanged() throws {
        let black = Self.uniform([0, 0, 0])
        let stage = EffectsStage(effects: Self.neutralEffects(with: Self.leak(intensity: 100, rotation: 30)), presetFinishing: .init(),
                                 presetStrength: 0, frameWidth: 40, frameHeight: 30, model: try EditorTestSupport.model(),
                                 leakImages: { _ in black })
        XCTAssertNotNil(stage.leakImage)
        XCTAssertNil(stage.leak, "a leak image is not drawn as one of the four styles")
        let pixels = Self.ramp(40, 30)
        XCTAssertEqual(stage.apply(pixels, width: 40, height: 30), pixels)
    }

    func testScreenFormulaOnAKnownPixel() throws {
        let image = Self.uniform([200, 100, 50])
        let evaluator = try XCTUnwrap(LeakImageEvaluator(Self.leak(intensity: 50), image: image, frameWidth: 20, frameHeight: 10))
        let input = SIMD3<Float>(0.4, 0.2, 0.6)
        let light = SIMD3<Double>(200, 100, 50) / 255 * 0.5
        let expected = SIMD3<Double>(repeating: 1) - (SIMD3<Double>(repeating: 1) - SIMD3<Double>(input)) * (SIMD3<Double>(repeating: 1) - light)
        let output = evaluator.apply(input, x: 7, y: 3)
        for c in 0..<3 { XCTAssertEqual(Double(output[c]), expected[c], accuracy: 1e-6) }
        // And through the stage on 8-bit sRGB: the encoded values are screened directly.
        let stage = EffectsStage(effects: Self.neutralEffects(with: Self.leak(intensity: 50)), presetFinishing: .init(), presetStrength: 0,
                                 frameWidth: 1, frameHeight: 1, model: try EditorTestSupport.model(), leakImages: { _ in image })
        let pixel = stage.apply([102, 51, 153, 255], width: 1, height: 1)
        let base = SIMD3<Double>(102, 51, 153) / 255
        let screened = SIMD3<Double>(repeating: 1) - (SIMD3<Double>(repeating: 1) - base) * (SIMD3<Double>(repeating: 1) - light)
        XCTAssertEqual(Array(pixel.prefix(3)), (0..<3).map { UInt8((screened[$0] * 255 + 0.5).rounded(.down)) })
    }

    /// A 200 × 100 image on a 100 × 50 frame: s = 0.5, so x = y = 50 covers the frame exactly.
    func testPositionAndRotationMapping() throws {
        let image = Self.halves(width: 200, height: 100, left: [255, 0, 0], right: [0, 0, 255])
        func evaluator(x: Double = 50, y: Double = 50, rotation: Double = 0) throws -> LeakImageEvaluator {
            try XCTUnwrap(LeakImageEvaluator(Self.leak(intensity: 100, x: x, y: y, rotation: rotation), image: image, frameWidth: 100, frameHeight: 50))
        }
        let centred = try evaluator()
        XCTAssertEqual(centred.scale, 0.5)
        XCTAssertEqual(centred.imagePoint(x: 0, y: 0), SIMD2(1, 1), "frame pixel centre (0.5, 0.5) → image (1, 1)")
        XCTAssertEqual(try XCTUnwrap(centred.light(x: 10, y: 25)).x, 1, accuracy: 1e-9, "left of the frame: the image's left (red)")
        XCTAssertEqual(try XCTUnwrap(centred.light(x: 90, y: 25)).z, 1, accuracy: 1e-9, "right: blue")

        let halfTurn = try evaluator(rotation: 180)
        XCTAssertEqual(try XCTUnwrap(halfTurn.light(x: 10, y: 25)).z, 1, accuracy: 1e-9, "turned 180°: the right half is on the left")

        // Clockwise positive: turned 90°, the image's right half points down the frame.
        let quarterTurn = try evaluator(rotation: 90)
        XCTAssertEqual(try XCTUnwrap(quarterTurn.light(x: 50, y: 45)).z, 1, accuracy: 1e-9, "below the centre: the right half (blue)")
        XCTAssertEqual(try XCTUnwrap(quarterTurn.light(x: 50, y: 5)).x, 1, accuracy: 1e-9, "above the centre: the left half (red)")
        let anticlockwise = try evaluator(rotation: -90)
        XCTAssertEqual(try XCTUnwrap(anticlockwise.light(x: 50, y: 45)).x, 1, accuracy: 1e-9)

        // Moved to the frame's left edge (x = 0): the image's centre is there, its right half covers the frame's left
        // half, and past the image's right edge there is no light.
        let moved = try evaluator(x: 0)
        XCTAssertEqual(moved.imagePoint(x: 0, y: 25), SIMD2(101, 51))
        XCTAssertEqual(try XCTUnwrap(moved.light(x: 10, y: 25)).z, 1, accuracy: 1e-9)
        XCTAssertNil(moved.light(x: 60, y: 25), "outside the image: no light")
        XCTAssertEqual(moved.apply(SIMD3(0.3, 0.3, 0.3), x: 60, y: 25), SIMD3(0.3, 0.3, 0.3))
    }

    /// rendering-v2 revision 8 (080003a): the image's light fades over the last 8 % of each side.
    func testTheLeakImageFadesAtItsEdges() throws {
        // 1000 × 1000 image on a 1000 × 1000 frame, centred: frame pixel x maps to image x + 0.5.
        let image = Self.uniform([255, 255, 255], width: 1000, height: 1000)
        let evaluator = try XCTUnwrap(LeakImageEvaluator(Self.leak(intensity: 100), image: image, frameWidth: 1000, frameHeight: 1000))
        let middle = try XCTUnwrap(evaluator.light(x: 500, y: 500))
        XCTAssertEqual(middle, SIMD3(repeating: 1), "at 50 %: full light")
        let outer = evaluator.light(x: 5, y: 500)?.x ?? 0   // u.x/iw = 0.0055: the outer 1 %
        XCTAssertLessThan(outer, 0.02, "the outer 1 % gets almost no light")
        XCTAssertEqual(evaluator.light(x: 500, y: 994)?.x ?? 0, outer, accuracy: 1e-9, "every side fades alike")
        XCTAssertEqual(try XCTUnwrap(evaluator.light(x: 100, y: 500)).x, 1, accuracy: 1e-12, "past 8 %: full")
        XCTAssertEqual(LeakImageEvaluator.edgeFactor(SIMD2(40, 500), width: 1000, height: 1000), 0.5, accuracy: 1e-12,
                       "halfway into the fade: smoothstep 0.5")
        // A moved leak's edge is soft: light rises continuously from the image edge instead of jumping.
        let moved = try XCTUnwrap(LeakImageEvaluator(Self.leak(intensity: 100, x: 0), image: image, frameWidth: 1000, frameHeight: 1000))
        var previous = 0.0
        for x in stride(from: 499, through: 400, by: -1) {
            let light = moved.light(x: x, y: 500)?.x ?? 0
            XCTAssertLessThan(abs(light - previous), 0.03, "no seam at x = \(x)")
            previous = light
        }
    }

    func testIntensityScalesTheLight() throws {
        let image = Self.uniform([255, 255, 255])
        let half = try XCTUnwrap(LeakImageEvaluator(Self.leak(intensity: 50), image: image, frameWidth: 10, frameHeight: 10))
        XCTAssertEqual(try XCTUnwrap(half.light(x: 5, y: 5)), SIMD3(repeating: 0.5))
        XCTAssertEqual(half.apply(SIMD3(repeating: 0.5), x: 5, y: 5), SIMD3(repeating: 0.75))
    }

    func testALeakThisBuildLacksAddsNoLight() throws {
        let stage = EffectsStage(effects: Self.neutralEffects(with: Self.leak(intensity: 80)), presetFinishing: .init(), presetStrength: 0,
                                 frameWidth: 20, frameHeight: 10, model: try EditorTestSupport.model(), leakImages: { _ in nil })
        XCTAssertTrue(stage.isEmpty)
    }

    func testDrawnStylesStillUseTheDrawnLeak() throws {
        var leak = Self.leak(intensity: 55)
        leak.style = .rose
        let stage = EffectsStage(effects: Self.neutralEffects(with: leak), presetFinishing: .init(), presetStrength: 0,
                                 frameWidth: 20, frameHeight: 10, model: try EditorTestSupport.model(),
                                 leakImages: { _ in XCTFail("a drawn style never asks for an image"); return nil })
        XCTAssertNotNil(stage.leak)
        XCTAssertNil(stage.leakImage)
    }

    // MARK: - Pack

    func testAManifestOfAnotherFormatOrWithAMalformedLeakLoadsNothing() {
        func manifest(_ format: String = "lightly-leak-pack", _ version: Int = 1, id: String = "leak-edf0a0ecd85d") -> Data {
            Data("""
            {"format": "\(format)", "formatVersion": \(version), "leaks": [{"id": "\(id)", "name": "Gold Fringe",
             "image": "img/\(id).jpg", "thumbnail": "thumb/\(id).jpg",
             "imageSha256": "\(String(repeating: "a", count: 64))", "width": 1280, "height": 720}]}
            """.utf8)
        }
        XCTAssertEqual(try LeakPackLoader.read(manifest()).map(\.name), ["Gold Fringe"])
        XCTAssertThrowsError(try LeakPackLoader.read(manifest("lightly-look-pack")))
        XCTAssertThrowsError(try LeakPackLoader.read(manifest("lightly-leak-pack", 2)))
        XCTAssertThrowsError(try LeakPackLoader.read(manifest(id: "leak-XYZ")))
        XCTAssertEqual(LeakPackLoader.load(from: URL(fileURLWithPath: "/nonexistent")).problem, .missing)
    }

    /// The bundled pack (scripts/bundle_leak_pack.sh): the manifest parsed, every image and thumbnail present, each
    /// image's SHA-256 and size as the manifest says, and the shared cache decoding them for the renderer.
    func testTheBundledPackIsCompleteAndMatchesItsManifest() throws {
        let (pack, problem) = LeakPackLoader.loadBundled()
        if problem == .missing { throw XCTSkip("This build carries no light-leak pack (shared/leaks/out was not built).") }
        XCTAssertNil(problem)
        XCTAssertFalse(pack.leaks.isEmpty)
        XCTAssertEqual(Set(pack.leaks.map(\.id)).count, pack.leaks.count, "unique ids")
        XCTAssertEqual(pack, LeakPack.bundled)
        for leak in pack.leaks {
            let imageURL = try XCTUnwrap(pack.imageURL(leak)), thumbnailURL = try XCTUnwrap(pack.thumbnailURL(leak))
            let data = try Data(contentsOf: imageURL)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), leak.imageSha256, leak.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path), leak.id)
            let image = try XCTUnwrap(LeakPackLoader.decode(imageURL))
            XCTAssertEqual([image.width, image.height], [leak.width, leak.height], leak.id)
        }
        let first = try XCTUnwrap(pack.leaks.first)
        let decoded = try XCTUnwrap(LeakImageCache.bundled.image(for: first.id))
        XCTAssertEqual([decoded.width, decoded.height], [first.width, first.height])
        XCTAssertNil(LeakImageCache.bundled.image(for: "leak-000000000000"))
        // The default resolver renders the bundled leak.
        var leak = Self.leak(intensity: 100)
        leak.style = try XCTUnwrap(Style.leakImage(first.id))
        let stage = EffectsStage(effects: Self.neutralEffects(with: leak), presetFinishing: .init(), presetStrength: 0,
                                 frameWidth: 64, frameHeight: 48, model: try EditorTestSupport.model())
        let grey = [UInt8](repeating: 60, count: 64 * 48 * 4)
        XCTAssertNotEqual(stage.apply(grey, width: 64, height: 48), grey)
    }

    // MARK: - Gallery

    func testTheGalleryStartsWithNoneThenThePackInOrder() {
        let leaks = ["leak-000000000001", "leak-000000000002"].map {
            LeakPack.Leak(id: $0, name: $0, imagePath: "", thumbnailPath: "", imageSha256: "", width: 1, height: 1)
        }
        XCTAssertEqual(LeakGallery.tileIDs(LeakPack(leaks: leaks, directory: nil)), [nil, "leak-000000000001", "leak-000000000002"])
        XCTAssertEqual(LeakGallery.tileIDs(.empty), [nil], "no pack: only None")
        var leak = Self.leak(intensity: 50)
        XCTAssertEqual(LeakGallery.selectedLeakID(leak), Self.firstLeakID)
        leak.enabled = false
        XCTAssertNil(LeakGallery.selectedLeakID(leak), "off: None is chosen")
        XCTAssertEqual([LeakGallery.columnWidth, LeakGallery.rowHeight, LeakGallery.rowGap, LeakGallery.columnGap], [96, 84, 10, 12])
    }

    func testChoosingALeakIsOneUndoStepAndNoneTurnsItOff() async throws {
        let session = try await EditorTestSupport.readySession(library: try EditorTestSupport.library())
        defer { session.close() }
        let before = session.recipe
        XCTAssertFalse(before.tools.effects.lightLeak.enabled)

        session.chooseLightLeak(Self.firstLeakID)
        var leak = session.recipe.tools.effects.lightLeak
        XCTAssertTrue(leak.enabled)
        XCTAssertEqual(leak.style.leakImageID, Self.firstLeakID)
        XCTAssertEqual(leak.intensity, 50, "choosing a leak while off starts at 50")
        XCTAssertEqual([leak.x, leak.y], [50, 50], "turning it on centres the image (mockup `center/cover`)")
        XCTAssertEqual(leak.rotation, before.tools.effects.lightLeak.rotation)
        session.undo()
        XCTAssertEqual(session.recipe.tools, before.tools, "one undo step")
        session.redo()

        session.commitEffects { $0.lightLeak.intensity = 80; $0.lightLeak.x = 30; $0.lightLeak.y = 70 }
        session.chooseLightLeak("leak-fc36430bd1c4")
        leak = session.recipe.tools.effects.lightLeak
        XCTAssertEqual(leak.style.leakImageID, "leak-fc36430bd1c4")
        XCTAssertEqual(leak.intensity, 80, "switching leaks keeps the Intensity")
        XCTAssertEqual([leak.x, leak.y], [30, 70], "…and where the person moved it")

        session.chooseLightLeak(nil)
        XCTAssertFalse(session.recipe.tools.effects.lightLeak.enabled, "None turns it off")
        session.undo()
        XCTAssertEqual(session.recipe.tools.effects.lightLeak.style.leakImageID, "leak-fc36430bd1c4")
        XCTAssertTrue(session.recipe.tools.effects.lightLeak.enabled)
    }

    /// rendering-v2 revision 8 (080003a): dragging on the photo moves only a chosen leak; with None chosen it does
    /// nothing, no effect turned on and no undo step.
    func testDraggingOnThePhotoMovesOnlyAChosenLeak() async throws {
        let session = try await EditorTestSupport.readySession(library: try EditorTestSupport.library())
        defer { session.close() }
        let before = session.recipe
        let couldUndo = session.canUndo
        session.moveLightLeak(x: 70, y: 30, final: false)
        session.moveLightLeak(x: 70, y: 30, final: true)
        XCTAssertEqual(session.recipe, before, "None chosen: nothing changes")
        XCTAssertEqual(session.canUndo, couldUndo, "…and no undo step")
        XCTAssertFalse(session.recipe.tools.effects.lightLeak.enabled)

        session.chooseLightLeak(Self.firstLeakID)
        session.moveLightLeak(x: 70, y: 30, final: false)
        session.moveLightLeak(x: 72, y: 31, final: true)
        let leak = session.recipe.tools.effects.lightLeak
        XCTAssertEqual([leak.x, leak.y], [72, 31])
        XCTAssertEqual(leak.style.leakImageID, Self.firstLeakID)
        session.undo()
        XCTAssertEqual([session.recipe.tools.effects.lightLeak.x, session.recipe.tools.effects.lightLeak.y], [50, 50], "one undo step")
        XCTAssertTrue(session.recipe.tools.effects.lightLeak.enabled)
    }

    // MARK: - Change background › Image

    func testBackgroundTilesFillTheRowFourAcross() {
        typealias Grid = BackgroundImageGrid<EmptyView>
        for width in [343.0, 361.0, 400.0] {
            XCTAssertEqual(Grid.tileSide(gridWidth: width), (width - 24) / 4)
            XCTAssertEqual(4 * Grid.tileSide(gridWidth: width) + 3 * Grid.columnGap, width, accuracy: 1e-9)
        }
        XCTAssertEqual(Grid.rowGap, 10)
        XCTAssertEqual(Grid.columnGap, 8)
        XCTAssertEqual(Grid.horizontalPadding, 2)
    }
}
