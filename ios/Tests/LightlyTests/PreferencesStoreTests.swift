import XCTest
@testable import Lightly

/// Preferences persist across launches (a new store over the same defaults stands in for a
/// relaunch) and read as the approved defaults when nothing, or something unreadable, is stored.
@MainActor
final class PreferencesStoreTests: XCTestCase {

    /// A private defaults domain per test case instance, removed afterwards.
    private let suiteName = "PreferencesStoreTests.\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    func testApprovedDefaults() {
        let store = PreferencesStore(defaults: defaults)

        XCTAssertEqual(store.appearance, .system)
        XCTAssertTrue(store.keepsPhotoMetadata, "Keep photo metadata defaults on")
        XCTAssertFalse(store.includesLocation, "Include location defaults off")
        XCTAssertEqual(store.preferredBorder, .none, "Preferred border defaults to None")
        XCTAssertEqual(store.exportMetadataPolicy, .default)
    }

    func testEveryPreferenceSurvivesARelaunch() {
        let first = PreferencesStore(defaults: defaults)
        first.appearance = .dark
        first.keepsPhotoMetadata = false
        first.includesLocation = true
        first.preferredBorder = .polaroid

        let relaunched = PreferencesStore(defaults: defaults)

        XCTAssertEqual(relaunched.appearance, .dark)
        XCTAssertFalse(relaunched.keepsPhotoMetadata)
        XCTAssertTrue(relaunched.includesLocation)
        XCTAssertEqual(relaunched.preferredBorder, .polaroid)
    }

    /// Turning one switch off never changes the other, in either direction.
    func testMetadataSwitchesAreIndependent() {
        let store = PreferencesStore(defaults: defaults)

        store.keepsPhotoMetadata = false
        XCTAssertFalse(store.includesLocation)
        store.includesLocation = true
        XCTAssertFalse(store.keepsPhotoMetadata, "Location on does not turn metadata back on")
        store.keepsPhotoMetadata = true
        XCTAssertTrue(store.includesLocation, "Metadata on does not change location")
        store.includesLocation = false
        XCTAssertTrue(store.keepsPhotoMetadata, "Location off does not turn metadata off")
    }

    func testSaveCopySettingsFollowTheSwitches() {
        let store = PreferencesStore(defaults: defaults)
        store.keepsPhotoMetadata = false
        store.includesLocation = true

        let settings = store.saveCopySettings

        XCTAssertEqual(settings.format, .jpeg, "Save copy is always a new JPEG")
        XCTAssertEqual(settings.metadataPolicy, ExportMetadataPolicy(keepsCaptureMetadata: false, includesLocation: true))
    }

    func testUnreadableStoredValuesReadAsDefaults() {
        defaults.set("sepia", forKey: PreferencesStore.Key.appearance)
        defaults.set("rainbow", forKey: PreferencesStore.Key.preferredBorder)
        defaults.set("yes", forKey: PreferencesStore.Key.keepsPhotoMetadata)

        let store = PreferencesStore(defaults: defaults)

        XCTAssertEqual(store.appearance, .system)
        XCTAssertEqual(store.preferredBorder, .none)
        XCTAssertTrue(store.keepsPhotoMetadata)
    }

    func testAppearanceMapsToTheWindowOverride() {
        XCTAssertEqual(AppearancePreference.system.interfaceStyle, .unspecified)
        XCTAssertEqual(AppearancePreference.light.interfaceStyle, .light)
        XCTAssertEqual(AppearancePreference.dark.interfaceStyle, .dark)
        XCTAssertNil(AppearancePreference.system.colorScheme)
    }

    func testRemoveAllRestoresDefaults() {
        let store = PreferencesStore(defaults: defaults)
        store.includesLocation = true
        PreferencesStore.removeAll(from: defaults)

        XCTAssertFalse(PreferencesStore(defaults: defaults).includesLocation)
    }
}

/// Favourites: up to five ordered shortcuts, ids from the approved Develop catalogue.
@MainActor
final class FavouritePresetsStoreTests: XCTestCase {

    /// A private defaults domain per test case instance, removed afterwards.
    private let suiteName = "FavouritePresetsStoreTests.\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    func testAddsUpToFiveInOrderThenReportsFull() {
        let store = FavouritePresetsStore(defaults: defaults)
        for id in ["a", "b", "c", "d", "e"] {
            XCTAssertEqual(store.add(id), .added)
        }
        XCTAssertEqual(store.add("f"), .full)
        XCTAssertEqual(store.add("c"), .alreadyFavourite)
        XCTAssertEqual(store.presetIDs, ["a", "b", "c", "d", "e"])
        XCTAssertEqual(store.freeSlots, 0)
    }

    func testReorderRemoveAndReplacePersist() {
        let store = FavouritePresetsStore(defaults: defaults)
        ["a", "b", "c"].forEach { store.add($0) }

        store.move(from: 0, to: 2)
        XCTAssertEqual(store.presetIDs, ["b", "c", "a"])
        store.replace("c", with: "z")
        XCTAssertEqual(store.presetIDs, ["b", "z", "a"])
        store.remove("b")

        XCTAssertEqual(FavouritePresetsStore(defaults: defaults).presetIDs, ["z", "a"], "Order survives a relaunch")
    }

    func testOutOfRangeMovesChangeNothing() {
        let store = FavouritePresetsStore(defaults: defaults)
        ["a", "b"].forEach { store.add($0) }
        store.move(from: 0, to: 5)
        store.move(from: -1, to: 0)
        XCTAssertEqual(store.presetIDs, ["a", "b"])
    }

    func testIdsMissingFromTheCatalogueAreDroppedOnLoad() {
        defaults.set(["look-known", "look-gone", "look-known"], forKey: FavouritePresetsStore.storageKey)
        let catalogue = DevelopPresetCatalogue(categories: [
            .init(id: "film", name: "Film", presets: [.init(id: "look-known", displayName: "Known", stop: 1)])
        ])

        let store = FavouritePresetsStore(defaults: defaults, catalogue: catalogue)

        XCTAssertEqual(store.presetIDs, ["look-known"])
    }

    func testDoesNotShareTheLegacyLooksFavourites() {
        defaults.set(["legacy-look"], forKey: "lightly.user.favourite_presets")
        XCTAssertEqual(FavouritePresetsStore(defaults: defaults).presetIDs, [])
    }
}

/// The bundled approved catalogue and release content.
final class BundledContentTests: XCTestCase {

    func testTheApprovedDevelopCatalogueIsBundled() throws {
        let catalogue = DevelopPresetCatalogue.loadBundled()

        XCTAssertEqual(catalogue.categories.count, 9)
        let portrait = try XCTUnwrap(catalogue.categories.first { $0.id == "portrait" })
        XCTAssertEqual(portrait.name, "Portrait")
        // The five favourites the approved Preferences screens show.
        for (category, stop) in [("portrait", 13), ("landscape", 37), ("film", 12), ("golden-hour", 4), ("black-white", 3)] {
            let preset = try XCTUnwrap(catalogue.preset(inCategory: category, atStop: stop), "\(category) \(stop)")
            XCTAssertEqual(catalogue.entry(forPresetID: preset.id)?.category.id, category)
        }
    }

    /// Release text is pending (plan D2): the bundled file is empty and must stay free of
    /// placeholder text until the product owner supplies it.
    func testBundledReleaseContentIsEmptyUntilSupplied() {
        let content = ReleaseContent.loadBundled()

        XCTAssertEqual(content.schemaVersion, 1)
        XCTAssertNil(content.availablePrivacyPolicy)
        XCTAssertNil(content.availableTermsOfUse)
        XCTAssertNil(content.supportURL)
    }

    func testDocumentsWithTextAreShownAndBlankOnesAreNot() throws {
        let json = """
        {"schemaVersion": 1,
         "privacyPolicy": {"sections": [{"heading": "Photos", "paragraphs": ["Text."]}]},
         "termsOfUse": {"sections": [{"heading": null, "paragraphs": ["  "]}]},
         "support": {"url": "mailto:help@example.org"}}
        """
        let content = try ReleaseContent.decode(Data(json.utf8))

        XCTAssertEqual(content.availablePrivacyPolicy?.sections.first?.paragraphs, ["Text."])
        XCTAssertNil(content.availableTermsOfUse, "Whitespace is not a document")
        XCTAssertEqual(content.supportURL?.scheme, "mailto")
    }

    func testOnlyMailAndWebSupportDestinationsAreOpened() throws {
        let json = #"{"schemaVersion": 1, "privacyPolicy": null, "termsOfUse": null, "support": {"url": "tel:123"}}"#
        XCTAssertNil(try ReleaseContent.decode(Data(json.utf8)).supportURL)
    }

    func testAnUnknownSchemaIsRejected() {
        let json = #"{"schemaVersion": 2, "privacyPolicy": null, "termsOfUse": null, "support": null}"#
        XCTAssertThrowsError(try ReleaseContent.decode(Data(json.utf8)))
    }

    func testVersionAndBuildComeFromTheBundle() {
        let version = AppVersion(bundle: .main)
        XCTAssertEqual(version.version, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertEqual(version.build, Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        XCTAssertFalse(version.version.isEmpty)
    }
}

/// The prototype's icon path data, parsed natively.
final class ApprovedIconTests: XCTestCase {

    func testCameraOutlineSpansThePrototypeBounds() {
        // "M4 8.5A2.5 2.5 0 0 1 6.5 6h1.6l1.4-2h5l1.4 2h1.6A2.5 2.5 0 0 1 20 8.5v8A2.5 2.5 0 0 1 17.5 19h-11A2.5 2.5 0 0 1 4 16.5z"
        let bounds = SVGPathParser.path(
            "M4 8.5A2.5 2.5 0 0 1 6.5 6h1.6l1.4-2h5l1.4 2h1.6A2.5 2.5 0 0 1 20 8.5v8A2.5 2.5 0 0 1 17.5 19h-11A2.5 2.5 0 0 1 4 16.5z"
        ).boundingRect
        XCTAssertEqual(bounds.minX, 4, accuracy: 0.01)
        XCTAssertEqual(bounds.maxX, 20, accuracy: 0.01)
        XCTAssertEqual(bounds.minY, 4, accuracy: 0.01)
        XCTAssertEqual(bounds.maxY, 19, accuracy: 0.01)
    }

    func testRelativeImplicitLinesAndCompactNumbers() {
        // Back chevron: "M15 5l-7 7 7 7" → (15,5) (8,12) (15,19).
        let back = SVGPathParser.path("M15 5l-7 7 7 7").boundingRect
        XCTAssertEqual(back, CGRect(x: 8, y: 5, width: 7, height: 14))
        // Photo's mountain line: "4.5-4.5" is two numbers.
        let line = SVGPathParser.path("M4 17l4.5-4.5 4 4 2.5-2.5 5 5").boundingRect
        XCTAssertEqual(line.minY, 12.5, accuracy: 0.001)
        XCTAssertEqual(line.maxX, 20, accuracy: 0.001)
    }

    func testEveryIconHasGeometry() {
        for icon in ApprovedIcon.allCases {
            XCTAssertFalse(icon.elements.isEmpty, "\(icon)")
            for case .path(let data, _) in icon.elements {
                XCTAssertFalse(SVGPathParser.path(data).isEmpty, "\(icon) path parsed to nothing")
            }
        }
    }
}
