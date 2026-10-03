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

    func testEveryValidFixtureRoundTripsByteForByte() throws {
        let valid = try Self.recipeFixtures().filter { !$0.lastPathComponent.hasPrefix("invalid-") }
        XCTAssertEqual(valid.count, 24)
        for file in valid {
            let bytes = try Data(contentsOf: file)
            let recipe = try EditRecipeCodec.decode(bytes)
            XCTAssertEqual(String(decoding: EditRecipeCodec.encode(recipe), as: UTF8.self), String(decoding: bytes, as: UTF8.self),
                           file.lastPathComponent)
        }
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
        XCTAssertEqual(EditRecipeCodec.encode(migrated), expected)
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
