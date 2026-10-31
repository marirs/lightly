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

    /// App state with the bundled catalogue and a fixed version so the references do not change with the build
    /// number. The More pages take the approved Lightly 2 screens' state (`more`, `welcome-more`, `pref-favourites`):
    /// three favourites, the appearance the screen's theme shows selected, and, where [library] is given, the loaded
    /// preset pack (About's count, the favourites' thumbnails). The mockup's preset names are placeholders that are
    /// not in the catalogue, so the favourites are real presets.
    private func makeState(signatures: SignatureStore = SignatureStore(directory: nil), appearance: AppearancePreference = .system,
                           library: DevelopLibrary? = nil) -> AppState {
        let catalogue = DevelopPresetCatalogue.loadBundled()
        let favourites = FavouritePresetsStore(defaults: defaults, catalogue: catalogue)
        let seeded = [("portrait", 13), ("daylight", 37), ("film", 12)]
            .compactMap { catalogue.preset(inCategory: $0.0, atStop: $0.1)?.id }
        favourites.replaceAll(with: seeded)
        let preferences = PreferencesStore(defaults: defaults)
        preferences.appearance = appearance
        return AppState(
            photoLoader: ImageIOPhotoLoader(),
            developLibrary: library,
            preferences: preferences,
            favourites: favourites,
            signatures: signatures,
            presetCatalogue: catalogue,
            releaseContent: .none,
            appVersion: AppVersion(version: "1.0", build: "1")
        )
    }

    /// The approved screens show a saved drawn signature: the mockup's own sample (`SIG`).
    private func savedSignature() -> SignatureStore {
        let signatures = SignatureStore(directory: nil)
        signatures.saveDrawn(.lightlyTwoSample)
        return signatures
    }

    /// The bundled preset pack, loaded once for the suite (its parse and Metal set-up are slow).
    private static var loadedLibrary: DevelopLibrary?
    private func library() async throws -> DevelopLibrary {
        if let loaded = Self.loadedLibrary { return loaded }
        let library = DevelopLibrary()
        await library.loadBundled(lutApplier: try MetalLUTRenderer())
        XCTAssertEqual(library.state, .ready)
        Self.loadedLibrary = library
        return library
    }

    /// Renders the favourites' sample thumbnails first: a snapshot is a single pass, so they must already be cached
    /// (FavouriteThumbnail shows a cached one at once) instead of arriving from the view's task.
    private func warmThumbnails(_ state: AppState) async {
        for id in state.favourites.presetIDs {
            guard let preset = state.developLibrary.pack.preset(id: id) else { XCTFail("favourite \(id) is not in the pack"); continue }
            _ = await EditorSession.sampleThumbnail(preset, library: state.developLibrary)
        }
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

    func testWelcomeAccessibilityTextSize() throws {
        // Owner, 2026-10-21: no pixel reference yet (the mockup has no screen at this size); without the skip the
        // harness would record one. The size is still checked for clipping, overlap, scrolling and usable controls by
        // AccessibilityAuditUITests.testWelcomeAndMoreAtLargestTextHaveNoClippingOverlapOrUnreachableControls.
        try XCTSkipIf(true, "Largest text size: no pixel reference yet; layout checked by AccessibilityAuditUITests")
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

    func testMoreMenu() async throws {
        let state = makeState(signatures: savedSignature(), appearance: .light, library: try await library())
        await warmThumbnails(state)
        SnapshotAssertion.assert(of: page(.menu, state: state), named: "more-menu")
    }
    // Lightly 2: the preferences live on the More page itself (no Preferences page).
    func testMoreMenuDark() async throws {
        let state = makeState(signatures: savedSignature(), appearance: .dark, library: try await library())
        await warmThumbnails(state)
        SnapshotAssertion.assert(of: page(.menu, state: state), named: "more-menu-dark", colorScheme: .dark)
    }
    func testMoreMenuAccessibilityTextSize() async throws {
        // As testWelcomeAccessibilityTextSize: no pixel reference yet; the layout is checked by the UI test.
        try XCTSkipIf(true, "Largest text size: no pixel reference yet; layout checked by AccessibilityAuditUITests")
        let state = makeState(signatures: savedSignature(), appearance: .light, library: try await library())
        await warmThumbnails(state)
        let view = page(.menu, state: state).environment(\.dynamicTypeSize, .accessibility3)
        SnapshotAssertion.assert(of: view, named: "more-menu-accessibility3")
    }
    func testFavourites() async throws {
        let state = makeState(library: try await library())
        await warmThumbnails(state)
        SnapshotAssertion.assert(of: page(.favourites, state: state), named: "more-favourites")
    }
    /// The approved page with a saved (drawn) signature: the mockup's sample.
    func testSavedSignature() {
        SnapshotAssertion.assert(of: page(.savedSignature, state: makeState(signatures: savedSignature())), named: "more-signature")
    }
    func testPreferredBorder() { SnapshotAssertion.assert(of: page(.preferredBorder, state: makeState()), named: "more-border") }
    func testLegal() { SnapshotAssertion.assert(of: page(.legal, state: makeState()), named: "more-legal") }
    /// The document-missing failure state stays tested, but its appearance has no approved design yet (owner,
    /// 2026-10-21), so no reference is compared or recorded until it has one.
    func testPrivacyPolicyUnavailable() throws {
        try XCTSkipIf(true, "Privacy Policy unavailable: no approved design for this state yet")
        SnapshotAssertion.assert(of: page(.privacyPolicy, state: makeState()), named: "more-privacy")
    }
    /// About › Presets counts the loaded pack.
    func testAbout() async throws {
        SnapshotAssertion.assert(of: page(.about, state: makeState(library: try await library())), named: "more-about")
    }
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
        case .legal, .about, .favourites, .savedSignature, .preferredBorder: [.menu, page]
        case .privacyPolicy, .termsOfUse: [.menu, .legal, page]
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

    /// At the default size everything fits without scrolling: the link as drawn (the mockup's text + 10 pt padding box)
    /// sits above Welcome's 10 pt bottom padding. Its 44 pt touch target is centred on that box, so it reaches a few
    /// points into the padding by design, but stays on screen.
    func testDefaultSizeFitsTheScreen() throws {
        try assertLayout(at: .large)
        let layout = LayoutProbe(
            WelcomeView().environment(AppState(photoLoader: ImageIOPhotoLoader())),
            size: SnapshotAssertion.defaultSize, dynamicTypeSize: .large
        )
        defer { layout.tearDown() }
        let visibleLink = try XCTUnwrap(layout.frame("welcome.privacyPolicy.label"))
        let target = try XCTUnwrap(layout.frame("welcome.privacyPolicy"))
        XCTAssertLessThanOrEqual(visibleLink.maxY, SnapshotAssertion.defaultSize.height - 10 + 0.5)
        XCTAssertLessThanOrEqual(target.maxY, SnapshotAssertion.defaultSize.height)
        XCTAssertEqual(target.midY, visibleLink.midY, accuracy: 0.5, "the target is centred on the visible link")
    }

    func testAccessibility3() throws { try assertLayout(at: .accessibility3) }
    func testAccessibility5() throws { try assertLayout(at: .accessibility5) }
}

extension DrawnSignature {
    /// The Lightly 2 mockup's drawn signature (`SIG`: view box 58 × 22, stroke 1.6,
    /// `M2 16c5 0 6-12 9-12s1 12 4 12 3-8 6-8 3 6 7 6 4-10 8-10 2 10 6 10 5-4 14-4`), flattened to points. The
    /// smooth segments (`s`) take their first control point as the reflection of the previous second one.
    static let lightlyTwoSample: DrawnSignature = {
        // (first control, second control, end), absolute, from the path above.
        let start = Point(x: 2, y: 16)
        let segments: [(Point, Point, Point)] = [
            (Point(x: 7, y: 16), Point(x: 8, y: 4), Point(x: 11, y: 4)),
            (Point(x: 14, y: 4), Point(x: 12, y: 16), Point(x: 15, y: 16)),
            (Point(x: 18, y: 16), Point(x: 18, y: 8), Point(x: 21, y: 8)),
            (Point(x: 24, y: 8), Point(x: 24, y: 14), Point(x: 28, y: 14)),
            (Point(x: 32, y: 14), Point(x: 32, y: 4), Point(x: 36, y: 4)),
            (Point(x: 40, y: 4), Point(x: 38, y: 14), Point(x: 42, y: 14)),
            (Point(x: 46, y: 14), Point(x: 47, y: 10), Point(x: 56, y: 10)),
        ]
        var points = [start]
        var current = start
        for (c1, c2, end) in segments {
            for step in 1...16 {
                let t = Double(step) / 16, u = 1 - t
                points.append(Point(x: u * u * u * current.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x,
                                    y: u * u * u * current.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y))
            }
            current = end
        }
        return DrawnSignature(strokes: [points], viewBox: Box(x: 0, y: 0, width: 58, height: 22), strokeWidth: 1.6)
    }()
}
