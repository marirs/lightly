import XCTest

/// Captures every slice-1 screen of the running app for side-by-side comparison with the
/// approved prototype (`docs/ui/tools/shot.js`). It asserts nothing about pixels. It only
/// navigates and saves screenshots.
///
/// It runs only when `LIGHTLY_CAPTURE_DIR` is set (`TEST_RUNNER_LIGHTLY_CAPTURE_DIR=<dir>` on the
/// xcodebuild command line). Otherwise every test skips, so the normal UI suite is unaffected.
/// `LIGHTLY_CAPTURE_ORIENTATION=landscape` rotates an iPad first. Theme and text size come from
/// the simulator (`simctl ui appearance`, `simctl ui content_size`). File names are the prototype's
/// screen ids.
final class DesignCaptureUITests: XCTestCase {

    private var app: XCUIApplication!
    private let timeout: TimeInterval = 15
    private var directory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let path = ProcessInfo.processInfo.environment["LIGHTLY_CAPTURE_DIR"] else {
            throw XCTSkip("Design captures run only with LIGHTLY_CAPTURE_DIR set.")
        }
        directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["LIGHTLY_CAPTURE_ORIENTATION"] == "landscape" {
            XCUIDevice.shared.orientation = .landscapeLeft
        } else {
            XCUIDevice.shared.orientation = .portrait
        }
        app = XCUIApplication()
    }

    private func launch(_ arguments: [String]) {
        app.terminate()
        app.launchArguments = ["--reset-preferences", "--seed-favourites"] + arguments
        app.launch()
    }

    private func save(_ name: String) {
        // Let presentation animations finish so the capture shows the settled screen.
        Thread.sleep(forTimeInterval: 0.9)
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func tap(_ identifier: String) {
        let target = app.buttons[identifier].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(identifier) missing")
        target.tap()
    }

    func testCaptureWelcomeAndMore() {
        launch([])
        XCTAssertTrue(app.buttons["welcome.choosePhoto"].waitForExistence(timeout: timeout))
        save("welcome")

        tap("welcome.more")
        save("welcome-more")
        tap("more.row.preferences"); save("preferences")
        tap("preferences.favourites"); save("pref-favourites"); tap("page.back")
        tap("preferences.signature"); save("pref-signature"); tap("page.back")
        tap("preferences.preferredBorder"); save("pref-border"); tap("page.back")
        tap("page.back")
        tap("more.row.legal"); save("legal")
        tap("more.row.privacyPolicy"); save("privacy"); tap("page.back")
        tap("more.row.termsOfUse"); save("terms"); tap("page.back")
        tap("page.back")
        tap("more.row.about"); save("about")
        tap("more.row.support"); save("support")
        tap("page.back"); tap("page.back"); tap("page.close")

        tap("welcome.privacyPolicy"); save("welcome-privacy")
        tap("page.back")
    }

    func testCapturePickerAndCancel() {
        launch([])
        tap("welcome.choosePhoto")
        _ = app.scrollViews["photosView_content_scroll_view"].waitForExistence(timeout: timeout)
        save("picker")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 3) { cancel.tap() } else { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(app.buttons["welcome.choosePhoto"].waitForExistence(timeout: timeout))
        save("picker-cancelled")
    }

    func testCaptureLoadFailed() {
        launch(["--open-unreadable-photo"])
        XCTAssertTrue(app.buttons["loadFailed.chooseAnother"].waitForExistence(timeout: timeout))
        save("load-failed")
    }

    /// Run after `simctl privacy reset camera`: the system prompt, then Don't Allow, then the
    /// denied screen.
    func testCaptureCameraPermissionAndDenied() {
        launch([])
        tap("welcome.camera")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllow = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Don'")).firstMatch
        if dontAllow.waitForExistence(timeout: 8) {
            save("camera-permission")
            dontAllow.tap()
        }
        XCTAssertTrue(app.buttons["cameraOff.openSettings"].waitForExistence(timeout: timeout))
        save("camera-denied")
    }

    /// Needs at least one photo in the simulator's library.
    func testCaptureEditorMore() {
        launch([])
        tap("welcome.choosePhoto")
        let grid = app.scrollViews["photosView_content_scroll_view"]
        guard grid.waitForExistence(timeout: timeout) else { return XCTFail("Picker did not present") }
        let photo = app.descendants(matching: .any)["editor.photo"]
        for offset in [CGVector(dx: 0.17, dy: 0.12), CGVector(dx: 0.43, dy: 0.2)] where !photo.exists {
            if grid.exists { grid.coordinate(withNormalizedOffset: offset).tap() }
            _ = photo.waitForExistence(timeout: 8)
        }
        tap("editor.more")
        save("more")
    }
}
