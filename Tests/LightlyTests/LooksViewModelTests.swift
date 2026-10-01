import CoreGraphics
import XCTest
@testable import Lightly

/// A thumbnail renderer whose outcome the test dictates.
private actor ScriptedThumbnailRenderer: LookThumbnailRendering {
    enum Behaviour: Sendable {
        case succeed
        /// Fails only for the named preset; every other preset succeeds.
        case failOnly(presetID: String)
        case failAll
        /// Never returns, so cancellation can be observed.
        case hang
    }

    private let behaviour: Behaviour
    private(set) var renderCount = 0

    init(behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    func thumbnail(
        for preset: LightlyPreset,
        from image: CGImage,
        maximumDimension: Int
    ) async throws -> CGImage {
        renderCount += 1

        switch behaviour {
        case .succeed:
            return TestFixtures.makeImage(width: 40, height: 40)
        case .failOnly(let presetID):
            if preset.id == presetID { throw LightlyError.developFailed }
            return TestFixtures.makeImage(width: 40, height: 40)
        case .failAll:
            throw LightlyError.developFailed
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            return TestFixtures.makeImage(width: 40, height: 40)
        }
    }

    func currentRenderCount() -> Int { renderCount }
}

/// Grants every paid capability, standing in for a Pro subscriber.
private struct ProEntitlementResolver: EntitlementResolving {
    let level: EntitlementLevel = .pro
    let generativeCredits: Int = 0
    func canApply(_ capability: PaidCapability) -> Bool { true }
}

@MainActor
final class LooksViewModelTests: XCTestCase {

    private func makeViewModel(
        renderer: any LookThumbnailRendering = ScriptedThumbnailRenderer(behaviour: .succeed),
        entitlements: any EntitlementResolving = FreeTierEntitlementResolver()
    ) -> LooksViewModel {
        LooksViewModel(
            sourceImage: TestFixtures.makeImage(),
            catalog: TestFixtures.bundledCatalog,
            thumbnailRenderer: renderer,
            entitlements: entitlements
        )
    }

    // MARK: - Recommended set

    /// Spec §7 and §0.11: 3–6 Looks in the first viewport, not a flat dump.
    func testRecommendedSetIsBetweenThreeAndSix() {
        let viewModel = makeViewModel()

        viewModel.load(category: .recommended)

        XCTAssertGreaterThanOrEqual(viewModel.presets.count, 3)
        XCTAssertLessThanOrEqual(viewModel.presets.count, 6)
    }

    /// Recommendations must not claim to be personalised until scene
    /// classification exists (Phase 4).
    func testRecommendationsAreNotClaimedToBeSceneAware() {
        let viewModel = makeViewModel()

        XCTAssertFalse(
            viewModel.recommendationsAreSceneAware,
            """
            Scene awareness appears to be implemented. If so, remove the \
            "not yet tailored" disclaimer string and update \
            docs/phase-2-deferred.md.
            """
        )
    }

    func testRecommendedSetIncludesFreeTierLooks() {
        let viewModel = makeViewModel()
        viewModel.load(category: .recommended)

        XCTAssertTrue(
            viewModel.presets.contains { $0.isIncludedInFreeTier },
            "The free tier must feel complete, not crippled (spec §26.2)."
        )
    }

    // MARK: - Thumbnails

    func testThumbnailsRenderForEveryLook() async {
        let viewModel = makeViewModel()
        viewModel.load(category: .recommended)
        await viewModel.inFlightThumbnailWork?.value

        for preset in viewModel.presets {
            XCTAssertNotNil(
                viewModel.thumbnails[preset.id]?.image,
                "Missing thumbnail for \(preset.id)"
            )
        }
    }

    /// A single failing thumbnail must not blank the grid.
    func testOneFailingThumbnailDoesNotAffectTheOthers() async {
        let sampleCatalog = TestFixtures.bundledCatalog
        let targetID = sampleCatalog.recommended(for: .unclassified).first?.id ?? "cinematic.green-hawaii-f149aa"

        let viewModel = makeViewModel(
            renderer: ScriptedThumbnailRenderer(
                behaviour: .failOnly(presetID: targetID)
            )
        )
        viewModel.load(category: .recommended)
        await viewModel.inFlightThumbnailWork?.value

        XCTAssertEqual(viewModel.thumbnails[targetID], .failed)

        let others = viewModel.presets.filter { $0.id != targetID }
        for preset in others {
            XCTAssertNotNil(
                viewModel.thumbnails[preset.id]?.image,
                "\(preset.id) should still have rendered."
            )
        }
    }

    func testFavouritesCategoryWorkflow() {
        let favouritesManager = UserDefaultsFavouritesManager(userDefaults: UserDefaults(suiteName: "test.looks.vm.favs")!)
        let viewModel = LooksViewModel(
            sourceImage: TestFixtures.makeImage(),
            catalog: TestFixtures.bundledCatalog,
            thumbnailRenderer: ScriptedThumbnailRenderer(behaviour: .succeed),
            entitlements: FreeTierEntitlementResolver(),
            favouritesManager: favouritesManager
        )

        viewModel.load(category: .recommended)
        guard let firstLook = viewModel.presets.first else {
            return XCTFail("Expected presets in recommended")
        }

        XCTAssertFalse(viewModel.isFavourite(firstLook))
        viewModel.toggleFavourite(firstLook)
        XCTAssertTrue(viewModel.isFavourite(firstLook))

        viewModel.load(category: .favourites)
        XCTAssertTrue(viewModel.presets.contains { $0.id == firstLook.id })

        viewModel.toggleFavourite(firstLook)
        XCTAssertFalse(viewModel.isFavourite(firstLook))
    }

    /// A favourite whose Look no longer exists is hidden and reported, never
    /// replaced by a similarly named Look (v1 substituted via prefix/"gold").
    func testUnavailableFavouriteIsReportedNotSubstituted() {
        let suiteName = "test.looks.vm.unavailable-favs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let favouritesManager = UserDefaultsFavouritesManager(userDefaults: defaults)

        let kept = LightlyPreset(
            id: "film.kodak-gold-200", name: "Gold", category: .film,
            isIncludedInFreeTier: true, recipe: .unmodified
        )
        let catalog = BuiltInPresetCatalog(presets: [kept])
        favouritesManager.toggleFavourite(presetID: kept.id)
        favouritesManager.toggleFavourite(presetID: "film.kodak-gold")
        favouritesManager.toggleFavourite(presetID: "film.golden-memory")

        let viewModel = LooksViewModel(
            sourceImage: TestFixtures.makeImage(),
            catalog: catalog,
            thumbnailRenderer: ScriptedThumbnailRenderer(behaviour: .succeed),
            entitlements: FreeTierEntitlementResolver(),
            favouritesManager: favouritesManager
        )
        viewModel.load(category: .favourites)
        viewModel.cancelThumbnailWork()

        XCTAssertEqual(viewModel.presets.map(\.id), [kept.id])
        XCTAssertEqual(viewModel.unavailableFavouriteIDs, ["film.golden-memory", "film.kodak-gold"])
        // Kept in storage so a future migration entry can restore it.
        XCTAssertTrue(favouritesManager.isFavourite(presetID: "film.golden-memory"))
    }

    func testAllThumbnailsFailingLeavesEveryCellInFailedState() async {
        let viewModel = makeViewModel(
            renderer: ScriptedThumbnailRenderer(behaviour: .failAll)
        )
        viewModel.load(category: .recommended)
        await viewModel.inFlightThumbnailWork?.value

        for preset in viewModel.presets {
            XCTAssertEqual(viewModel.thumbnails[preset.id], .failed)
        }
        // A total failure is still not an error banner — the screen degrades
        // rather than interrupting.
        XCTAssertNil(viewModel.paywallPrompt)
    }

    // MARK: - Cancellation

    func testCancellingThumbnailWorkStopsRendering() async {
        let viewModel = makeViewModel(
            renderer: ScriptedThumbnailRenderer(behaviour: .hang)
        )
        viewModel.load(category: .recommended)

        viewModel.cancelThumbnailWork()
        await viewModel.inFlightThumbnailWork?.value

        // Cancellation leaves cells loading rather than marking them failed:
        // nothing went wrong, the work was simply abandoned.
        XCTAssertTrue(
            viewModel.presets.allSatisfy { viewModel.thumbnails[$0.id] == .loading }
        )
    }

    func testChangingCategoryCancelsThePreviousRender() async {
        let renderer = ScriptedThumbnailRenderer(behaviour: .hang)
        let viewModel = makeViewModel(renderer: renderer)

        viewModel.load(category: .recommended)
        let firstRender = viewModel.inFlightThumbnailWork

        viewModel.load(category: .film)

        // The superseded render must have been cancelled, not left running.
        XCTAssertEqual(firstRender?.isCancelled, true)
        XCTAssertEqual(viewModel.category, .film)

        // Cancel before awaiting: the second render also hangs by design, and
        // awaiting it would block the suite for the stub's full sleep duration.
        viewModel.cancelThumbnailWork()
        await viewModel.inFlightThumbnailWork?.value
    }

    // MARK: - Preview is always free

    /// Spec §0.3: every Look previews freely regardless of entitlement.
    func testFreeTierCanPreviewProLooks() {
        let viewModel = makeViewModel(entitlements: FreeTierEntitlementResolver())
        viewModel.load(category: .recommended)

        guard let proLook = viewModel.presets.first(where: { !$0.isIncludedInFreeTier }) else {
            return XCTFail("Expected at least one Pro Look in the recommended set")
        }

        viewModel.preview(proLook)

        XCTAssertEqual(viewModel.previewedLookID, proLook.id)
        XCTAssertNil(
            viewModel.paywallPrompt,
            "Previewing must never raise a paywall."
        )
    }

    func testIntensityIsAdjustableDuringPreviewOnTheFreeTier() {
        let viewModel = makeViewModel()
        viewModel.load(category: .recommended)
        guard let proLook = viewModel.presets.first(where: { !$0.isIncludedInFreeTier }) else {
            return XCTFail("Expected a Pro Look")
        }
        viewModel.preview(proLook)

        viewModel.setIntensity(0.4)

        XCTAssertEqual(viewModel.intensity, 0.4, accuracy: 0.001)
        XCTAssertNil(viewModel.paywallPrompt)
    }

    func testIntensityIsClamped() {
        let viewModel = makeViewModel()
        viewModel.load(category: .recommended)

        viewModel.setIntensity(2.5)
        XCTAssertEqual(viewModel.intensity, 1, accuracy: 0.001)

        viewModel.setIntensity(-1)
        XCTAssertEqual(viewModel.intensity, 0, accuracy: 0.001)
    }

    // MARK: - Entitlement enforced only at apply

    func testApplyingAProLookOnFreeTierRaisesThePaywall() {
        let viewModel = makeViewModel(entitlements: FreeTierEntitlementResolver())
        viewModel.load(category: .recommended)
        guard let proLook = viewModel.presets.first(where: { !$0.isIncludedInFreeTier }) else {
            return XCTFail("Expected a Pro Look")
        }
        viewModel.preview(proLook)

        let result = viewModel.confirmApplication()

        XCTAssertNil(result, "A gated Look must not be committed.")
        XCTAssertEqual(viewModel.paywallPrompt, .fullLooksLibrary)
    }

    func testApplyingAFreeLookOnFreeTierSucceeds() {
        let viewModel = makeViewModel(entitlements: FreeTierEntitlementResolver())
        viewModel.load(category: .recommended)
        guard let freeLook = viewModel.presets.first(where: { $0.isIncludedInFreeTier }) else {
            return XCTFail("Expected a free Look")
        }
        viewModel.preview(freeLook)

        let result = viewModel.confirmApplication()

        XCTAssertEqual(result?.preset.id, freeLook.id)
        XCTAssertNil(viewModel.paywallPrompt)
    }

    func testProSubscriberCanApplyAnyLook() {
        let viewModel = makeViewModel(entitlements: ProEntitlementResolver())
        viewModel.load(category: .recommended)
        guard let proLook = viewModel.presets.first(where: { !$0.isIncludedInFreeTier }) else {
            return XCTFail("Expected a Pro Look")
        }
        viewModel.preview(proLook)

        let result = viewModel.confirmApplication()

        XCTAssertEqual(result?.preset.id, proLook.id)
        XCTAssertNil(viewModel.paywallPrompt)
    }

    func testDismissingThePaywallLeavesThePreviewIntact() {
        let viewModel = makeViewModel()
        viewModel.load(category: .recommended)
        guard let proLook = viewModel.presets.first(where: { !$0.isIncludedInFreeTier }) else {
            return XCTFail("Expected a Pro Look")
        }
        viewModel.preview(proLook)
        _ = viewModel.confirmApplication()

        viewModel.dismissPaywall()

        XCTAssertNil(viewModel.paywallPrompt)
        XCTAssertEqual(
            viewModel.previewedLookID,
            proLook.id,
            "Declining to upgrade must not take away what the user was looking at."
        )
    }
}
