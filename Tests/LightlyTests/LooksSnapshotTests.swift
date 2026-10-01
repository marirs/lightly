import SwiftUI
import XCTest
@testable import Lightly

/// Thumbnail renderer producing deterministic output for snapshots.
private struct DeterministicThumbnailRenderer: LookThumbnailRendering {
    var failsForPresetID: String?

    func thumbnail(
        for preset: LightlyPreset,
        from image: CGImage,
        maximumDimension: Int
    ) async throws -> CGImage {
        if preset.id == failsForPresetID { throw LightlyError.developFailed }
        // Falls back to the source rather than propagating, so a rendering
        // hiccup cannot fail a layout snapshot for the wrong reason.
        return (try? RecipeRenderer().render(image, with: preset.recipe)) ?? image
    }
}

private struct SnapshotProEntitlements: EntitlementResolving {
    let level: EntitlementLevel = .pro
    let generativeCredits: Int = 0
    func canApply(_ capability: PaidCapability) -> Bool { true }
}

@MainActor
final class LooksSnapshotTests: XCTestCase {

    private func makeViewModel(
        renderer: any LookThumbnailRendering = DeterministicThumbnailRenderer(),
        entitlements: any EntitlementResolving = FreeTierEntitlementResolver()
    ) -> LooksViewModel {
        LooksViewModel(
            sourceImage: TestFixtures.makeImage(),
            catalog: TestFixtures.bundledCatalog,
            thumbnailRenderer: renderer,
            entitlements: entitlements
        )
    }

    private func looks(_ viewModel: LooksViewModel) -> some View {
        LooksView(
            viewModel: viewModel,
            onPreviewChanged: { _, _ in },
            onApply: { _, _ in },
            onClose: {}
        )
    }

    /// Loads a category and waits for thumbnails, so snapshots capture the
    /// settled grid rather than a rack of loading placeholders.
    private func loaded(
        _ viewModel: LooksViewModel,
        category: PresetCategory = .recommended
    ) async -> LooksViewModel {
        viewModel.load(category: category)
        await viewModel.inFlightThumbnailWork?.value
        return viewModel
    }

    private let sheetSize = CGSize(width: 402, height: 560)

    // MARK: - Grid, both appearances

    func testRecommendedGridLight() async {
        let viewModel = await loaded(makeViewModel())
        let view = looks(viewModel)
        SnapshotAssertion.assert(of: view, named: "looks-recommended-light", size: sheetSize)
    }

    func testRecommendedGridDark() async {
        let viewModel = await loaded(makeViewModel())
        let view = looks(viewModel)
        SnapshotAssertion.assert(of: view, named: "looks-recommended-dark", size: sheetSize, colorScheme: .dark)
    }

    /// The "not yet tailored" disclaimer must be present while scene
    /// classification is missing.
    func testRecommendedShowsNotTailoredDisclaimer() async {
        let viewModel = await loaded(makeViewModel())

        XCTAssertFalse(viewModel.recommendationsAreSceneAware)

        let view = looks(viewModel)
        SnapshotAssertion.assert(of: view, named: "looks-disclaimer", size: sheetSize)
    }

    // MARK: - Dynamic Type

    func testRecommendedGridAccessibilityTextSize() async {
        let viewModel = await loaded(makeViewModel())
        let view = looks(viewModel).environment(\.dynamicTypeSize, .accessibility3)
        SnapshotAssertion.assert(
            of: view,
            named: "looks-recommended-accessibility3",
            size: sheetSize
        )
    }

    // MARK: - Preview and intensity

    func testPreviewSelectionShowsIntensityAndApply() async {
        let viewModel = await loaded(makeViewModel())
        guard let first = viewModel.presets.first else { return XCTFail("No presets") }
        viewModel.preview(first)

        let view = looks(viewModel)
        SnapshotAssertion.assert(of: view, named: "looks-previewing", size: sheetSize)
    }

    func testPartialIntensity() async {
        let viewModel = await loaded(makeViewModel())
        guard let first = viewModel.presets.first else { return XCTFail("No presets") }
        viewModel.preview(first)
        viewModel.setIntensity(0.35)

        let view = looks(viewModel)
        SnapshotAssertion.assert(of: view, named: "looks-intensity-partial", size: sheetSize)
    }

    // MARK: - Entitlement

    /// Free tier previewing a Pro Look: the grid must look identical to the Pro
    /// view — no lock badges, no dimming, no hint of the boundary (spec §0.3).
    func testFreeTierShowsNoLockAffordances() async {
        let freeViewModel = await loaded(makeViewModel(entitlements: FreeTierEntitlementResolver()))
        let view = looks(freeViewModel)
        SnapshotAssertion.assert(of: view, named: "looks-free-tier", size: sheetSize)
    }

    func testProTierGridIsIdenticalToFreeTier() async {
        let proViewModel = await loaded(makeViewModel(entitlements: SnapshotProEntitlements()))
        let view = looks(proViewModel)
        // Compared against the free-tier reference on purpose: if these ever
        // diverge, a lock affordance has crept into the grid.
        SnapshotAssertion.assert(of: view, named: "looks-free-tier", size: sheetSize)
    }

    // MARK: - Thumbnail failure

    /// One failing thumbnail degrades its own cell only.
    func testSingleThumbnailFailure() async {
        let viewModel = await loaded(
            makeViewModel(
                renderer: DeterministicThumbnailRenderer(
                    failsForPresetID: "film.golden-memory"
                )
            )
        )
        let view = looks(viewModel)
        SnapshotAssertion.assert(of: view, named: "looks-thumbnail-failed", size: sheetSize)
    }

    // MARK: - Other categories

    func testFilmCategory() async {
        let viewModel = await loaded(makeViewModel(), category: .film)
        let view = looks(viewModel)
        SnapshotAssertion.assert(of: view, named: "looks-category-film", size: sheetSize)
    }
}
