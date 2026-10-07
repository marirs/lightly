import XCTest

/// Release functionality (2026-10-07): run against a Release build with the depth and Remove gates open (the build that
/// ships after sign-off). No debug launch arguments (Release ignores them): a library photo through the system picker,
/// one Remove stroke, then Focus & Blur. Outcomes are written to /tmp/lightly-a11y/release-features.json.
final class ReleaseFeatureUITests: XCTestCase {
    private var results: [String: String] = [:]

    func testRemoveAndFocusAndBlurInRelease() throws {
        let app = XCUIApplication()
        app.launch()
        // A previous run's unsaved edit is restored on launch (Release behaviour): leave it, discarding the edit.
        let close = app.buttons["editor.close"]
        if !app.buttons["welcome.choosePhoto"].waitForExistence(timeout: 10), close.waitForExistence(timeout: 30) {
            close.tap()
            let discard = app.alerts.buttons["Discard edits"]
            if discard.waitForExistence(timeout: 5) { discard.tap() }
        }
        XCTAssertTrue(app.buttons["welcome.choosePhoto"].waitForExistence(timeout: 30))
        app.buttons["welcome.choosePhoto"].tap()
        let grid = app.scrollViews["photosView_content_scroll_view"]
        guard grid.waitForExistence(timeout: 30) else { throw XCTSkip("system photo picker did not present") }
        let explainer = app.buttons["Close"].firstMatch
        if explainer.waitForExistence(timeout: 3), explainer.isHittable { explainer.tap() }
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.12)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["develop.ruler"].waitForExistence(timeout: 90), "editor did not open")

        // Edit › Remove: one stroke across the middle of the photo.
        app.descendants(matching: .any)["tool.edit"].tap()
        let removeTab = app.descendants(matching: .any)["edit.sub.Remove"]
        XCTAssertTrue(removeTab.waitForExistence(timeout: 10))
        let width = app.windows.firstMatch.frame.maxX
        for _ in 0..<4 where removeTab.frame.maxX > width - 4 { app.descendants(matching: .any)["edit.sub.Crop"].swipeLeft() }
        removeTab.tap()
        let photo = app.descendants(matching: .any)["editor.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).press(forDuration: 0.1, thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.52)))
        let undoStroke = app.buttons["edit.remove.undoStroke"]
        let failed = app.buttons["edit.remove.retry"]
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline && !failed.exists && !(undoStroke.exists && undoStroke.isEnabled) { Thread.sleep(forTimeInterval: 1) }
        results["remove"] = failed.exists ? "failed: Couldn't remove that area" : (undoStroke.isEnabled ? "applied (Undo stroke enabled)" : "no result in 180 s")

        // Background › Focus & Blur: the blur control, or the approved depth-failure notice.
        app.descendants(matching: .any)["tool.background"].tap()
        let focus = app.descendants(matching: .any)["background.mode.focus"]
        if focus.waitForExistence(timeout: 120) { focus.tap() }
        let blur = app.descendants(matching: .any)["slider.blur"]
        let noDepth = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'measure depth'")).firstMatch
        let end = Date().addingTimeInterval(180)
        while Date() < end && !blur.exists && !noDepth.exists { Thread.sleep(forTimeInterval: 1) }
        try? app.debugDescription.write(toFile: "/tmp/lightly-a11y/release-focus.txt", atomically: true, encoding: .utf8)
        results["focusAndBlur"] = blur.exists ? "blur control shown (depth available)" : (noDepth.exists ? "depth failure notice" : "neither in 180 s")
        let url = URL(fileURLWithPath: "/tmp/lightly-a11y/release-features.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        XCTAssertEqual(results["remove"], "applied (Undo stroke enabled)")
        XCTAssertEqual(results["focusAndBlur"], "blur control shown (depth available)")
    }
}
