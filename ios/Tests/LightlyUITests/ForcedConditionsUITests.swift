import XCTest

/// A11 forced conditions (completion plan, 2026-10-07), end to end in the Simulator: Save copy on a full device and with
/// a failed write shows the approved alert and keeps the edit; the source photo deleted while it is being edited.
/// Results are also written to /tmp/lightly-a11y/forced-<device>.json.
final class ForcedConditionsUITests: XCTestCase {
    private let timeout: TimeInterval = 40
    /// A full-resolution Save copy in the Simulator takes well over 30 s for the 12 MP lake photo.
    private static let saveTimeout: TimeInterval = 120

    private func openEditor(photo: String, extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-preferences", "--open-photo", photo, "--scenario", "dev-preset"] + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["develop.ruler"].waitForExistence(timeout: timeout), "editor not ready")
        return app
    }

    private var lakePath: String { "\(EditorCaptureUITests.repositoryRoot)/\(EditorCaptureUITests.photoFiles["lake"]!).jpg" }

    func testStorageFullShowsTheApprovedAlertAndKeepsTheEdit() {
        let app = openEditor(photo: lakePath, extra: ["--failing-library-writer", "storage"])
        app.buttons["editor.saveCopy"].tap()
        let alert = app.alerts["Not enough storage"]
        XCTAssertTrue(alert.waitForExistence(timeout: Self.saveTimeout), "no storage-full alert")
        XCTAssertTrue(alert.staticTexts["Free up some space and try again. Your edits are kept."].exists)
        XCTAssertTrue(alert.buttons["Try again"].exists && alert.buttons["OK"].exists)
        alert.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["editor.saveCopy"].waitForExistence(timeout: 5), "editor gone after OK")
        XCTAssertTrue(app.descendants(matching: .any)["develop.ruler"].exists, "the edit is not kept")
        record("storageFull", "alert shown, OK returns to the editor with the edit")
    }

    func testFailedWriteShowsTheApprovedAlertAndTryAgainRetries() {
        let app = openEditor(photo: lakePath, extra: ["--failing-library-writer", "other"])
        app.buttons["editor.saveCopy"].tap()
        let alert = app.alerts["Couldn’t save the copy"]
        XCTAssertTrue(alert.waitForExistence(timeout: Self.saveTimeout), "no save-failed alert")
        alert.buttons["Try again"].tap()
        XCTAssertTrue(app.alerts["Couldn’t save the copy"].waitForExistence(timeout: Self.saveTimeout), "Try again did not save again")
        app.alerts["Couldn’t save the copy"].buttons["Keep editing"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["develop.ruler"].waitForExistence(timeout: 5), "the edit is not kept")
        record("saveFailed", "alert shown; Try again saves again (fails again here); Keep editing returns with the edit")
    }

    /// The photo file disappears while it is open (deleted, or access lost). The session keeps the original's bytes,
    /// so Save copy is expected to complete from them; any other outcome is recorded as it happened.
    func testSourceDeletedWhileEditingThenSaveCopy() throws {
        let copy = "/tmp/lightly-forced-source.jpg"
        try? FileManager.default.removeItem(atPath: copy)
        try FileManager.default.copyItem(atPath: lakePath, toPath: copy)
        let app = openEditor(photo: copy, extra: ["--fake-library-writer"])
        try FileManager.default.removeItem(atPath: copy)
        app.buttons["editor.saveCopy"].tap()
        let saved = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Saved'")).firstMatch
        let anyAlert = app.alerts.firstMatch
        let outcome: String
        if saved.waitForExistence(timeout: Self.saveTimeout) { outcome = "saved from the session's copy of the original" }
        else if anyAlert.exists { outcome = "alert: \(anyAlert.label)" }
        else { outcome = "neither saved nor an alert within the save timeout" }
        record("sourceDeleted", outcome)
        XCTAssertFalse(outcome.hasPrefix("neither"), outcome)
    }

    private func record(_ key: String, _ value: String) {
        let url = URL(fileURLWithPath: "/tmp/lightly-a11y/forced-\(UIDevice.current.name.replacingOccurrences(of: " ", with: "_")).json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var all = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: String] ?? [:]
        all[key] = value
        try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}
