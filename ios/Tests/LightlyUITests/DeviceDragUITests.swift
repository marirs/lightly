import XCTest

/// Device acceptance of Auto and the live preset ruler (2026-10-08), with Background off and on. Runs on the dev iPhone
/// against the diagnostic build (Release optimisation; DEBUG launch arguments): the red-wall portrait copied to
/// Documents/pm02.jpg and launched by the script with `--keep-stored-session --session-store dragcheck --keep-awake
/// --open-photo pm02.jpg`: a separate session store (`--session-store dragcheck`) and `--keep-stored-session`, so the
/// owner's disposable edit is neither read nor written. Visible frames during a drag are read from the app's trace
/// ("ruler: first drag frame visible after N ms"); this test checks the final state and one Undo step per gesture.
/// Results are printed as "DRAGCHECK …" lines.
final class DeviceDragUITests: XCTestCase {
    // The app is launched by the device script (devicectl, with the arguments below) and attached to here: launching it
    // through XCTest on the dev phone fails ("process identifier ... could not be determined", 2026-10-08).
    private let app = XCUIApplication(bundleIdentifier: "com.lightlylabs.lightly")
    private let timeout: TimeInterval = 60

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["LIGHTLY_DEVICE_DRAG"] != nil else { throw XCTSkip("set LIGHTLY_DEVICE_DRAG (device run only)") }
        app.activate()
        XCTAssertTrue(element("develop.ruler").waitForExistence(timeout: 120), "editor did not open")
    }

    private func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }
    private func label(_ identifier: String) -> String { element(identifier).label }
    private func waitFor(_ seconds: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.2) }
        return condition()
    }
    private func report(_ line: String) { print("DRAGCHECK \(line)") }

    /// A slow drag of the ruler by about `stops` stops, finger held briefly before release.
    private func dragRuler(by stops: Int) {
        let start = element("develop.ruler").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -CGFloat(stops) * 12, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    private func undoCount(back target: () -> Bool) -> Int {
        var taps = 0
        while !target() && app.buttons["editor.undo"].isEnabled && taps < 5 {
            app.buttons["editor.undo"].tap(); taps += 1
            _ = waitFor(10, target)
        }
        return taps
    }

    private func checkAutoAndDrag(context: String) {
        let before = label("develop.name"), beforePosition = label("develop.position")
        report("\(context) start name=\(before) position=\(beforePosition)")
        // Auto off: one step; Undo restores it.
        element("develop.auto").tap()
        let autoOff = waitFor { self.element("develop.auto").value as? String == "Off" || self.label("develop.name") == "Original" }
        app.buttons["editor.undo"].tap()
        let autoBack = waitFor { self.label("develop.name") == before }
        report("\(context) auto off=\(autoOff) undo-restores=\(autoBack) name=\(label("develop.name"))")
        XCTAssertTrue(autoOff && autoBack, "\(context): Auto toggle and one Undo")

        dragRuler(by: 5)
        let moved = waitFor { self.label("develop.position") != beforePosition }
        let applied = label("develop.name"), appliedPosition = label("develop.position")
        report("\(context) drag moved=\(moved) name=\(applied) position=\(appliedPosition)")
        XCTAssertTrue(moved, "\(context): the drag applied a preset")
        let taps = undoCount { self.label("develop.name") == before && self.label("develop.position") == beforePosition }
        report("\(context) undo taps to return=\(taps)")
        XCTAssertEqual(taps, 1, "\(context): one Undo step per completed drag")
        app.buttons["editor.redo"].tap()
        let redone = waitFor { self.label("develop.name") == applied && self.label("develop.position") == appliedPosition }
        report("\(context) redo returns the dragged preset=\(redone)")
        XCTAssertTrue(redone)
    }

    func testAutoAndRulerWithBackgroundOffThenOn() throws {
        checkAutoAndDrag(context: "background-off")

        // Background on: Change background, Colour, Charcoal.
        element("tool.background").tap()
        let change = element("background.mode.change")
        XCTAssertTrue(change.waitForExistence(timeout: 120)); change.tap()
        element("background.kind.Colour").tap()
        let charcoal = element("background.colour.#1F2328")
        XCTAssertTrue(charcoal.waitForExistence(timeout: timeout)); charcoal.tap()
        XCTAssertTrue(element("background.remove").waitForExistence(timeout: timeout))
        report("background on: \(element("tool.background").value as? String ?? "-")")
        element("tool.develop").tap()
        XCTAssertTrue(element("develop.ruler").waitForExistence(timeout: timeout))
        checkAutoAndDrag(context: "background-on")
        XCTAssertEqual(element("tool.background").value as? String, "Edited", "The background change survived the develop steps")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.lifetime = .keepAlways; add(shot)

        // Save copy with the replacement active, through the interface (writes one new photo to the library).
        let started = Date()
        app.buttons["editor.saveCopy"].tap()
        let allow = app.alerts.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Allow'")).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let saved = element("saved.title").waitForExistence(timeout: 120)
        let failed = app.alerts.firstMatch.exists ? app.alerts.firstMatch.label : "-"
        report("save with replacement: saved=\(saved) after \(Int(Date().timeIntervalSince(started) * 1000)) ms alert=\(failed) state=\(app.state.rawValue)")
        XCTAssertTrue(saved, "Save copy with the replacement completed")
    }
}
