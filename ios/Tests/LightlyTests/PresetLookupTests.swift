import XCTest
@testable import Lightly

/// Exact-ID resolution of persisted Look identifiers.
///
/// Guards against the v1 behaviour where a missing ID was silently replaced by
/// a prefix-similar Look or by "any golden-hour Look".
final class PresetLookupTests: XCTestCase {

    private static func makePreset(
        id: String,
        category: PresetCategory = .film,
        exposure: Double = 0
    ) -> LightlyPreset {
        var recipe = DevelopRecipe.unmodified
        recipe.exposure = exposure
        return LightlyPreset(
            id: id,
            name: id,
            category: category,
            isIncludedInFreeTier: true,
            recipe: recipe
        )
    }

    private let goldenHourLook = makePreset(id: "golden_hour.warm-dusk", category: .goldenHour, exposure: 0.3)
    private let filmGold = makePreset(id: "film.kodak-gold-200", exposure: 0.2)
    private let filmGoldVariant = makePreset(id: "film.kodak-gold-200-faded", exposure: -0.1)

    private func makeCatalog(
        migrations: PresetIDMigrations = .shipped
    ) -> BuiltInPresetCatalog {
        BuiltInPresetCatalog(
            presets: [goldenHourLook, filmGold, filmGoldVariant],
            migrations: migrations
        )
    }

    func testExactIDResolvesToThatPreset() {
        XCTAssertEqual(
            makeCatalog().resolvePreset(id: "film.kodak-gold-200-faded"),
            .found(filmGoldVariant)
        )
    }

    /// v1 matched `stored.hasPrefix(id) || id.hasPrefix(stored)`.
    func testPrefixOfAnExistingIDDoesNotMatch() {
        XCTAssertEqual(
            makeCatalog().resolvePreset(id: "film.kodak-gold"),
            .unavailable(requestedID: "film.kodak-gold")
        )
    }

    func testIDExtendingAnExistingIDDoesNotMatch() {
        XCTAssertEqual(
            makeCatalog().resolvePreset(id: "film.kodak-gold-200-v2"),
            .unavailable(requestedID: "film.kodak-gold-200-v2")
        )
    }

    /// v1 returned the first golden-hour or film Look for any ID containing
    /// "gold"; the pre-ingestion starter ID `film.golden-memory` hit this path.
    func testGoldenSubstringDoesNotFallBackToAGoldenHourLook() {
        XCTAssertEqual(
            makeCatalog().resolvePreset(id: "film.golden-memory"),
            .unavailable(requestedID: "film.golden-memory")
        )
    }

    func testMigratedIDResolvesToItsReplacement() {
        let catalog = makeCatalog(
            migrations: PresetIDMigrations(renames: ["film.old-gold": "film.kodak-gold-200"])
        )
        XCTAssertEqual(catalog.resolvePreset(id: "film.old-gold"), .found(filmGold))
    }

    func testChainedMigrationsResolveToTheLatestID() {
        let catalog = makeCatalog(
            migrations: PresetIDMigrations(renames: [
                "a": "b",
                "b": "film.kodak-gold-200"
            ])
        )
        XCTAssertEqual(catalog.resolvePreset(id: "a"), .found(filmGold))
    }

    func testMigrationCycleTerminatesAsUnavailable() {
        let catalog = makeCatalog(
            migrations: PresetIDMigrations(renames: ["a": "b", "b": "a"])
        )
        XCTAssertEqual(catalog.resolvePreset(id: "a"), .unavailable(requestedID: "a"))
    }

    func testUnknownIDIsUnavailable() {
        XCTAssertEqual(
            makeCatalog().resolvePreset(id: "landscape.does-not-exist"),
            .unavailable(requestedID: "landscape.does-not-exist")
        )
    }

    func testShippedMigrationsContainNoInventedRenames() {
        XCTAssertTrue(PresetIDMigrations.shipped.renames.isEmpty)
    }
}
