import XCTest

/// Lightly 2 tabs scroll sideways: the Develop categories (owner report 2026-10-10: "I cannot scroll the categories").
final class TabScrollUITests: XCTestCase {
    func testDevelopCategoriesScrollSideways() throws {
        let app = XCUIApplication()
        let photo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/ui/assets/photos/portrait_medium_02.jpg").path
        app.launchArguments = ["--reset-preferences", "--open-photo", photo, "--scenario", "dev-preset"]
        app.launch()
        let landscape = app.buttons["develop.category.daylight"]   // a collection past the first screen (curated pack, 2026-10-11)
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

    /// Owner report 2026-10-11: the trailing "more this way" fade stayed on once a row was scrolled to its end. The
    /// preset gallery and the light-leak gallery fade their end ("More") at the start and not ("End") at the end.
    func testPresetGalleryFadesOnlyWhileMoreIsPastTheEnd() throws {
        try assertTrailingFadeFollowsScroll(scenario: "dev-preset", gallery: "develop.gallery.compact")
    }

    func testLeakGalleryFadesOnlyWhileMoreIsPastTheEnd() throws {
        try assertTrailingFadeFollowsScroll(scenario: "fx-leak", gallery: "effects.leak.gallery")
    }

    private func assertTrailingFadeFollowsScroll(scenario: String, gallery identifier: String) throws {
        let app = XCUIApplication()
        let photo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/ui/assets/photos/portrait_medium_02.jpg").path
        app.launchArguments = ["--reset-preferences", "--open-photo", photo, "--scenario", scenario]
        app.launch()
        let gallery = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(gallery.waitForExistence(timeout: 30), "\(identifier) did not appear")
        sleep(2)
        let fadeShown = NSPredicate(format: "value == %@", "More"), fadeGone = NSPredicate(format: "value == %@", "End")
        XCTAssertEqual(gallery.value as? String, "More", "\(identifier): no trailing fade at the start")
        var swipes = 0
        while (gallery.value as? String) != "End" && swipes < 40 {
            // A horizontal drag through the middle of the gallery: never vertical enough to expand the preset gallery.
            let start = gallery.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            start.press(forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: -300, dy: 0)), withVelocity: .fast, thenHoldForDuration: 0)
            swipes += 1
        }
        expectation(for: fadeGone, evaluatedWith: gallery); waitForExpectations(timeout: 3)
        let end = XCTAttachment(screenshot: app.screenshot()); end.name = "\(identifier)-end"; end.lifetime = .keepAlways; add(end)
        // Back from the end: the fade returns.
        let start = gallery.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        start.press(forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: 250, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.3)
        expectation(for: fadeShown, evaluatedWith: gallery); waitForExpectations(timeout: 3)
    }
}
