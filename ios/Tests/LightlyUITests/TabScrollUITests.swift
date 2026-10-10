import XCTest

/// Lightly 2 tabs scroll sideways: the Develop categories (owner report 2026-10-10: "I cannot scroll the categories").
final class TabScrollUITests: XCTestCase {
    func testDevelopCategoriesScrollSideways() throws {
        let app = XCUIApplication()
        let photo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/ui/assets/photos/portrait_medium_02.jpg").path
        app.launchArguments = ["--reset-preferences", "--open-photo", photo, "--scenario", "dev-preset"]
        app.launch()
        let landscape = app.buttons["develop.category.landscape"]
        XCTAssertTrue(landscape.waitForExistence(timeout: 20))
        sleep(3)
        let before = landscape.frame.minX
        let start = landscape.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -220, dy: 0)))
        sleep(1)
        let after = landscape.frame.minX
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.lifetime = .keepAlways; add(shot)
        XCTAssertLessThan(after, before - 60, "tabs did not scroll: \(before) → \(after)")
    }
}
