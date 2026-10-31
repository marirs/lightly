import XCTest

/// Effects › Ink on a physical iPhone (owner-approved design docs/ui/proposals/ink-2026-10-31): drives the Lightly build
/// already installed on the phone through every Ink control, the photo gestures, Undo/Redo, Reset and Save copy, and keeps
/// a screenshot of each state. Not part of any regular run: skipped unless LIGHTLY_INK_DEVICE_CHECK is set, and its
/// xctestrun must not install the host app (the installed review build stays on the phone).
final class InkDeviceUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.lightlylabs.lightly")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private static let drySweep = "effects.ink.ink-cbfae4259a79"
    private static let splatter = "effects.ink.ink-3de0ea10dbb4"

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["LIGHTLY_INK_DEVICE_CHECK"] != nil else {
            throw XCTSkip("Ink device check: set LIGHTLY_INK_DEVICE_CHECK to run")
        }
        continueAfterFailure = true
    }

    func testInkOnTheDevice() throws {
        app.terminate()
        app.launch()
        openFirstPhoto()
        XCTAssertTrue(app.buttons["tool.develop"].waitForExistence(timeout: 30), "editor open")
        pause(3)

        // The tab: fifth in Effects, None chosen, the stroke controls and the note.
        tap(app.buttons["tool.effects"])
        tapInScrollingRow("effects.sub.Ink")
        pause(1)
        XCTAssertTrue(element("effects.ink.gallery").waitForExistence(timeout: 5), "Ink gallery")
        if !element("effects.ink.none").isSelected {   // a restored edit may already have an ink
            tap(element("effects.ink.none")); pause(3)
        }
        XCTAssertTrue(element("effects.ink.none").isSelected, "None chosen")
        XCTAssertTrue(element("slider.size").exists && element("slider.rotation").exists, "Size and Rotation")
        XCTAssertTrue(element("effects.ink.paper.strip").exists, "Paper colour strip")
        XCTAssertTrue(app.staticTexts["Drag on the photo to move the ink. Pinch to resize or turn it."].exists, "the note")
        shot("01-none")

        // Choosing an ink: one step, the photo through the stroke on paper.
        let undo = app.buttons["editor.undo"]
        tap(element(Self.drySweep))
        pause(4)
        XCTAssertTrue(element(Self.drySweep).isSelected, "Dry Sweep chosen")
        XCTAssertTrue(undo.isEnabled, "choosing is an undo step")
        shot("02-dry-sweep")

        // Drag on the photo moves it; pinch scales; rotate turns.
        let photo = element("editor.photo")
        XCTAssertTrue(photo.exists, "photo")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.42)))
        pause(3)
        shot("03-dragged")
        photo.pinch(withScale: 1.35, velocity: 1)
        pause(3)
        record("size after pinch", element("slider.size").value)
        shot("04-pinched")
        photo.rotate(0.6, withVelocity: 1)
        pause(3)
        record("rotation after turn", element("slider.rotation").value)
        shot("05-turned")

        // Sliders and the paper colour.
        setSlider(element("slider.size"), to: 0.2)
        pause(3)
        record("size slider", element("slider.size").value)
        shot("06-size-small")
        let strip = element("effects.ink.paper.strip")
        // Scroll the panel, never the photo (a swipe over the photo moves the ink).
        if !strip.isHittable { scrollPanel(up: true) }
        state("after size")
        strip.coordinate(withNormalizedOffset: CGVector(dx: 6.5 / 24, dy: 0.5)).tap()   // Charcoal, the 7th colour
        pause(3)
        state("after paper")
        shot("07-charcoal-paper")

        // Undo and Redo.
        tap(undo); pause(3)
        state("after undo")
        shot("08-undo-paper")
        tap(app.buttons["editor.redo"]); pause(3)
        state("after redo")
        shot("09-redo-paper")

        // An overlay ink: Intensity instead of Size and Paper, and its note.
        if !element("effects.ink.gallery").isHittable { scrollPanel(up: false) }
        tapInScrollingRow(Self.splatter)
        pause(4)
        XCTAssertTrue(element(Self.splatter).isSelected, "Splatter chosen")
        XCTAssertTrue(element("slider.intensity").waitForExistence(timeout: 3), "Intensity for an overlay ink")
        XCTAssertFalse(element("slider.size").exists, "no Size for an overlay ink")
        XCTAssertTrue(app.staticTexts["The ink is printed over the whole photo."].exists, "overlay note")
        shot("10-splatter")
        setSlider(element("slider.intensity"), to: 1)
        pause(3)
        shot("11-splatter-full")

        // Reset on the tab removes the ink.
        tap(element("reset.effects"))
        pause(1)
        shot("12a-reset-choices")
        tap(element("reset.effects.ink"))
        pause(3)
        XCTAssertFalse(element(Self.splatter).isSelected, "Reset: no ink")
        XCTAssertTrue(element("slider.size").exists, "Reset: the stroke controls again")
        shot("12-reset")

        // Save copy with Dry Sweep, and the saved screen.
        tapInScrollingRow(Self.drySweep)
        pause(4)
        shot("13-before-save")
        tap(app.buttons["editor.saveCopy"])
        allowPhotosAddIfAsked()
        XCTAssertTrue(element("saved.title").waitForExistence(timeout: 60), "saved")
        pause(2)
        shot("14-saved")
        tap(app.buttons["saved.keepEditing"])
        pause(2)

        // The saved copy is the newest photo: open it from the picker to compare with the preview.
        if element("editor.chooseAnother").exists { tap(element("editor.chooseAnother")) }
        else if app.buttons["editor.close"].exists { tap(app.buttons["editor.close"]); tap(app.buttons["welcome.choosePhoto"]) }
        let grid = app.scrollViews["photosView_content_scroll_view"]
        if grid.waitForExistence(timeout: 20) {
            pause(2)
            shot("15-picker-newest")
            grid.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.12)).tap()
            _ = app.buttons["tool.develop"].waitForExistence(timeout: 30)
            pause(4)
            shot("16-saved-copy-opened")
        }
    }

    // MARK: - Helpers

    private func openFirstPhoto() {
        if app.buttons["tool.develop"].waitForExistence(timeout: 5) { return }   // a restored edit
        guard app.buttons["welcome.choosePhoto"].waitForExistence(timeout: 20) else { return }
        app.buttons["welcome.choosePhoto"].tap()
        let grid = app.scrollViews["photosView_content_scroll_view"]
        guard grid.waitForExistence(timeout: 20) else { return }
        pause(2)
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.12)).tap()
    }

    private func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }

    private func tap(_ e: XCUIElement) {
        XCTAssertTrue(e.waitForExistence(timeout: 10), "\(e) missing")
        if e.exists { e.tap() }
    }

    private func tapInScrollingRow(_ identifier: String) {
        let item = element(identifier)
        // The galleries are lazy: a tile past the visible columns does not exist until the row is scrolled to it.
        let gallery = element("effects.ink.gallery")
        if identifier.hasPrefix("effects.ink."), gallery.exists {
            for _ in 0..<6 where !item.exists {   // back to the start first: the tile may lie behind
                let f = gallery.frame
                let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.minX + 30, dy: f.midY))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: f.width * 0.6, dy: 0)))
                pause(1)
            }
            for _ in 0..<10 where !item.exists {
                let f = gallery.frame
                let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.maxX - 30, dy: f.midY))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -f.width * 0.6, dy: 0)))
                pause(1)
            }
        }
        guard item.waitForExistence(timeout: 10) else { XCTFail("\(identifier) missing"); return }
        let width = app.windows.firstMatch.frame.width
        func fullyOnScreen() -> Bool { let f = item.frame; return !f.isEmpty && f.minX >= 0 && f.maxX <= width }
        for _ in 0..<8 where !fullyOnScreen() {
            let back = item.frame.midX < width / 2
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: back ? width * 0.3 : width * 0.75, dy: item.frame.midY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: back ? 220 : -220, dy: 0)))
            pause(1)
        }
        item.tap()
    }

    /// L2Slider: 92 pt label, 12 pt gap, the track, 12 pt gap, 34 pt value.
    private func setSlider(_ slider: XCUIElement, to fraction: CGFloat) {
        guard slider.waitForExistence(timeout: 5) else { XCTFail("\(slider) missing"); return }
        let frame = slider.frame
        let trackStart: CGFloat = 92 + 12, trackEnd = frame.width - 12 - 34
        slider.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: trackStart + (trackEnd - trackStart) * fraction, dy: frame.height / 2)).tap()
    }

    private func allowPhotosAddIfAsked() {
        for label in ["Allow", "Allow Access", "OK", "Add Photos Only"] {
            let button = springboard.alerts.buttons[label].firstMatch
            if button.waitForExistence(timeout: label == "Allow" ? 5 : 1) { button.tap(); return }
        }
    }

    /// Drags inside the tool panel (below the photo) to scroll its contents.
    private func scrollPanel(up: Bool) {
        let window = app.windows.firstMatch.frame
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.width * 0.5, dy: window.height * (up ? 0.82 : 0.6)))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: up ? -180 : 180)))
        pause(1)
    }

    private func state(_ label: String) {
        record(label, "size \(element("slider.size").value ?? "-"), rotation \(element("slider.rotation").value ?? "-"), paper \(element("effects.ink.paper.strip").value ?? "-"), undo \(app.buttons["editor.undo"].isEnabled), redo \(app.buttons["editor.redo"].isEnabled)")
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
