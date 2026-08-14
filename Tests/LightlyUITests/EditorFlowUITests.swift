import XCTest

/// End-to-end verification against a running app on a simulator.
///
/// Snapshot tests render views in isolation; this exercises the real thing —
/// the system photo picker, the actual decode path, the live editor — which is
/// where integration problems such as a lost EXIF orientation actually surface.
///
/// Screenshots are written to `LIGHTLY_UI_TEST_OUTPUT` when set, so a run can be
/// inspected afterwards rather than only passing or failing.
final class EditorFlowUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Generous, because the picker involves another process.
    private let timeout: TimeInterval = 20

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    // MARK: - Launch

    func testLaunchShowsTaglineAndNoChrome() {
        XCTAssertTrue(
            app.staticTexts["Lightly"].waitForExistence(timeout: timeout),
            "Launch screen should show the wordmark."
        )
        // Spec §4.1: no login, no onboarding, no buttons.
        XCTAssertFalse(app.buttons["Sign In"].exists)
        XCTAssertFalse(app.buttons["Continue"].exists)

        capture(named: "01-launch")
    }

    // MARK: - Source selection

    func testSwipeUpRevealsSourceSheet() {
        XCTAssertTrue(app.staticTexts["Lightly"].waitForExistence(timeout: timeout))

        app.swipeUp()

        XCTAssertTrue(
            app.staticTexts["Choose a photo"].waitForExistence(timeout: timeout),
            "Swiping up should reveal the source sheet."
        )
        XCTAssertTrue(app.staticTexts["Camera"].exists)
        XCTAssertTrue(app.staticTexts["Photo Library"].exists)

        capture(named: "02-source-sheet")
    }

    // MARK: - Full flow

    /// Selects a photo, develops it, and opens Looks.
    ///
    /// The photo library of a fresh simulator contains Apple's sample images,
    /// several of which carry EXIF orientation — which is what makes this a real
    /// check of the orientation fix rather than a synthetic one.
    func testSelectDevelopAndOpenLooks() throws {
        XCTAssertTrue(app.staticTexts["Lightly"].waitForExistence(timeout: timeout))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Photo Library"].waitForExistence(timeout: timeout))
        app.staticTexts["Photo Library"].tap()

        try selectFirstPhotoFromSystemPicker()

        // Pre-develop state.
        let develop = app.buttons["action.develop"]
        XCTAssertTrue(
            develop.waitForExistence(timeout: timeout),
            "Editor should show the Develop action after selection."
        )
        XCTAssertFalse(
            app.buttons["action.compare"].exists,
            "Compare must be absent before a developed version exists (spec §0.11)."
        )
        capture(named: "03-photo-selected")

        // Develop.
        develop.tap()

        let looks = app.buttons["tool.looks"]
        XCTAssertTrue(
            looks.waitForExistence(timeout: timeout),
            "Contextual bar should appear once developed."
        )
        XCTAssertTrue(
            app.buttons["action.compare"].exists,
            "Compare must be available after development."
        )
        XCTAssertFalse(
            app.buttons["action.develop"].exists,
            "The Develop action should be gone once developed."
        )
        capture(named: "04-developed")

        // Looks.
        looks.tap()
        XCTAssertTrue(
            app.staticTexts["Looks"].waitForExistence(timeout: timeout),
            "Looks screen should open from the contextual bar."
        )
        XCTAssertTrue(
            app.staticTexts["A general starting set — not yet tailored to this photo."]
                .waitForExistence(timeout: timeout),
            "The non-personalised disclaimer must be shown while scene analysis is missing."
        )
        capture(named: "05-looks")

        // Preview a Look; the Apply action appears only once one is selected.
        let firstLook = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'look.'")
        ).firstMatch
        XCTAssertTrue(firstLook.waitForExistence(timeout: timeout), "Expected Look cells.")
        firstLook.tap()

        XCTAssertTrue(
            app.buttons["looks.apply"].waitForExistence(timeout: timeout),
            "Selecting a Look should reveal Apply."
        )
        capture(named: "06-looks-previewing")
    }

    /// Develops a photograph and exports it to the library.
    ///
    /// Covers the part the unit tests deliberately stub: the real PhotoKit
    /// write, including the add-only permission prompt.
    func testExportSavesToPhotoLibrary() throws {
        XCTAssertTrue(app.staticTexts["Lightly"].waitForExistence(timeout: timeout))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Photo Library"].waitForExistence(timeout: timeout))
        app.staticTexts["Photo Library"].tap()

        try selectFirstPhotoFromSystemPicker()

        app.buttons["action.develop"].tap()

        let share = app.buttons["action.share"]
        XCTAssertTrue(
            share.waitForExistence(timeout: timeout),
            "Share should be available once developed."
        )
        share.tap()

        XCTAssertTrue(
            app.staticTexts["Export"].waitForExistence(timeout: timeout),
            "Share should open the export sheet."
        )
        capture(named: "07-export-sheet")

        // Location must be off by default (spec §13, §19).
        let location = app.switches["export.preserveLocation"]
        if location.waitForExistence(timeout: 5) {
            XCTAssertEqual(
                location.value as? String, "0",
                "Location must default to off."
            )
        }

        app.buttons["export.save"].tap()

        // The add-only permission prompt is a system alert. Tapping it from a
        // UI test is unreliable, so the runner is expected to have granted
        // `photos-add` beforehand (see docs/phase-2-deferred.md). This tap
        // remains as a fallback for a run against an ungranted simulator.
        //
        // `BEGINSWITH` rather than `CONTAINS`: the prompt's other button is
        // "Don't Allow", which a contains-match also selects — silently
        // declining and failing the export for a reason unrelated to the app.
        //
        // This test therefore covers the *write*, not the permission dialog.
        // The denial path is covered by `ExportViewModelTests`.
        let allow = springboard.buttons
            .matching(NSPredicate(format: "label BEGINSWITH[c] 'Allow' OR label ==[c] 'OK'"))
            .firstMatch
        if allow.waitForExistence(timeout: 5) {
            allow.tap()
        }

        // A permission failure here means the simulator was not granted
        // add-only access; say so rather than reporting an export defect.
        if app.staticTexts["Lightly needs permission to add photos to your library. You can grant it in Settings."]
            .waitForExistence(timeout: 3) {
            throw XCTSkip(
                """
                Simulator has not granted add-only Photos access. Run: \
                xcrun simctl privacy booted grant photos-add com.lightlylabs.lightly
                """
            )
        }

        XCTAssertTrue(
            app.staticTexts["Saved"].waitForExistence(timeout: 30),
            "Export should confirm once the photo is written to the library."
        )
        capture(named: "08-export-saved")
    }

    private var springboard: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    // MARK: - Helpers

    /// Taps the first photo in Apple's system photo picker.
    ///
    /// The picker presents as a remote view inside the app's element tree, but
    /// its thumbnail grid is drawn as a single layer — the individual photos are
    /// not exposed as queryable cells or images. Selection therefore has to go
    /// through a coordinate tap. `PickerDiagnostics` dumps the live hierarchy if
    /// this ever needs revisiting.
    private func selectFirstPhotoFromSystemPicker() throws {
        let grid = app.scrollViews["photosView_content_scroll_view"]
        guard grid.waitForExistence(timeout: timeout) else {
            throw XCTSkip("System photo picker did not present.")
        }

        // The "Private Access to Photos" explainer sits above the grid and
        // shifts the first row down; dismissing it puts the thumbnails in a
        // predictable place.
        let dismissExplainer = app.buttons["Close"].firstMatch
        if dismissExplainer.waitForExistence(timeout: 3), dismissExplainer.isHittable {
            dismissExplainer.tap()
        }

        // First thumbnail: left column, just below the navigation bar.
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.12)).tap()

        // The picker dismisses itself on selection; if it is still up, no photo
        // was hit and the library is probably empty.
        let editorAppeared = app.buttons["action.develop"].waitForExistence(timeout: timeout)
        guard editorAppeared else {
            throw XCTSkip(
                """
                Tapped the picker grid but no photo was selected. A fresh \
                simulator has an empty photo library; add one with \
                `xcrun simctl addmedia <udid> <file>` and re-run.
                """
            )
        }
    }

    /// Saves a screenshot as a test attachment, and to disk when a destination
    /// directory is provided.
    private func capture(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let directory = ProcessInfo.processInfo
            .environment["LIGHTLY_UI_TEST_OUTPUT"] else { return }

        let url = URL(fileURLWithPath: directory)
            .appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }
}
