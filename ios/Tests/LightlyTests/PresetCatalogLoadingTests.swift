import XCTest
@testable import Lightly

/// Loading the catalogue from an injected bundle, and failing loudly.
final class PresetCatalogLoadingTests: XCTestCase {

    /// The unit-test bundle, which carries the fixture JSON as resources.
    private var testBundle: Bundle { Bundle(for: Self.self) }

    func testLoadsPresetsFromAnInjectedBundle() throws {
        let catalog = try BuiltInPresetCatalog.load(
            from: testBundle, resourceName: "presets_fixture"
        )

        let warm = try XCTUnwrap(catalog.resolvePreset(id: "film.fixture-warm").preset)
        XCTAssertEqual(warm.name, "Fixture Warm")
        XCTAssertEqual(warm.recipe.exposure, 0.25, accuracy: 0.0001)
        XCTAssertEqual(warm.recipe.whiteBalance.temperature, 400, accuracy: 0.0001)
        XCTAssertEqual(catalog.presets(in: .bw).map(\.id), ["bw.fixture-mono"])
        XCTAssertNil(catalog.loadFailure)
    }

    func testMissingResourceThrowsResourceMissing() {
        XCTAssertThrowsError(
            try BuiltInPresetCatalog.load(from: testBundle, resourceName: "does_not_exist")
        ) { error in
            XCTAssertEqual(
                error as? PresetCatalogLoadError,
                .resourceMissing(resourceName: "does_not_exist")
            )
        }
    }

    /// The test bundle deliberately has no `presets_photo.json`: loading the
    /// default resource from the wrong bundle must not find the app's copy
    /// through some other path (v1 fell back to an absolute developer path).
    func testDefaultResourceIsOnlyLookedUpInTheGivenBundle() {
        XCTAssertThrowsError(try BuiltInPresetCatalog.load(from: testBundle)) { error in
            XCTAssertEqual(
                error as? PresetCatalogLoadError,
                .resourceMissing(resourceName: BuiltInPresetCatalog.bundledResourceName)
            )
        }
    }

    func testMalformedResourceThrowsDecodingFailed() {
        XCTAssertThrowsError(
            try BuiltInPresetCatalog.load(from: testBundle, resourceName: "presets_malformed")
        ) { error in
            guard case .decodingFailed(let name, _)? = error as? PresetCatalogLoadError else {
                return XCTFail("Expected decodingFailed, got \(error)")
            }
            XCTAssertEqual(name, "presets_malformed")
        }
    }

    /// Release register: the legacy catalogues name third-party packs and nothing in the app reads
    /// them, so the app does not ship them (the format-3 Look pack is the catalogue).
    func testTheAppBundleDoesNotShipTheLegacyCatalogues() throws {
        XCTAssertNil(Bundle.main.url(forResource: "presets_photo", withExtension: "json"))
        XCTAssertNil(Bundle.main.url(forResource: "luts_video", withExtension: "json"))
        let catalog = try BuiltInPresetCatalog.load(from: TestFixtures.legacyPresetsBundle)
        XCTAssertGreaterThan(catalog.presets(in: .film).count, 0, "still readable by its own tests")
    }
}
