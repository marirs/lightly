import XCTest

/// Portrait › Sunglasses and Border › Polaroid on a physical iPhone: drives the Lightly build already installed on the
/// phone on a photo with a face, keeps a screenshot of each state and the values, then saves a copy and reopens it so
/// preview and saved output can be compared. Not part of any regular run: skipped unless LIGHTLY_PORTRAIT_DEVICE_CHECK
/// is set, and its xctestrun must not install the host app. LIGHTLY_DEVICE_APPEARANCE=dark|light runs it under that
/// in-app Appearance (More › Appearance, never the phone's Settings); LIGHTLY_DEVICE_RESTORE_APPEARANCE is put back after.
final class PortraitBorderDeviceUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.lightlylabs.lightly")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    /// Set once this run changes the photo; until then any unsaved edits on screen predate the test.
    private var editedInThisRun = false

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["LIGHTLY_PORTRAIT_DEVICE_CHECK"] != nil else {
            throw XCTSkip("Portrait/Border device check: set LIGHTLY_PORTRAIT_DEVICE_CHECK to run")
        }
        continueAfterFailure = true
        SystemAlertGuard.install(on: self)
    }

    func testSunglassesAndPolaroidOnTheDevice() throws {
        app.terminate()
        app.launch()
        let environment = ProcessInfo.processInfo.environment
        guard openPhotoWithAFace() else {
            XCTFail("No photo with a detected face among the newest picker tiles")
            return
        }
        shot("01-face-photo")
        let chosenPrevious = environment["LIGHTLY_DEVICE_APPEARANCE"].flatMap(chooseAppearance)
        let previousAppearance = environment["LIGHTLY_DEVICE_RESTORE_APPEARANCE"] ?? chosenPrevious
        defer { if let previousAppearance { _ = chooseAppearance(previousAppearance) } }

        checkSunglasses()
        checkPolaroid()
        saveAndReopen()
    }

    // MARK: - Steps

    private func checkSunglasses() {
        pause(2)   // Portrait is already open (openPhotoWithAFace)
        revealTab(element("portrait.tab.Sunglasses"), firstTab: element("portrait.tab.Skin"))
        pause(2)
        XCTAssertTrue(element("sunglasses.pair.none").waitForExistence(timeout: 10), "Sunglasses pairs shown")
        shot("02-sunglasses-tab")

        let pairs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sunglasses.pair.' AND identifier != 'sunglasses.pair.none'"))
        record("pairs", (0..<pairs.count).map { pairs.element(boundBy: $0).identifier }.joined(separator: ","))
        // The pairs are greyed out while the face fit is prepared, and a tap then does nothing: wait until enabled.
        let firstPair = pairs.element(boundBy: 0)
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: firstPair)
        wait(for: [enabled], timeout: 45)
        pause(1)
        shot("02b-pairs-ready")
        let shown = (0..<pairs.count).map { pairs.element(boundBy: $0) }.filter(\.isHittable)
        for (index, pair) in shown.prefix(2).enumerated() {
            let id = pair.identifier
            editedInThisRun = true
            pair.tap()
            pause(8)   // the paint-out of existing glasses and the fit run on the device
            record("pair \(index + 1)", "\(id) selected \(pair.isSelected)")
            shot("0\(3 + index)-\(id.replacingOccurrences(of: "sunglasses.pair.", with: ""))")
        }

        let brown = element("sunglasses.lens.brown")
        if !brown.isHittable { scrollPanel() }
        revealAndTap(brown)
        pause(4)
        record("lens brown selected", brown.isSelected)
        shot("05-lens-brown")
        let darkness = element("slider.darkness")
        if !darkness.isHittable { scrollPanel() }
        setSlider(darkness, to: 0.3)
        pause(4)
        record("darkness", darkness.value)
        shot("06-darkness")

        tap(app.buttons["editor.undo"]); pause(4)
        record("darkness after undo", element("slider.darkness").value)
        shot("07-undo")
        tap(app.buttons["editor.redo"]); pause(4)
        record("darkness after redo", element("slider.darkness").value)
        shot("08-redo")
    }

    private func checkPolaroid() {
        revealAndTap(app.buttons["tool.border"])
        pause(2)
        revealTab(element("border.type.Polaroid"), firstTab: element("border.type.None"))   // the type row is lazy too
        pause(4)
        record("polaroid selected", element("border.type.Polaroid").isSelected)
        // Polish #1: Auto and Reset all must not cover the Polaroid's bottom margin; the screenshot shows the print,
        // these frames say where the two buttons sit.
        record("frames", "photo \(element("editor.photo").frame), auto \(element("develop.auto").frame), resetAll \(element("editor.resetAll").frame)")
        shot("09-polaroid")
    }

    private func saveAndReopen() {
        shot("10-before-save")
        tap(app.buttons["editor.saveCopy"])
        allowPhotosAddIfAsked()
        XCTAssertTrue(element("saved.title").waitForExistence(timeout: 60), "saved")
        pause(2)
        shot("11-saved")
        tap(app.buttons["saved.keepEditing"])
        pause(2)
        guard backToPicker() else { XCTFail("picker not reopened"); return }
        let tiles = photoTiles()
        guard let newest = tiles.first else { XCTFail("no photo tiles"); return }
        newest.tap()
        _ = app.buttons["tool.develop"].waitForExistence(timeout: 30)
        pause(4)
        shot("12-saved-copy-opened")
    }

    // MARK: - Photo choice

    /// Opens the newest photos one by one until the editor offers Portrait (a face was detected). Earlier device runs
    /// leave saved copies without faces at the top of the library, so the first tile is not enough.
    private func openPhotoWithAFace() -> Bool {
        for index in 0..<12 {
            guard backToPicker() else { return false }
            let tiles = photoTiles()
            guard index < tiles.count else { return false }
            tiles[index].tap()
            guard app.buttons["tool.develop"].waitForExistence(timeout: 30) else { continue }
            pause(4)
            // Portrait can be offered for a person whose face is too small or covered ("No face can be edited in
            // this photo", e.g. an earlier run's Ink copy): only a photo whose Portrait panel shows its tabs counts.
            if app.buttons["tool.portrait"].exists {
                revealAndTap(app.buttons["tool.portrait"])
                if element("portrait.tab.Skin").waitForExistence(timeout: 8) {
                    record("photo tile", index)
                    return true
                }
            }
        }
        return false
    }

    private func backToPicker() -> Bool {
        let grid = app.scrollViews["photosView_content_scroll_view"]
        if grid.exists { return true }
        if element("editor.chooseAnother").exists { tap(element("editor.chooseAnother")) }
        else if app.buttons["editor.close"].exists {
            tap(app.buttons["editor.close"])
            pause(1)
            // Closing with unsaved edits asks first (Lightly's own "Leave without saving?", L2Alert). Only edits this run
            // made may be discarded: edits restored from before the test can be the owner's real work, so keep them and
            // stop (Codex review, 2026-11-06).
            if element("leave.discard").waitForExistence(timeout: 3) {
                guard editedInThisRun else {
                    tap(element("leave.keep"))
                    XCTFail("Unsaved edits from before this test are open; left untouched. Save or discard them on the phone, then re-run.")
                    return false
                }
                tap(element("leave.discard"))
                pause(1)
            }
        }
        if app.buttons["welcome.choosePhoto"].waitForExistence(timeout: 10) { app.buttons["welcome.choosePhoto"].tap() }
        guard grid.waitForExistence(timeout: 20) else { return false }
        pause(2)
        return true
    }

    /// Photo tiles, newest first (top row, then left to right). Skips the picker's first-use header and its "Private
    /// Access to Photos" banner, which are not photo tiles.
    private func photoTiles() -> [XCUIElement] {
        let grid = app.scrollViews["photosView_content_scroll_view"]
        let query = grid.images.matching(NSPredicate(format: "identifier == 'PXGGridLayout-Info'"))
        let tiles = (0..<min(query.count, 24)).map { query.element(boundBy: $0) }.filter(\.isHittable)
        return tiles.sorted { a, b in
            abs(a.frame.minY - b.frame.minY) > 2 ? a.frame.minY < b.frame.minY : a.frame.minX < b.frame.minX
        }
    }

    // MARK: - Helpers

    private func chooseAppearance(_ value: String) -> String? {
        guard app.buttons["editor.more"].waitForExistence(timeout: 10) else { XCTFail("More missing"); return nil }
        app.buttons["editor.more"].tap()
        pause(1)
        let previous = ["system", "light", "dark"].first { element("appearance.\($0)").isSelected }
        tap(element("appearance.\(value)"))
        pause(1)
        XCTAssertTrue(element("appearance.\(value)").isSelected, "Appearance \(value) chosen")
        shot("00-appearance-\(value)")
        tap(element("page.close"))
        pause(2)
        return previous
    }

    private func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }

    private func tap(_ e: XCUIElement) {
        XCTAssertTrue(e.waitForExistence(timeout: 10), "\(e) missing")
        if e.exists { e.tap() }
    }

    /// Scrolls the element's own row (the dock, the tabs, a chip row) leftwards until it can be tapped.
    private func revealAndTap(_ e: XCUIElement) {
        guard e.waitForExistence(timeout: 10) else { XCTFail("\(e) missing"); return }
        let window = app.windows.firstMatch.frame
        // An element scrolled past the edge of its row can still report hittable; require it fully on screen.
        // Frame first: asking a fully off-screen element whether it is hittable fails the test (iPhone SE 3 dock).
        func onScreen() -> Bool { e.frame.minX >= 0 && e.frame.maxX <= window.width && e.isHittable }
        for _ in 0..<6 where !onScreen() {
            let y = e.frame.midY
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.width * 0.8, dy: y))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -window.width * 0.5, dy: 0)))
            pause(1)
        }
        e.tap()
    }

    /// The tab row is lazy: a tab past the visible ones does not exist until the row is scrolled, so drag along the
    /// row of a tab that does exist until the wanted one appears, then tap it.
    private func revealTab(_ tab: XCUIElement, firstTab: XCUIElement) {
        guard firstTab.waitForExistence(timeout: 10) else { XCTFail("tab row missing"); return }
        let window = app.windows.firstMatch.frame
        let y = firstTab.frame.midY
        for _ in 0..<6 where !(tab.exists && tab.isHittable) {
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.width * 0.8, dy: y))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -window.width * 0.5, dy: 0)))
            pause(1)
        }
        tap(tab)
    }

    /// Scrolls the tool panel up, starting on the left margin of the panel so no slider is dragged.
    private func scrollPanel() {
        let window = app.windows.firstMatch.frame
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 12, dy: window.height * 0.8))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -160)))
        pause(1)
    }

    private func setSlider(_ slider: XCUIElement, to fraction: CGFloat) {
        guard slider.waitForExistence(timeout: 5) else { XCTFail("\(slider) missing"); return }
        let frame = slider.frame
        let trackStart: CGFloat = 92 + 12, trackEnd = frame.width - 12 - 34
        slider.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: trackStart + (trackEnd - trackStart) * fraction, dy: frame.height / 2)).tap()
    }

    /// Lightly's own permission to add the saved copy to Photos (the app under test), never an account or system setting.
    private func allowPhotosAddIfAsked() {
        for label in ["Allow", "Allow Access", "OK", "Add Photos Only"] {
            let button = springboard.alerts.buttons[label].firstMatch
            if button.waitForExistence(timeout: label == "Allow" ? 5 : 1) { button.tap(); return }
        }
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func record(_ what: String, _ value: Any?) {
        let attachment = XCTAttachment(string: "\(what): \(value ?? "nil")")
        attachment.name = what
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}
