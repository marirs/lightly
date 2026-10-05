import XCTest

/// Slice 1 navigation on the running app: Welcome's Privacy Policy link, every More page and
/// its Back, the recovery screens, and preferences that survive a relaunch.
///
/// Every launch passes `--reset-preferences` (DEBUG) so each test starts from the approved
/// defaults, except the relaunch that checks persistence.
final class WelcomeAndMoreUITests: XCTestCase {

    private var app: XCUIApplication!
    private let timeout: TimeInterval = 15

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--reset-preferences"]
        app.launch()
    }

    // MARK: - Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func waitForWelcome(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.buttons["welcome.choosePhoto"].waitForExistence(timeout: timeout), "Welcome expected", file: file, line: line)
    }

    private func tap(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = app.buttons[identifier].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(identifier) missing", file: file, line: line)
        target.tap()
    }

    private func assertOnPage(_ page: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element("more.page.\(page)").waitForExistence(timeout: timeout), "Expected More page \(page)", file: file, line: line)
    }

    private func openPreferences() {
        waitForWelcome()
        tap("welcome.more")
        assertOnPage("menu")
        tap("more.row.preferences")
        assertOnPage("preferences")
    }

    /// The switch's value as the toggle reports it ("1" on, "0" off).
    private func switchValue(_ identifier: String) -> String? {
        let control = app.switches[identifier].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: timeout), "\(identifier) switch missing")
        return control.value as? String
    }

    // MARK: - Welcome › Privacy Policy

    func testPrivacyPolicyFromWelcomeReturnsToWelcome() {
        waitForWelcome()
        tap("welcome.privacyPolicy")
        assertOnPage("privacyPolicy")
        // The bundled text is the website's Privacy Policy (lightly.pro/privacy).
        XCTAssertTrue(element("legal.document").exists)
        XCTAssertTrue(app.staticTexts["Editing on your device"].exists)
        tap("page.back")
        waitForWelcome()
        XCTAssertFalse(element("more.page.privacyPolicy").exists)
    }

    // MARK: - More pages and Back

    /// Preferences › Saved signature › Draw a new signature replaces the More page with the Draw
    /// signature sheet (prototype `overlay:sigDraw`); Cancel returns to the screen beneath More.
    func testDrawFromPreferencesReplacesTheMorePage() {
        openPreferences()
        tap("preferences.signature"); assertOnPage("savedSignature")
        tap("signature.draw")
        XCTAssertTrue(app.buttons["signature.draw.save"].waitForExistence(timeout: timeout), "Draw signature sheet")
        XCTAssertFalse(element("more.page.savedSignature").exists, "More is replaced, not covered")
        if let directory = ProcessInfo.processInfo.environment["LIGHTLY_VERIFY_DIR"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("pref-sig-draw.png"))
        }
        tap("sheet.cancel")
        waitForWelcome()
        XCTAssertFalse(element("more.page.menu").exists)
    }

    func testEveryMorePageGoesBackToItsParent() {
        waitForWelcome()
        tap("welcome.more")
        assertOnPage("menu")

        tap("more.row.preferences"); assertOnPage("preferences")
        tap("preferences.favourites"); assertOnPage("favourites")
        tap("page.back"); assertOnPage("preferences")
        tap("preferences.signature"); assertOnPage("savedSignature")
        tap("page.back"); assertOnPage("preferences")
        tap("preferences.preferredBorder"); assertOnPage("preferredBorder")
        tap("page.back"); assertOnPage("preferences")
        tap("page.back"); assertOnPage("menu")

        tap("more.row.legal"); assertOnPage("legal")
        tap("more.row.privacyPolicy"); assertOnPage("privacyPolicy")
        tap("page.back"); assertOnPage("legal")
        tap("more.row.termsOfUse"); assertOnPage("termsOfUse")
        XCTAssertTrue(element("legal.document").exists)
        XCTAssertTrue(app.staticTexts["Your photographs"].exists)
        tap("page.back"); assertOnPage("legal")
        tap("page.back"); assertOnPage("menu")

        tap("more.row.about"); assertOnPage("about")
        XCTAssertTrue(element("about.version").label.contains("Version"), element("about.version").label)
        tap("more.row.support"); assertOnPage("support")
        XCTAssertFalse(element("support.unavailable").exists, "Support has a destination (hello@lightly.pro)")
        tap("page.back"); assertOnPage("about")
        tap("page.back"); assertOnPage("menu")

        tap("page.close")
        waitForWelcome()
        XCTAssertFalse(element("more.page.menu").exists)
    }

    // MARK: - Preferences

    func testDefaults() {
        openPreferences()
        XCTAssertTrue(app.buttons["appearance.system"].isSelected)
        XCTAssertEqual(switchValue("preferences.keepMetadata"), "1", "Keep photo metadata defaults on")
        XCTAssertEqual(switchValue("preferences.includeLocation"), "0", "Include location defaults off")
    }

    /// Turning one switch off never changes the other.
    func testMetadataSwitchesAreIndependent() {
        openPreferences()
        app.switches["preferences.keepMetadata"].firstMatch.tap()
        XCTAssertEqual(switchValue("preferences.keepMetadata"), "0")
        XCTAssertEqual(switchValue("preferences.includeLocation"), "0")
        app.switches["preferences.includeLocation"].firstMatch.tap()
        XCTAssertEqual(switchValue("preferences.includeLocation"), "1", "Location can be on while metadata is off")
        XCTAssertEqual(switchValue("preferences.keepMetadata"), "0")
        app.switches["preferences.keepMetadata"].firstMatch.tap()
        XCTAssertEqual(switchValue("preferences.keepMetadata"), "1")
        XCTAssertEqual(switchValue("preferences.includeLocation"), "1")
    }

    func testPreferencesPersistAcrossRelaunch() {
        openPreferences()
        tap("appearance.dark")
        XCTAssertTrue(app.buttons["appearance.dark"].isSelected)
        app.switches["preferences.keepMetadata"].firstMatch.tap()
        app.switches["preferences.includeLocation"].firstMatch.tap()
        tap("preferences.preferredBorder")
        tap("border.polaroid")
        tap("page.back")

        app.terminate()
        app.launchArguments = []   // no reset: what was stored must come back
        app.launch()

        openPreferences()
        XCTAssertTrue(app.buttons["appearance.dark"].isSelected, "Appearance persists")
        XCTAssertEqual(switchValue("preferences.keepMetadata"), "0", "Keep photo metadata persists")
        XCTAssertEqual(switchValue("preferences.includeLocation"), "1", "Include location persists")
        tap("preferences.preferredBorder")
        XCTAssertTrue(app.buttons["border.polaroid"].isSelected, "Preferred border persists")
    }

    func testFavouritesCanBeRemovedAndReordered() {
        app.terminate()
        app.launchArguments = ["--reset-preferences", "--seed-favourites"]
        app.launch()
        openPreferences()
        tap("preferences.favourites")
        assertOnPage("favourites")
        let first = element("favourites.row.0")
        XCTAssertTrue(first.waitForExistence(timeout: timeout))
        let firstLabel = first.label
        let secondLabel = element("favourites.row.1").label

        // Drag the first row's handle onto the second row, as a finger would.
        let handle = first.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        let target = element("favourites.row.1").coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.7))
        handle.press(forDuration: 1.0, thenDragTo: target)
        let reordered = NSPredicate { _, _ in self.element("favourites.row.0").label == secondLabel }
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: reordered, evaluatedWith: nil)], timeout: 5), .completed,
                       "Dragging the handle should reorder; first row is now \(element("favourites.row.0").label)")
        XCTAssertEqual(element("favourites.row.1").label, firstLabel)

        app.buttons["favourites.remove.0"].tap()
        XCTAssertFalse(element("favourites.row.4").waitForExistence(timeout: 2), "Four left")
        XCTAssertTrue(app.staticTexts["1 free. Star a preset in Develop to add it."].exists)
    }

    // MARK: - Recovery

    func testPhotoThatCannotBeOpenedOffersAnotherPhotoAndClose() {
        app.terminate()
        app.launchArguments = ["--reset-preferences", "--open-unreadable-photo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["This photo can’t be opened"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["loadFailed.chooseAnother"].exists)
        XCTAssertTrue(app.buttons["loadFailed.tryAgain"].exists)
        tap("loadFailed.tryAgain")
        XCTAssertTrue(app.staticTexts["This photo can’t be opened"].waitForExistence(timeout: timeout), "Still unreadable")
        tap("recovery.close")
        waitForWelcome()
    }
}
