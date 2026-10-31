import Photos
import XCTest

/// The App Review screen recording (Guideline 2.1 Information Needed, 2026-10-31): drives the Lightly build already
/// installed on a physical iPhone (the submitted TestFlight build) through the typical flow at a human pace, while the
/// Mac records the phone's screen. Not part of any regular run: it is skipped unless LIGHTLY_APP_REVIEW_WALKTHROUGH is
/// set, and its xctestrun must not install the host app (the submitted build stays on the phone).
///
/// Every step is optional: a control missing from the installed build (or a photo without a face, which hides
/// Portrait) is skipped rather than failing the recording.
final class AppReviewWalkthroughUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.lightlylabs.lightly")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["LIGHTLY_APP_REVIEW_WALKTHROUGH"] != nil else {
            throw XCTSkip("App Review walkthrough: set LIGHTLY_APP_REVIEW_WALKTHROUGH to run")
        }
        continueAfterFailure = true
    }

    func testAppReviewWalkthrough() {
        // The recording must begin with launching the app: start from the Home Screen, start the phone's own Screen
        // Recording (Control Centre), then launch.
        app.terminate()
        XCUIDevice.shared.press(.home)
        pause(2)
        // Records on the phone when Control Centre has Screen Recording; otherwise the Mac records the screen
        // (QuickTime, over the cable) and the walkthrough just runs.
        let recordsOnPhone = ProcessInfo.processInfo.environment["LIGHTLY_WALKTHROUGH_PHONE_RECORDING"] != nil && toggleScreenRecording()
        pause(recordsOnPhone ? 5 : 3)   // the 3-second countdown, then a moment on the Home Screen
        defer { if recordsOnPhone { pause(2); _ = toggleScreenRecording() } }
        app.launch()
        pause(3)

        guard tapIfPresent(app.buttons["welcome.choosePhoto"], wait: 20) else { return }
        pause(2)
        chooseFirstPhoto()
        guard app.buttons["tool.develop"].waitForExistence(timeout: 30) else { return }
        pause(4)

        // Develop: Auto, then two presets from the gallery.
        tapIfPresent(element("develop.auto")); pause(3)
        let presets = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'develop.thumbnail.' AND identifier != 'develop.thumbnail.original'"))
        if presets.count > 1 { presets.element(boundBy: 1).tap(); pause(3) }
        if presets.count > 4 { presets.element(boundBy: 4).tap(); pause(3) }

        visit("tool.background", for: 4)
        visit("tool.portrait", for: 4)
        if visit("tool.edit", for: 3) {
            tapIfPresent(app.buttons["edit.sub.adjust"]); pause(3)
            tapIfPresent(app.buttons["edit.sub.crop"]); pause(2)
        }
        visit("tool.effects", for: 3)
        if visit("tool.text", for: 2), tapIfPresent(app.buttons["text.add"]) {
            pause(1.5)
            let field = app.descendants(matching: .any)["text.sheet.field"].firstMatch
            if field.waitForExistence(timeout: 5) {
                field.typeText("Summer evening")
                pause(1.5)
                tapIfPresent(app.buttons["text.sheet.done"]); pause(3)
            }
        }
        visit("tool.watermark", for: 3)
        visit("tool.border", for: 3)
        visit("tool.develop", for: 2)

        // Save a copy: iOS asks for add-only Photos access the first time.
        guard tapIfPresent(app.buttons["editor.saveCopy"]) else { return }
        allowPhotosAddIfAsked()
        if app.descendants(matching: .any)["saved.title"].waitForExistence(timeout: 30) {
            pause(4)
            tapIfPresent(app.buttons["saved.keepEditing"])
        }
        pause(3)
    }

    // MARK: - Steps

    /// Opens Control Centre (swipe down from the top-right corner), taps Screen Recording (starts it, or stops it when
    /// recording), and closes Control Centre. False when the button is not there (it must be in Control Centre).
    private func toggleScreenRecording() -> Bool {
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.005))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.6)))
        pause(1.5)
        let button = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Screen Recording' OR identifier CONTAINS[c] 'screen-recording'")).firstMatch
        guard button.waitForExistence(timeout: 5) else {
            print("walkthrough control centre buttons: \(springboard.buttons.allElementsBoundByIndex.prefix(60).map(\.label))")
            XCUIDevice.shared.press(.home)
            return false
        }
        button.tap()
        pause(1)
        XCUIDevice.shared.press(.home)   // closes Control Centre
        return true
    }

    /// Puts a rights-cleared portrait (docs/ui/assets/photos/portrait_medium_02.jpg, Unsplash Licence, SOURCES.csv)
    /// into the phone's Photos so it is the newest photo, the one the picker shows first, with a face for Portrait.
    /// The file is copied into this test bundle before signing (it is not part of the regular test target).
    private func addReviewPortraitToLibrary() {
        guard let url = Bundle(for: Self.self).url(forResource: "review-portrait", withExtension: "jpg") else { return }
        let granted = expectation(description: "add-only Photos access")
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in granted.fulfill() }
        allowPhotosAddIfAsked()
        wait(for: [granted], timeout: 30)
        try? PHPhotoLibrary.shared().performChangesAndWait {
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        }
        pause(1)
    }

    @discardableResult
    private func visit(_ tool: String, for seconds: TimeInterval) -> Bool {
        guard tapIfPresent(app.buttons[tool], wait: 3) else { return false }
        pause(seconds)
        return true
    }

    /// Taps the first thumbnail, the newest photo (Recents lists newest first on the phone), by position as the
    /// simulator tests do: the picker's image elements are not reliably tappable themselves.
    private func chooseFirstPhoto() {
        let grid = app.scrollViews["photosView_content_scroll_view"]
        guard grid.waitForExistence(timeout: 20) else { return }
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 2), close.isHittable { close.tap(); pause(1) }
        let editor = app.buttons["tool.develop"]
        for offset in [CGVector(dx: 0.17, dy: 0.12), CGVector(dx: 0.17, dy: 0.2)] where !editor.exists {
            guard grid.exists else { break }
            grid.coordinate(withNormalizedOffset: offset).tap()
            _ = editor.waitForExistence(timeout: 10)
        }
    }

    private func allowPhotosAddIfAsked() {
        for label in ["Allow", "Allow Access", "OK", "Add Photos Only"] {
            let button = springboard.alerts.buttons[label].firstMatch
            if button.waitForExistence(timeout: label == "Allow" ? 5 : 1) { button.tap(); return }
        }
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @discardableResult
    private func tapIfPresent(_ element: XCUIElement, wait: TimeInterval = 5) -> Bool {
        guard element.waitForExistence(timeout: wait), element.isHittable else { return false }
        element.tap()
        return true
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
