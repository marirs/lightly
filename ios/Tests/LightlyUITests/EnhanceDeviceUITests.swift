import XCTest

/// Device acceptance of Edit › Enhance (owner-approved design 2026-11-18, mockup `ed-enhance*`) on the review iPhones,
/// with the real engine. The device script copies a photo into Lightly's Documents and launches the app with
/// `--open-photo <file> --scenario ed-enhance`; launching through XCTest on the phones fails (DeviceDragUITests), so the
/// test attaches to the running app. Screenshots are attachments in the result bundle; results print as "ENHANCECHECK".
///
/// `testEnhanceFlow`: ready (with the large-photo sentence: the script's photo is over 2000 px), Cancel changes
/// nothing, a real run with the progress card, the enhanced note and toast, Undo/Redo without a new run.
/// `testEnhanceRestored`: the script ends the app and relaunches it with `--restore-stored-session` (a terminate looks
/// like a force-quit, which discards the edit by design); the restored edit is still enhanced, and Save copy works from
/// it. Saving last matters: Save copy with no later edits clears the stored session by design.
final class EnhanceDeviceUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.lightlylabs.lightly")

    override func setUpWithError() throws {
        continueAfterFailure = true
        SystemAlertGuard.install(on: self)
        guard ProcessInfo.processInfo.environment["LIGHTLY_ENHANCE_DEVICE"] == "1" else { throw XCTSkip("set LIGHTLY_ENHANCE_DEVICE=1 (device run only)") }
        app.activate()
    }

    private func element(_ identifier: String) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }
    private func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.2) }
        return condition()
    }
    private func report(_ line: String) { print("ENHANCECHECK \(line)") }
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testEnhanceFlow() {
        let run = element("edit.enhance.run")
        XCTAssertTrue(run.waitForExistence(timeout: 120), "Edit › Enhance did not open")
        Thread.sleep(forTimeInterval: 1.5)
        report("ready note=\(element("edit.enhance.note").label)")
        shot("ed-enhance-large")

        // Cancel: from the progress card on the photo; nothing changes.
        run.tap()
        let progress = element("edit.enhance.progress")
        let showedProgress = progress.waitForExistence(timeout: 10)
        report("enhancing progress=\(showedProgress) panelCancel=\(element("edit.enhance.cancel").exists)")
        shot("ed-enhancing")
        element("edit.enhance.progress.cancel").tap()
        let toast = element("editor.toast")
        let cancelled = waitFor(10) { toast.exists && toast.label.contains("Cancelled") }
        report("cancel toast=\(toast.exists ? toast.label : "none") runBack=\(run.waitForExistence(timeout: 10))")
        XCTAssertTrue(showedProgress && cancelled, "Cancel from the progress card")
        Thread.sleep(forTimeInterval: 3)

        // A real run to the end.
        let started = Date()
        run.tap()
        XCTAssertTrue(progress.waitForExistence(timeout: 10), "progress card")
        Thread.sleep(forTimeInterval: 4)
        shot("ed-enhancing-real")
        let finished = waitFor(300) { !progress.exists && !self.element("edit.enhance.cancel").exists }
        let seconds = Int(Date().timeIntervalSince(started))
        let note = element("edit.enhance.note")
        let enhanced = waitFor(10) { note.exists && note.label.hasPrefix("Twice the size") }
        report("run finished=\(finished) after \(seconds) s toast=\(toast.exists ? toast.label : "none") note=\(note.exists ? note.label : "none") failed=\(element("edit.enhance.retry").exists)")
        Thread.sleep(forTimeInterval: 1)
        shot("ed-enhanced")
        XCTAssertTrue(finished && enhanced, "the run finished with the enhanced note")

        // Undo/Redo bring the same result back (no progress card: no new run).
        app.buttons["editor.undo"].tap()
        let undone = run.waitForExistence(timeout: 10)
        app.buttons["editor.redo"].tap()
        let redone = waitFor(10) { note.exists && note.label.hasPrefix("Twice the size") }
        report("undo=\(undone) redo=\(redone) progressAfterRedo=\(progress.exists)")
        XCTAssertTrue(undone && redone && !progress.exists, "Undo and Redo without a new run")
        // Time for the session store to write the edit before the script ends the app.
        Thread.sleep(forTimeInterval: 5)
    }

    func testEnhanceRestored() {
        // The relaunched app restores the stored session into the editor; open Edit › Enhance by its tabs.
        let edit = element("tool.edit")
        if edit.waitForExistence(timeout: 120) { edit.tap() }
        let sub = element("edit.sub.Enhance")
        if sub.waitForExistence(timeout: 10) { sub.tap() }
        let note = element("edit.enhance.note")
        let restored = waitFor(30) { note.exists && note.label.hasPrefix("Twice the size") }
        report("restored enhanced=\(restored) note=\(note.exists ? note.label : "none")")
        shot("restored")
        XCTAssertTrue(restored, "the enhanced edit survives a restart")

        // Save copy from the restored edit (the stored result, not a new run).
        let saveStarted = Date()
        app.buttons["editor.saveCopy"].tap()
        let saved = element("saved.title").waitForExistence(timeout: 180)
        report("save saved=\(saved) after \(Int(Date().timeIntervalSince(saveStarted))) s")
        shot("saved")
        XCTAssertTrue(saved, "Save copy of the restored enhanced photo")
    }
}
