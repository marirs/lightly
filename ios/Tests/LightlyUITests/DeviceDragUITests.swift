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
        SystemAlertGuard.install(on: self)
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
        // Auto toggled (it opens off since 2026-10-11): one step; Undo restores the previous state.
        let autoBefore = element("develop.auto").value as? String
        element("develop.auto").tap()
        let autoOff = waitFor { self.element("develop.auto").value as? String != autoBefore }
        app.buttons["editor.undo"].tap()
        let autoBack = waitFor { self.element("develop.auto").value as? String == autoBefore && self.label("develop.name") == before }
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

/// Focused 1.2 check on an already installed app, opened to a disposable test photo by devicectl.
final class EraserDeviceUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.lightlylabs.lightly")
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    func testDraftEraseUndoAndSave() throws {
        guard ProcessInfo.processInfo.environment["LIGHTLY_ERASER_DEVICE"] == "1" else { throw XCTSkip("Physical Eraser check only") }
        continueAfterFailure = false
        SystemAlertGuard.install(on: self)
        app.activate()
        XCTAssertTrue(element("tool.edit").waitForExistence(timeout: 120))
        element("tool.edit").tap()
        let tab = element("edit.sub.Eraser")
        for _ in 0..<5 where !tab.isHittable {
            let row = element("edit.sub.Adjust")
            let y = row.exists ? row.frame.midY : element("edit.sub.Crop").frame.midY
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.85, dy: y))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -app.frame.width * 0.65, dy: 0)))
        }
        XCTAssertTrue(tab.isHittable); tab.tap()
        let erase = element("edit.remove.erase"), clear = element("edit.remove.clear"), undo = element("edit.remove.undoStroke")
        XCTAssertTrue(erase.waitForExistence(timeout: 10)); XCTAssertFalse(erase.isEnabled)
        shot("eraser-empty")
        let photo = element("editor.photo")
        func stroke(_ y: Double) {
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: y)).press(forDuration: 0.1,
                thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: y)))
        }
        stroke(0.4); stroke(0.7)
        XCTAssertTrue(erase.isEnabled); XCTAssertFalse(element("processing.overlay").exists)
        shot("eraser-two-marks")
        undo.tap(); XCTAssertTrue(erase.isEnabled)
        clear.tap(); XCTAssertFalse(erase.isEnabled)
        stroke(0.4); stroke(0.7)
        erase.tap()
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline && (element("processing.overlay").exists || erase.isEnabled) { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertFalse(element("processing.overlay").exists)
        XCTAssertFalse(erase.isEnabled, "successful batch clears the marks")
        XCTAssertTrue(undo.isEnabled)
        shot("eraser-applied")
        undo.tap(); XCTAssertFalse(undo.isEnabled, "Undo restores the entire two-stroke batch")
        shot("eraser-undone")
        element("editor.undo").tap() // undo the removal-undo: replay the same stored patches
        element("editor.saveCopy").tap()
        XCTAssertTrue(element("saved.title").waitForExistence(timeout: 120), "the actual edited photo saves")
        shot("eraser-saved")
    }
}

/// Real opening/Auto/matte/depth/inpainting/export, with opt-in diagnostic dwell for inspection.
final class ProcessingDeviceUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.lightlylabs.lightly")
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func check(_ state: String) {
        let overlay = element("processing.overlay")
        let predicate = NSPredicate { _, _ in overlay.exists && (overlay.value as? String) == state }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 120), .completed, state)
        XCTAssertFalse(app.staticTexts["Cancel"].exists, "No visible loading Cancel label")
        shot("processing-\(state)")
        // Tap the toolbar where Close would be. The actual operation must remain active.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.075)).tap()
        XCTAssertTrue(overlay.exists, "Background controls blocked during \(state)")
    }
    func testSixLoadingStates() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LIGHTLY_PROCESSING_DEVICE"] == "1" else { throw XCTSkip("Opt-in physical processing review") }
        let theme = env["LIGHTLY_PROCESSING_THEME"] ?? "light"
        continueAfterFailure = false
        SystemAlertGuard.install(on: self)
        app.launchArguments = ["--keep-stored-session", "--session-store", "processing-review-\(theme)", "--keep-awake", "--open-photo", "processing-check.jpg", "--processing-review", "-lightly.preferences.v1.appearance", theme]
        app.launch()
        check("opening"); check("auto")
        XCTAssertTrue(element("tool.background").waitForExistence(timeout: 120))
        shot("ready-\(theme)")
        element("tool.background").tap()
        check("subject"); check("depth")
        XCTAssertTrue(element("tool.edit").waitForExistence(timeout: 120))
        shot("background-ready")
        element("tool.edit").tap()
        let tab = element("edit.sub.Eraser")
        for _ in 0..<5 where !tab.isHittable {
            let y = element("edit.sub.Crop").exists ? element("edit.sub.Crop").frame.midY : element("edit.sub.Adjust").frame.midY
            let p = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.85, dy: y))
            p.press(forDuration: 0.05, thenDragTo: p.withOffset(CGVector(dx: -app.frame.width * 0.65, dy: 0)))
        }
        XCTAssertTrue(tab.isHittable); tab.tap()
        let photo = element("editor.photo")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.40)).press(forDuration: 0.1,
            thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.46, dy: 0.40)))
        element("edit.remove.erase").tap()
        check("eraser")
        XCTAssertTrue(element("edit.remove.undoStroke").waitForExistence(timeout: 120))
        XCTAssertTrue(element("edit.remove.undoStroke").isEnabled)
        XCTAssertFalse(element("edit.remove.erase").isEnabled)
        shot("eraser-ready")
        element("editor.saveCopy").tap()
        check("saving")
        XCTAssertTrue(element("saved.title").waitForExistence(timeout: 120))
        shot("saved")
    }
}
