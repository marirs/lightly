import XCTest

/// The built app carries its icon (the same checks as
/// `scripts/check_app_icon.sh`, which also runs as the app target's last
/// build phase). Unit tests are hosted in Lightly.app, so `Bundle.main` here
/// is the built product, not the sources: an asset catalog left out of the
/// target's Resources phase fails this even though the files exist.
final class AppIconPackagingTests: XCTestCase {

    private let app = Bundle.main

    func testHostIsTheLightlyApp() {
        XCTAssertEqual(app.bundleIdentifier, "com.lightlylabs.lightly")
    }

    func testInfoPlistNamesTheAppIcon() throws {
        let icons = try XCTUnwrap(app.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any], "CFBundleIcons missing")
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any], "CFBundlePrimaryIcon missing")
        XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon")
        XCTAssertFalse((primary["CFBundleIconFiles"] as? [String] ?? []).isEmpty, "CFBundleIconFiles missing or empty")
    }

    func testCompiledAssetCatalogAndHomeScreenIconAreBundled() {
        XCTAssertNotNil(app.url(forResource: "Assets", withExtension: "car"), "Assets.car missing from the app")
        XCTAssertNotNil(app.url(forResource: "AppIcon60x60@2x", withExtension: "png"), "Home-screen icon missing from the app")
    }
}
