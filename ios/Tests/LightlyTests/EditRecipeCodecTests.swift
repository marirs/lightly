import Foundation
import XCTest
@testable import Lightly

/// EditState schema 3 (edit recipe v1) against the shared fixtures in `shared/fixtures/edit-recipe/`
/// and the schema-2 fixtures in `shared/fixtures/edit-state/`: every valid file decodes and
/// re-encodes to identical bytes, every invalid file is rejected as a whole, and schema 1 and 2
/// migrate exactly as the README specifies.
final class EditRecipeCodecTests: XCTestCase {

    private static func url(_ path: String) -> URL { DevelopParityTests.fixture(path) }

    private static func recipeFixtures() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url("shared/fixtures/edit-recipe"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testPaperRoundTripsAndOldBorderDefaultsRemainReadable() throws {
        let file = try XCTUnwrap(Self.recipeFixtures().first { $0.lastPathComponent == "border-solid.json" })
        var recipe = try EditRecipeCodec.decode(Data(contentsOf: file))
        XCTAssertEqual(recipe.tools.border.paperFinish, .deckled)
        recipe.tools.border.type = .paper; recipe.tools.border.paperFinish = .torn; recipe.tools.border.texture = 73
        XCTAssertEqual(try EditRecipeCodec.decode(EditRecipeCodec.encode(recipe)), recipe)
    }

    /// The fixtures predate the owner amendment of 2026-10-11, whose two keys are optional on read and always written
    /// (`tools.text`, `faceEdit.smile`). The writer's bytes are the fixture's with exactly those keys added where the
    /// schema orders them: `smile` before each face's `hair`, `text` after `border`, the last key of `tools` (and
    /// `tools` is the document's last key). Everything else must still match byte for byte.
    static func withAlwaysWrittenKeys(_ fixture: String) -> String {
        var json = fixture.replacingOccurrences(of: "\"hair\":{\"definition\"", with: "\"smile\":{\"amount\":0},\"hair\":{\"definition\"")
        precondition(json.hasSuffix("}}"), "tools is the last key")
        json.removeLast(2)
        return json + ",\"text\":{\"layers\":[]}}}"
    }

    func testEveryValidFixtureRoundTripsByteForByte() throws {
        let valid = try Self.recipeFixtures().filter { !$0.lastPathComponent.hasPrefix("invalid-") }
        XCTAssertEqual(valid.count, 25)   // 25th: effects-selective-colour (rendering-v2 revision 4)
        for file in valid {
            let bytes = try Data(contentsOf: file)
            let recipe = try EditRecipeCodec.decode(bytes)
            XCTAssertEqual(String(decoding: EditRecipeCodec.encode(recipe), as: UTF8.self),
                           Self.withAlwaysWrittenKeys(String(decoding: bytes, as: UTF8.self)), file.lastPathComponent)
            // The written form (with the new keys) reads back to the same recipe.
            XCTAssertEqual(try EditRecipeCodec.decode(EditRecipeCodec.encode(recipe)), recipe, file.lastPathComponent)
        }
    }

    /// Shared fixtures and Android write a bundled background as `background.<name>`; in memory it is the bare bundled
    /// name the panel and the scene cache use, and writing restores the fixture form.
    func testBundledBackgroundReadsTheFixtureFormAsTheBundledName() throws {
        let bytes = try Data(contentsOf: Self.url("shared/fixtures/edit-recipe/background-replace-image.json"))
        let recipe = try EditRecipeCodec.decode(bytes)
        guard case .image(let image, _, _, _)? = recipe.tools.background.replacement else { return XCTFail("image replacement") }
        XCTAssertEqual(image, .bundled(id: "landscape_01"))
        let written = String(decoding: EditRecipeCodec.encode(recipe), as: UTF8.self)
        XCTAssertTrue(written.contains("\"image\":{\"kind\":\"bundled\",\"id\":\"background.landscape_01\"}"), written)
    }

    /// Recipes saved by earlier iOS builds hold the bare name; they still read, and are rewritten in the fixture form.
    func testBundledBackgroundStillReadsTheBareNameFromEarlierIOSBuilds() throws {
        let fixture = String(decoding: try Data(contentsOf: Self.url("shared/fixtures/edit-recipe/background-replace-image.json")),
                             as: UTF8.self)
        let legacy = fixture.replacingOccurrences(of: "\"id\":\"background.landscape_01\"", with: "\"id\":\"landscape_01\"")
        XCTAssertNotEqual(legacy, fixture)
        let recipe = try EditRecipeCodec.decode(Data(legacy.utf8))
        XCTAssertEqual(recipe, try EditRecipeCodec.decode(Data(fixture.utf8)))
        XCTAssertEqual(String(decoding: EditRecipeCodec.encode(recipe), as: UTF8.self), Self.withAlwaysWrittenKeys(fixture))
    }

    /// The prefix is added once, never doubled, and only to bundled images; other asset kinds pass through unchanged.
    func testTheBackgroundPrefixIsAddedOnceAndOnlyToBundledImages() {
        XCTAssertEqual(EditRecipeCodec.backgroundImageForRecipe(.bundled(id: "sunset_03")), .bundled(id: "background.sunset_03"))
        XCTAssertEqual(EditRecipeCodec.backgroundImageForRecipe(.bundled(id: "background.sunset_03")), .bundled(id: "background.sunset_03"))
        XCTAssertEqual(EditRecipeCodec.backgroundImageFromRecipe(.bundled(id: "background.")), .bundled(id: "background."))
        let file = EditRecipe.AssetRef.file(sha256: String(repeating: "a", count: 64))
        XCTAssertEqual(EditRecipeCodec.backgroundImageForRecipe(file), file)
        XCTAssertEqual(EditRecipeCodec.backgroundImageFromRecipe(file), file)
    }

    func testEveryInvalidFixtureIsRejected() throws {
        let invalid = try Self.recipeFixtures().filter { $0.lastPathComponent.hasPrefix("invalid-") }
        XCTAssertEqual(invalid.count, 8)  // revision 1 added invalid-blur-without-depth.json
        for file in invalid {
            XCTAssertThrowsError(try EditRecipeCodec.decode(Data(contentsOf: file)), file.lastPathComponent)
        }
    }

    func testSchema2MigratesToTheExpectedSchema3Bytes() throws {
        let migrated = try EditRecipeCodec.decode(Data(contentsOf: Self.url("shared/fixtures/edit-state/v2-with-look.json")))
        let expected = try Data(contentsOf: Self.url("shared/fixtures/edit-recipe/migrated-from-v2-with-look.json"))
        XCTAssertEqual(String(decoding: EditRecipeCodec.encode(migrated), as: UTF8.self),
                       Self.withAlwaysWrittenKeys(String(decoding: expected, as: UTF8.self)))
    }

    func testSchema1MigratesThroughSchema2WithALegacyLookVersion() throws {
        let recipe = try EditRecipeCodec.decode(Data(contentsOf: Self.url("shared/fixtures/edit-state/v1-numeric-look-version.json")))
        XCTAssertEqual(recipe.look?.lookVersion, "legacy-v1-2")
        XCTAssertEqual(recipe.look?.lookId, "film.portra")
        XCTAssertEqual(recipe.revision, 7)
        XCTAssertEqual(recipe.tools.effects.grain.seed, 0xABAB_ABAB)
    }

    func testSchema2RejectionsStillApply() throws {
        for name in ["invalid-unknown-key", "invalid-strength-out-of-range"] {
            XCTAssertThrowsError(try EditRecipeCodec.decode(Data(contentsOf: Self.url("shared/fixtures/edit-state/\(name).json"))), name)
        }
    }

    func testNeutralRecipeMatchesTheNeutralFixture() throws {
        let fixture = try EditRecipeCodec.decode(Data(contentsOf: Self.url("shared/fixtures/edit-recipe/neutral.json")))
        let built = EditRecipe.neutral(source: fixture.source, grainSeed: EditRecipe.grainSeed(fromHeadSha256: fixture.source.fingerprint.headSha256))
        XCTAssertEqual(built, fixture)
    }

    func testDevelopLookAmountFixtureCarriesAmountAsStrength() throws {
        let recipe = try EditRecipeCodec.decode(Data(contentsOf: Self.url("shared/fixtures/edit-recipe/develop-look-amount-auto.json")))
        XCTAssertEqual(recipe.look?.strength, 0.6)
        XCTAssertEqual(recipe.auto.strength, 0.75)
    }
}
