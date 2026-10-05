import UIKit
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

    // MARK: - Welcome

    /// Welcome shows the brand and both ways in; no login, no onboarding (approved Welcome).
    func testWelcomeShowsBrandAndBothWaysIn() {
        XCTAssertTrue(app.staticTexts["Lightly"].waitForExistence(timeout: timeout), "Welcome should show the wordmark.")
        XCTAssertTrue(app.staticTexts["See it as you remember it."].exists)
        XCTAssertTrue(app.buttons["welcome.choosePhoto"].exists)
        XCTAssertTrue(app.buttons["welcome.camera"].exists)
        XCTAssertTrue(app.buttons["welcome.privacyPolicy"].exists)
        XCTAssertTrue(app.buttons["welcome.more"].exists)
        XCTAssertFalse(app.buttons["Sign In"].exists)
        XCTAssertFalse(app.buttons["Continue"].exists)

        capture(named: "01-welcome")
    }

    /// Cancelling the system picker returns to Welcome with nothing changed.
    func testCancellingThePickerReturnsToWelcome() throws {
        XCTAssertTrue(app.buttons["welcome.choosePhoto"].waitForExistence(timeout: timeout))
        app.buttons["welcome.choosePhoto"].tap()
        let grid = app.scrollViews["photosView_content_scroll_view"]
        guard grid.waitForExistence(timeout: timeout) else { throw XCTSkip("System photo picker did not present.") }
        capture(named: "02-system-photo-picker")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 3) {
            cancel.tap()
        } else {
            grid.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(app.buttons["welcome.choosePhoto"].waitForExistence(timeout: timeout))
        XCTAssertFalse(grid.waitForExistence(timeout: 2), "The picker should be gone")
        XCTAssertTrue(app.staticTexts["See it as you remember it."].exists, "Still on Welcome")
    }

    /// ⋮ in the editor opens More; closing it returns to the same photo.
    func testEditorMoreOpensAndCloses() throws {
        try openFirstLibraryPhoto()
        let more = app.buttons["editor.more"]
        XCTAssertTrue(more.waitForExistence(timeout: timeout))
        more.tap()
        XCTAssertTrue(app.buttons["more.row.preferences"].waitForExistence(timeout: timeout))
        capture(named: "02c-editor-more")
        app.buttons["page.close"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["editor.photo"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["more.row.preferences"].exists)
    }

    // MARK: - Editor (slice 2)

    private func photoPath(_ name: String) -> String {
        "\(EditorCaptureUITests.repositoryRoot)/docs/ui/assets/photos/\(name).jpg"
    }

    /// Opens a prototype photograph straight into the editor (DEBUG `--open-photo`).
    private func openEditor(_ photo: String = "landscape_02", extra: [String] = []) {
        relaunch(arguments: ["--reset-preferences", "--fake-library-writer", "--open-photo", photoPath(photo)] + extra)
        XCTAssertTrue(element("develop.ruler").waitForExistence(timeout: timeout), "editor did not open")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func relaunch(arguments: [String]) {
        app.terminate()
        app.launchArguments = arguments
        app.launch()
    }

    private func label(_ identifier: String) -> String { element(identifier).label }

    /// Drags the ruler by `stops` (positive = towards higher stops) and releases.
    private func dragRuler(by stops: Int) {
        let ruler = element("develop.ruler")
        let start = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: -CGFloat(stops) * 12, dy: 0))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    func testPickedPhotoDevelopsByItselfIntoTheApprovedUnavailableState() throws {
        try openFirstLibraryPhoto()
        XCTAssertTrue(element("develop.ruler").waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["Automatic correction isn't available on this device. Presets still work."].exists)
        XCTAssertEqual(label("develop.name"), "Original")
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled)
        for tool in ["develop", "background", "edit", "effects", "watermark", "border"] {
            XCTAssertTrue(element("tool.\(tool)").exists, "\(tool) is listed")
        }
        capture(named: "s2-01-opened")
    }

    func testOpeningShowsThePhotoWhileLoading() {
        relaunch(arguments: ["--reset-preferences", "--open-photo", photoPath("landscape_02"), "--hold-phase", "opening"])
        XCTAssertTrue(element("loading.opening").waitForExistence(timeout: timeout))
        XCTAssertTrue(element("editor.photo").exists, "The photo stays visible")
        element("loading.cancel").tap()
        XCTAssertTrue(app.buttons["welcome.choosePhoto"].waitForExistence(timeout: timeout))
    }

    func testRulerPreviewsWhileDraggingAndReleaseIsOneUndoStep() {
        openEditor()
        XCTAssertEqual(label("develop.position"), "0 / 518")
        dragRuler(by: 5)
        XCTAssertTrue(waitFor { self.label("develop.position") != "0 / 518" })
        let applied = label("develop.name")
        XCTAssertNotEqual(applied, "Original")
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled)
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == "Original" })
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled, "Exactly one step")
        app.buttons["editor.redo"].tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == applied })
        capture(named: "s2-02-preset")
    }

    func testBrowsingAnotherCategoryKeepsTheLookAndShowsTheContextLine() {
        openEditor(extra: ["--scenario", "dev-preset"])
        XCTAssertTrue(waitFor { self.label("develop.name") == "05 Hiking 05" })
        element("develop.category.cinematic").tap()
        XCTAssertTrue(waitFor { self.label("develop.context") == "Applied: 05 Hiking 05" })
        XCTAssertEqual(label("develop.position"), "0 / 564")
        XCTAssertEqual(label("develop.name"), "Original")
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled, "Browsing made no undo step")
        // Landscape is scrolled out of sight to the left: swipe the row back, then choose it.
        let landscape = element("develop.category.landscape")
        for _ in 0..<3 where !landscape.isHittable {
            let start = element("develop.category.cinematic").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 200, dy: 0)))
        }
        landscape.tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == "05 Hiking 05" })
        XCTAssertEqual(label("develop.position"), "37 / 518")
    }

    func testAmountOpensTheSliderWithDone() {
        openEditor(extra: ["--scenario", "dev-preset"])
        XCTAssertTrue(waitFor { self.element("develop.amount").label == "Amount 100" })
        element("develop.amount").tap()
        XCTAssertTrue(element("slider.amount").waitForExistence(timeout: timeout))
        // Drag the knob from the track's end towards its start, as a finger does.
        let slider = element("slider.amount")
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)))
        element("develop.amount.done").tap()
        XCTAssertTrue(element("develop.ruler").waitForExistence(timeout: timeout))
        XCTAssertNotEqual(element("develop.amount").label, "Amount 100")
    }

    func testFavouritesStarFullNoticeAndReplace() {
        openEditor(extra: ["--scenario", "dev-fav-full"])
        XCTAssertTrue(element("develop.favourites.replace").waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Favourites holds five presets.'")).firstMatch.exists)
        element("develop.favourites.replace").tap()
        XCTAssertTrue(element("replace.cancel").waitForExistence(timeout: timeout))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'replace.row.'")).element(boundBy: 0).tap()
        XCTAssertFalse(element("replace.cancel").exists)
        XCTAssertTrue(element("develop.category.favourites").label.contains("5 of 5"))
    }

    func testSaveCopyShowsSavingThenSavedAndKeepEditing() {
        openEditor(extra: ["--scenario", "dev-preset"])
        XCTAssertTrue(waitFor { self.label("develop.name") == "05 Hiking 05" })
        app.buttons["editor.saveCopy"].tap()
        XCTAssertTrue(element("saved.keepEditing").waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["Saved as a new photo"].exists)
        XCTAssertTrue(app.staticTexts["The original is unchanged."].exists)
        element("saved.keepEditing").tap()
        XCTAssertTrue(element("develop.ruler").waitForExistence(timeout: timeout))
        // Saved: Close needs no confirmation.
        app.buttons["editor.close"].tap()
        XCTAssertTrue(app.buttons["welcome.choosePhoto"].waitForExistence(timeout: timeout))
    }

    /// Save copy through the real Photos writer (no fake writer), tapped as a person does. The runner grants the
    /// add-only permission beforehand and checks the new file, its size and the unchanged original afterwards.
    func testSaveCopyWritesANewPhotoThroughPhotos() {
        relaunch(arguments: ["--reset-preferences", "--open-photo", photoPath("landscape_02")])
        XCTAssertTrue(element("develop.ruler").waitForExistence(timeout: timeout), "editor did not open")
        app.buttons["editor.saveCopy"].tap()
        XCTAssertTrue(app.staticTexts["Saved as a new photo"].waitForExistence(timeout: 90), "no Saved sheet")
        XCTAssertTrue(app.staticTexts["The original is unchanged."].exists)
    }

    func testClosingWithUnsavedEditsAsks() {
        openEditor()
        dragRuler(by: 3)
        XCTAssertTrue(waitFor { self.label("develop.name") != "Original" })
        app.buttons["editor.close"].tap()
        XCTAssertTrue(app.alerts["Leave without saving?"].waitForExistence(timeout: timeout))
        app.alerts.buttons["Keep editing"].tap()
        XCTAssertTrue(element("develop.ruler").exists)
        app.buttons["editor.close"].tap()
        app.alerts.buttons["Discard edits"].tap()
        XCTAssertTrue(app.buttons["welcome.choosePhoto"].waitForExistence(timeout: timeout))
    }

    func testPortraitIsOfferedOnlyForAPhotoWithAPerson() {
        openEditor("landscape_02")
        XCTAssertFalse(element("tool.portrait").exists, "No person: Portrait hidden")
        openEditor("portrait_deep_03")
        XCTAssertTrue(element("tool.portrait").waitForExistence(timeout: timeout), "A person: Portrait offered")
    }

    /// Restore after the system ends the app: an edit, the app in the background, the process
    /// killed (as the system does), then a plain launch reopens the same edit in the editor.
    /// Screenshots go to `LIGHTLY_VERIFY_DIR` when set (focused verification).
    func testTheSessionComesBackAfterTheSystemEndsTheApp() {
        openEditor()
        element("tool.effects").tap()
        element("effects.sub.Vignette").tap()
        element("effects.vignette.toggle").tap()
        XCTAssertEqual(element("tool.effects").value as? String, "Edited")
        saveScreenshot("restore-1-before")
        XCUIDevice.shared.press(.home)
        // The system saves scene state as the app enters the background; give it time before the kill.
        _ = app.wait(for: .runningBackgroundSuspended, timeout: 5)
        Thread.sleep(forTimeInterval: 3)
        relaunch(arguments: [])
        // A cold launch loads the preset pack before the editor is ready (slow under a full suite).
        XCTAssertTrue(element("develop.ruler").waitForExistence(timeout: 60), "the editor reopens")
        XCTAssertEqual(element("tool.effects").value as? String, "Edited", "with the same edit")
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled, "and its history")
        saveScreenshot("restore-2-after-relaunch")
        app.buttons["editor.undo"].tap()
        XCTAssertNotEqual(element("tool.effects").value as? String, "Edited")
    }

    private func saveScreenshot(_ name: String) {
        guard let directory = ProcessInfo.processInfo.environment["LIGHTLY_VERIFY_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    /// Watermark in the same session: Text marks the tool used, the Position row cycles the
    /// anchors, and Undo walks back one whole step at a time.
    func testWatermarkTextPositionAndUndo() {
        openEditor()
        element("tool.watermark").tap()
        XCTAssertTrue(element("watermark.type.Text").waitForExistence(timeout: timeout))
        element("watermark.type.Text").tap()
        XCTAssertTrue(element("watermark.font.Caveat").waitForExistence(timeout: timeout))
        XCTAssertEqual(element("tool.watermark").value as? String, "Edited")
        XCTAssertTrue(app.staticTexts["Bottom right"].exists)
        element("watermark.position").tap()
        XCTAssertTrue(app.staticTexts["Top left"].waitForExistence(timeout: timeout))
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(app.staticTexts["Bottom right"].waitForExistence(timeout: timeout))
        app.buttons["editor.undo"].tap()
        XCTAssertNotEqual(element("tool.watermark").value as? String, "Edited")
    }

    /// Edit and Effects in the same session as Develop: an effect switched on marks Effects
    /// ("used" dot), a crop aspect marks Edit, and Undo walks back whole recipes, one step each.
    func testEditAndEffectsShareTheSessionAndUndoStepByStep() {
        openEditor()
        element("tool.effects").tap()
        XCTAssertTrue(element("effects.leak.toggle").waitForExistence(timeout: timeout))
        element("effects.sub.Vignette").tap()
        element("effects.vignette.toggle").tap()
        XCTAssertEqual(element("tool.effects").value as? String, "Edited")
        element("tool.edit").tap()
        XCTAssertTrue(element("edit.aspect.1:1").waitForExistence(timeout: timeout))
        element("edit.aspect.1:1").tap()
        XCTAssertEqual(element("tool.edit").value as? String, "Edited")
        XCTAssertTrue(element("edit.aspect.1:1").isSelected)
        element("editor.undo").tap()
        XCTAssertFalse(element("edit.aspect.1:1").isSelected, "Undo removes the crop")
        XCTAssertEqual(element("tool.effects").value as? String, "Edited", "…and keeps the earlier vignette")
        element("editor.undo").tap()
        XCTAssertNotEqual(element("tool.effects").value as? String, "Edited")
        element("editor.redo").tap()
        XCTAssertEqual(element("tool.effects").value as? String, "Edited")
    }

    func testFailedAutoOffersRetryAndContinueWithOriginal() {
        openEditor(extra: ["--auto-fails"])
        XCTAssertTrue(element("develop.auto.retry").waitForExistence(timeout: timeout))
        element("develop.auto.original").tap()
        XCTAssertFalse(element("develop.auto.retry").exists)
        XCTAssertEqual(label("develop.name"), "Original")
    }

    private func openFirstLibraryPhoto() throws {
        XCTAssertTrue(app.buttons["welcome.choosePhoto"].waitForExistence(timeout: timeout))
        app.buttons["welcome.choosePhoto"].tap()
        try selectFirstPhotoFromSystemPicker()
    }

    private func waitFor(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

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

        capture(named: "02b-system-photo-picker")

        // First thumbnail: left column, just below the navigation bar. On iPad the picker is a
        // sheet with a sidebar on the left of the same scroll view, so its first thumbnail sits
        // further right; that position is tried if the phone one selected nothing.
        let photo = app.descendants(matching: .any)["editor.photo"]
        var editorAppeared = false
        for offset in [CGVector(dx: 0.17, dy: 0.12), CGVector(dx: 0.43, dy: 0.2)] where !editorAppeared {
            guard grid.exists else { break }
            grid.coordinate(withNormalizedOffset: offset).tap()
            editorAppeared = photo.waitForExistence(timeout: 8)
        }
        // The picker dismisses itself on selection; if it is still up, no photo
        // was hit and the library is probably empty.
        editorAppeared = editorAppeared || photo.waitForExistence(timeout: timeout)
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
