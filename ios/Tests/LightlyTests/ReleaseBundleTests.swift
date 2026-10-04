import XCTest
@testable import Lightly

/// Release register items checked on the built app bundle.
final class ReleaseBundleTests: XCTestCase {

    /// PrivacyInfo.xcprivacy is bundled: no tracking, no collected data, and the required-reason
    /// APIs the app uses (UserDefaults CA92.1, system boot time 35F9.1).
    func testThePrivacyManifestIsBundledAndDeclaresTheAPIsUsed() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)
        let apis = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let reasons = Dictionary(uniqueKeysWithValues: apis.map { ($0["NSPrivacyAccessedAPIType"] as? String ?? "", $0["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []) })
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategorySystemBootTime"], ["35F9.1"])
    }

    func testTheLookPackIsBundled() {
        XCTAssertNotNil(Bundle.main.url(forResource: "LookPack", withExtension: nil), "format-3 Look pack folder")
    }
}
