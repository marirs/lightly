import XCTest
@testable import Lightly

final class PresetCatalogTests: XCTestCase {

    private var catalog: BuiltInPresetCatalog!

    override func setUp() {
        super.setUp()
        catalog = BuiltInPresetCatalog()
    }

    func testCatalogLoadsAllIngestedPresets() {
        let allCategories: [PresetCategory] = [
            .aerial, .landscape, .film, .cinematic,
            .goldenHour, .bw, .urban, .portrait, .minimal, .wedding
        ]

        var total = 0
        for category in allCategories {
            let presets = catalog.presets(in: category)
            XCTAssertFalse(presets.isEmpty, "Category \(category.rawValue) should have presets")
            total += presets.count
        }

        XCTAssertGreaterThan(total, 3000, "Should have loaded over 3,000 deduplicated presets")
    }

    func testRecommendedReturnsCuratedPresets() {
        let recommended = catalog.recommended(for: .unclassified)
        XCTAssertEqual(recommended.count, BuiltInPresetCatalog.recommendedCount)
        XCTAssertTrue(recommended.contains { $0.isIncludedInFreeTier }, "Recommended should contain free tier looks")
        XCTAssertTrue(recommended.contains { !$0.isIncludedInFreeTier }, "Recommended should contain pro tier looks to preview")
    }

    func testPresetLookupByID() {
        let recommended = catalog.recommended(for: .unclassified)
        guard let first = recommended.first else {
            XCTFail("Missing recommended presets")
            return
        }

        XCTAssertEqual(catalog.resolvePreset(id: first.id), .found(first))
    }

    func testRecommendedIsStable() {
        XCTAssertEqual(
            catalog.recommended(for: .unclassified).map(\.id),
            catalog.recommended(for: .unclassified).map(\.id)
        )
    }

    func testEveryPresetIdentifierIsUnique() {
        let all = PresetCategory.allCases
            .filter { $0 != .recommended && $0 != .favourites }
            .flatMap { catalog.presets(in: $0) }

        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    }
}
