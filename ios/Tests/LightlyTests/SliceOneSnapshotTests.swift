import SwiftUI
import XCTest
@testable import Lightly

/// Reference images for the slice-1 screens (Welcome, the recovery screens and every More page)
/// so later work cannot silently change them. The side-by-side comparison with the prototype
/// lives outside the suite (`docs/v1/slice1-ios.md`).
@MainActor
final class SliceOneSnapshotTests: XCTestCase {

    /// A private defaults domain per test case instance, removed afterwards.
    private let suiteName = "SliceOneSnapshotTests.\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    /// App state with the bundled catalogue, the five favourites the approved screens show and a
    /// fixed version so the references do not change with the build number.
    private func makeState(signatures: SignatureStore = SignatureStore(directory: nil)) -> AppState {
        let catalogue = DevelopPresetCatalogue.loadBundled()
        let favourites = FavouritePresetsStore(defaults: defaults, catalogue: catalogue)
        let seeded = [("portrait", 13), ("landscape", 37), ("film", 12), ("golden-hour", 4), ("black-white", 3)]
            .compactMap { catalogue.preset(inCategory: $0.0, atStop: $0.1)?.id }
        favourites.replaceAll(with: seeded)
        return AppState(
            photoLoader: ImageIOPhotoLoader(),
            preferences: PreferencesStore(defaults: defaults),
            favourites: favourites,
            signatures: signatures,
            presetCatalogue: catalogue,
            releaseContent: .none,
            appVersion: AppVersion(version: "1.0", build: "1")
        )
    }

    /// A More page as it sits in the phone sheet (below the grabber).
    private func page(_ page: MorePage, state: AppState) -> some View {
        MorePageHost(page: page)
            .environment(state)
    }

    // MARK: - Welcome

    func testWelcomeLight() {
        SnapshotAssertion.assert(of: WelcomeView().environment(makeState()), named: "welcome-light")
    }

    func testWelcomeDark() {
        SnapshotAssertion.assert(of: WelcomeView().environment(makeState()), named: "welcome-dark", colorScheme: .dark)
    }

    func testWelcomeAccessibilityTextSize() {
        let view = WelcomeView().environment(makeState()).environment(\.dynamicTypeSize, .accessibility3)
        SnapshotAssertion.assert(of: view, named: "welcome-accessibility3")
    }

    // MARK: - Recovery

    func testCameraAccessOff() {
        SnapshotAssertion.assert(of: CameraAccessOffView().environment(makeState()), named: "camera-denied-light")
    }

    func testPhotoCannotBeOpenedDark() {
        SnapshotAssertion.assert(of: PhotoCannotBeOpenedView().environment(makeState()), named: "load-failed-dark", colorScheme: .dark)
    }

    // MARK: - More pages

    func testMoreMenu() { SnapshotAssertion.assert(of: page(.menu, state: makeState()), named: "more-menu") }
    func testPreferences() { SnapshotAssertion.assert(of: page(.preferences, state: makeState()), named: "more-preferences") }
    func testPreferencesDark() {
        SnapshotAssertion.assert(of: page(.preferences, state: makeState()), named: "more-preferences-dark", colorScheme: .dark)
    }
    func testPreferencesAccessibilityTextSize() {
        let view = page(.preferences, state: makeState()).environment(\.dynamicTypeSize, .accessibility3)
        SnapshotAssertion.assert(of: view, named: "more-preferences-accessibility3")
    }
    func testFavourites() { SnapshotAssertion.assert(of: page(.favourites, state: makeState()), named: "more-favourites") }
    /// Slice 5: the approved page with a saved (drawn) signature: the prototype's sample.
    func testSavedSignature() {
        let signatures = SignatureStore(directory: nil)
        signatures.saveDrawn(.prototypeSample)
        SnapshotAssertion.assert(of: page(.savedSignature, state: makeState(signatures: signatures)), named: "more-signature")
    }
    func testPreferredBorder() { SnapshotAssertion.assert(of: page(.preferredBorder, state: makeState()), named: "more-border") }
    func testLegal() { SnapshotAssertion.assert(of: page(.legal, state: makeState()), named: "more-legal") }
    func testPrivacyPolicyUnavailable() { SnapshotAssertion.assert(of: page(.privacyPolicy, state: makeState()), named: "more-privacy") }
    func testAbout() { SnapshotAssertion.assert(of: page(.about, state: makeState()), named: "more-about") }
    func testSupportUnavailable() { SnapshotAssertion.assert(of: page(.support, state: makeState()), named: "more-support") }
}

/// Opens `MoreSheet` directly on one page, the way the sheet shows it after navigating there.
private struct MorePageHost: View {
    let page: MorePage
    var body: some View {
        MoreSheet(entry: .menu, initialPath: page == .menu ? [.menu] : pathTo(page))
            .padding(.top, 23)
            .background(ApprovedColor.sheet.dynamic)
    }

    private func pathTo(_ page: MorePage) -> [MorePage] {
        switch page {
        case .menu: [.menu]
        case .preferences, .legal, .about: [.menu, page]
        case .favourites, .savedSignature, .preferredBorder: [.menu, .preferences, page]
        case .privacyPolicy, .termsOfUse: [.menu, .legal, page]
        case .support: [.menu, .about, page]
        }
    }
}

/// Welcome keeps its content apart and on screen at every text size.
@MainActor
final class WelcomeLayoutTests: XCTestCase {

    private func assertLayout(at size: DynamicTypeSize, file: StaticString = #filePath, line: UInt = #line) throws {
        let layout = LayoutProbe(
            WelcomeView().environment(AppState(photoLoader: ImageIOPhotoLoader())),
            size: SnapshotAssertion.defaultSize, dynamicTypeSize: size
        )
        defer { layout.tearDown() }
        let brand = try XCTUnwrap(layout.frame("welcome.brand"), file: file, line: line)
        let actions = try XCTUnwrap(layout.frame("welcome.actions"), file: file, line: line)
        let link = try XCTUnwrap(layout.frame("welcome.privacyPolicy"), file: file, line: line)
        XCTAssertLessThanOrEqual(brand.maxY, actions.minY, "Brand overlaps the buttons at \(size)", file: file, line: line)
        XCTAssertLessThanOrEqual(actions.maxY, link.minY, "Buttons overlap the link at \(size)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(link.height, 44, "Privacy Policy target below 44 pt at \(size)", file: file, line: line)
    }

    /// At the default size everything fits without scrolling: the link sits above the bottom space.
    func testDefaultSizeFitsTheScreen() throws {
        try assertLayout(at: .large)
        let layout = LayoutProbe(
            WelcomeView().environment(AppState(photoLoader: ImageIOPhotoLoader())),
            size: SnapshotAssertion.defaultSize, dynamicTypeSize: .large
        )
        defer { layout.tearDown() }
        let link = try XCTUnwrap(layout.frame("welcome.privacyPolicy"))
        XCTAssertLessThanOrEqual(link.maxY, SnapshotAssertion.defaultSize.height - WelcomeView.bottomSpace(forScreenHeight: SnapshotAssertion.defaultSize.height) + 0.5)
    }

    func testAccessibility3() throws { try assertLayout(at: .accessibility3) }
    func testAccessibility5() throws { try assertLayout(at: .accessibility5) }
}
