import XCTest

/// Release functionality (2026-10-07): run against a Release build with the depth and Remove gates open (the build that
/// ships after sign-off). No debug launch arguments (Release ignores them): a library photo through the system picker,
/// one Eraser mark and Erase, then Focus & Blur. Outcomes are written to /tmp/lightly-a11y/release-features.json.
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
        // The Lightly 2 editor opens on the preset gallery (no Develop ruler), so the dock is the sign it is open.
        XCTAssertTrue(app.buttons["tool.develop"].waitForExistence(timeout: 90), "editor did not open")

        // Edit › Eraser (was "Remove" before the 1.2 Eraser): brush one mark, then Erase runs the inpainting model.
        app.descendants(matching: .any)["tool.edit"].tap()
        let eraserTab = app.descendants(matching: .any)["edit.sub.Eraser"]
        XCTAssertTrue(eraserTab.waitForExistence(timeout: 10))
        let width = app.windows.firstMatch.frame.maxX
        for _ in 0..<4 where eraserTab.frame.maxX > width - 4 { app.descendants(matching: .any)["edit.sub.Crop"].swipeLeft() }
        eraserTab.tap()
        let photo = app.descendants(matching: .any)["editor.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).press(forDuration: 0.1, thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.52)))
        let erase = app.descendants(matching: .any)["edit.remove.erase"].firstMatch
        let undoStroke = app.descendants(matching: .any)["edit.remove.undoStroke"].firstMatch
        let processing = app.descendants(matching: .any)["processing.overlay"].firstMatch
        XCTAssertTrue(erase.waitForExistence(timeout: 10) && erase.isEnabled, "the mark enables Erase")
        erase.tap()
        // A successful Erase clears the marks (Erase disabled) and leaves the batch undoable.
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline && (processing.exists || erase.isEnabled) { Thread.sleep(forTimeInterval: 1) }
        let applied = !processing.exists && !erase.isEnabled && undoStroke.isEnabled
        results["remove"] = applied ? "applied (Undo stroke enabled)" : "no result in 180 s"

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
