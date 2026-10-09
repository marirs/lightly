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
        // Start clean (2026-10-06): XCUITest's terminate() ends the app the way the system does, so the scene session
        // survives and a plain launch restores the previous test's unsaved edit (the designed system-kill restore).
        // --reset-preferences clears the stored session (DEBUG). The restore test relaunches without it on purpose.
        app.launchArguments = ["--reset-preferences"]
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

    /// iOS 1.0 Auto is Core Image auto enhancement (owner approval 2026-10-06): applied at open as the starting state
    /// (stop zero reads "Auto"); the Auto switch turns it off as one Undo step.
    func testPickedPhotoDevelopsByItselfWithCoreImageAuto() throws {
        try openFirstLibraryPhoto()
        XCTAssertTrue(element("develop.ruler").waitForExistence(timeout: timeout))
        XCTAssertFalse(element("develop.notice").exists)
        XCTAssertTrue(waitFor { self.label("develop.name") == "Auto" }, "Auto applied: \(self.label("develop.name"))")
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled, "Auto is the starting state, not an edit")
        element("develop.auto").tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == "Original" })
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled, "switching Auto off is one step")
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == "Auto" })
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
        // Stop zero reads Auto now that Core Image Auto is applied at open.
        XCTAssertTrue(waitFor { self.label("develop.name") == "Auto" })
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled, "Exactly one step")
        app.buttons["editor.redo"].tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == applied })
        capture(named: "s2-02-preset")
    }

    func testBrowsingAnotherCategoryKeepsTheLookAndShowsTheContextLine() {
        openEditor(extra: ["--scenario", "dev-preset"])
        XCTAssertTrue(waitFor { self.label("develop.name") == "Quiet Honey Daylight" })
        element("develop.category.cinematic").tap()
        XCTAssertTrue(waitFor { self.label("develop.context") == "Applied from Landscape" })
        XCTAssertEqual(label("develop.position"), "37 / 518", "The applied preset's position, beside its name")
        XCTAssertEqual(label("develop.name"), "Quiet Honey Daylight", "The applied preset, not 'Original'")
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled, "Browsing made no undo step")
        // Landscape is scrolled out of sight to the left: swipe the row back, then choose it.
        let landscape = element("develop.category.landscape")
        for _ in 0..<3 where !landscape.isHittable {
            let start = element("develop.category.cinematic").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 200, dy: 0)))
        }
        landscape.tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == "Quiet Honey Daylight" })
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

    func testFavouriteRemovalRefreshesWithoutRelaunch() {
        openEditor(extra: ["--scenario", "dev-preset"])
        XCTAssertTrue(waitFor { self.label("develop.name") == "Quiet Honey Daylight" })
        element("develop.star").tap()
        element("develop.category.favourites").tap()
        XCTAssertTrue(waitFor { self.label("develop.position") == "1 / 1" })
        element("develop.star").tap()
        XCTAssertTrue(waitFor { !self.element("develop.star").isSelected })
        XCTAssertFalse(element("develop.position").exists, "Removed preset is not still on the favourites ruler")
        XCTAssertEqual(label("develop.name"), "Quiet Honey Daylight", "Removing the shortcut keeps the applied edit")
        element("develop.category.landscape").tap()
        element("develop.category.favourites").tap()
        XCTAssertFalse(element("develop.position").exists)
    }

    func testLandscapeHidesPortraitCategory() {
        openEditor("landscape_03")
        XCTAssertFalse(element("develop.category.portrait").exists)
        XCTAssertTrue(element("develop.category.landscape").exists)
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
        XCTAssertTrue(waitFor { self.label("develop.name") == "Quiet Honey Daylight" })
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

    /// One interaction pass over the owner's 2026-10-05 feedback, as a person does it, with screenshots
    /// (LIGHTLY_VERIFY_DIR): open a photo, apply a Landscape preset, browse Portrait, open Background, crop freely
    /// (a corner, then moving the rectangle), Save copy through the real Photos writer. The runner checks the saved
    /// file and the unchanged original.
    func testOwnerFeedbackInteractionPass() {
        let mattes = "\(EditorCaptureUITests.repositoryRoot)/ios/Tests/Fixtures/SubjectMattes/portrait_medium_02.png"
        relaunch(arguments: ["--reset-preferences", "--open-photo", photoPath("portrait_medium_02"), "--subject-matte-fixture", mattes])
        XCTAssertTrue(element("develop.ruler").waitForExistence(timeout: timeout), "editor did not open")
        saveScreenshot("pass-1-opened")
        element("develop.category.landscape").tap()
        dragRuler(by: 5)
        XCTAssertTrue(waitFor { self.label("develop.name") != "Original" })
        let applied = label("develop.name")
        saveScreenshot("pass-2-landscape-applied")
        element("develop.category.portrait").tap()
        XCTAssertTrue(waitFor { self.label("develop.context").hasPrefix("Applied from Landscape") })  // "· N / M" since ab0a18b (owner amendment)
        XCTAssertEqual(label("develop.name"), applied, "browsing keeps naming the applied preset")
        saveScreenshot("pass-3-browsing-portrait")
        element("tool.background").tap()
        XCTAssertTrue(waitFor(timeout: 60) { !self.element("background.separating").exists })
        saveScreenshot("pass-4-background")
        element("tool.edit").tap()
        let photo = element("editor.photo")
        XCTAssertTrue(photo.waitForExistence(timeout: timeout))
        saveScreenshot("pass-5-crop-whole-frame")
        // Bottom-right corner inwards, then move the rectangle left by dragging inside it.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
            .press(forDuration: 0.1, thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.75)))
        sleep(2)
        saveScreenshot("pass-6-corner-dragged")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4))
            .press(forDuration: 0.1, thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)))
        sleep(2)
        saveScreenshot("pass-7-moved")
        app.buttons["editor.saveCopy"].tap()
        XCTAssertTrue(app.staticTexts["Saved as a new photo"].waitForExistence(timeout: 120), "no Saved sheet")
        saveScreenshot("pass-8-saved")
    }

    /// Owner check 2026-10-05: browsing Portrait while a Landscape preset is applied, then cancelling, committing,
    /// Undo and Redo. The name row, position, context line and ruler each describe their own state at every step.
    /// Screenshots to LIGHTLY_VERIFY_DIR.
    func testRulerHeaderStaysCoherentWhileBrowsing() {
        relaunch(arguments: ["--reset-preferences", "--open-photo", photoPath("landscape_02")])
        XCTAssertTrue(element("develop.ruler").waitForExistence(timeout: timeout), "editor did not open")
        // An empty Text is not in the accessibility tree: absent reads as "".
        func text(_ id: String) -> String { element(id).exists ? label(id) : "" }
        element("develop.category.landscape").tap()
        dragRuler(by: 5)
        XCTAssertTrue(waitFor { self.label("develop.name") != "Original" })
        let applied = label("develop.name")
        let appliedPosition = text("develop.position")
        XCTAssertFalse(appliedPosition.isEmpty)
        saveScreenshot("ruler-1-landscape-applied")

        element("develop.category.portrait").tap()
        XCTAssertTrue(waitFor { text("develop.context").hasPrefix("Applied from Landscape · ") })
        XCTAssertEqual(label("develop.name"), applied)
        XCTAssertEqual(text("develop.context"), "Applied from Landscape · \(appliedPosition)")
        XCTAssertEqual(text("develop.position"), "", "no position beside the Landscape name while the Portrait ruler shows")
        saveScreenshot("ruler-2-browsing-portrait")

        // A drag on the resting Portrait ruler that ends where it started (pulled the other way, held at stop 0) is a
        // cancel; before the fix it committed "no Look" and dropped the Landscape preset.
        let ruler = element("develop.ruler")
        let centre = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        centre.press(forDuration: 0.05, thenDragTo: centre.withOffset(CGVector(dx: 60, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        XCTAssertEqual(label("develop.name"), applied, "the Landscape preset stays applied")
        XCTAssertTrue(text("develop.context").hasPrefix("Applied from Landscape"))
        saveScreenshot("ruler-3-after-touch-cancel")

        dragRuler(by: 2)
        XCTAssertTrue(waitFor { self.label("develop.name") != applied })
        let portrait = label("develop.name")
        XCTAssertEqual(text("develop.context"), "")
        let portraitPosition = text("develop.position")
        XCTAssertTrue(portraitPosition.range(of: #"^[1-9]\d* / \d+$"#, options: .regularExpression) != nil, portraitPosition)
        XCTAssertNotEqual(portraitPosition, appliedPosition, "this ruler's position, not Landscape's")
        saveScreenshot("ruler-4-portrait-applied")

        app.buttons["editor.undo"].tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == applied })
        XCTAssertEqual(text("develop.position"), appliedPosition, "after Undo the Landscape ruler and position are back")
        XCTAssertEqual(text("develop.context"), "")
        saveScreenshot("ruler-5-after-undo")

        app.buttons["editor.redo"].tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == portrait })
        XCTAssertEqual(text("develop.context"), "")
        XCTAssertEqual(text("develop.position"), portraitPosition)
        saveScreenshot("ruler-6-after-redo")
    }

    /// Owner check 2026-10-05: every corner and edge, moving, a locked ratio then Free, and cropping after a rotation and
    /// straightening; each step checked against the committed rectangle. Screenshots to LIGHTLY_VERIFY_DIR.
    func testCropHandlesMoveOnlyTheirOwnSides() {
        relaunch(arguments: ["--reset-preferences", "--expose-crop", "--open-photo", photoPath("landscape_02")])
        XCTAssertTrue(element("develop.ruler").waitForExistence(timeout: timeout), "editor did not open")
        element("tool.edit").tap()
        let photo = element("editor.photo")
        XCTAssertTrue(photo.waitForExistence(timeout: timeout))
        func crop() -> (aspect: String, x: Double, y: Double, w: Double, h: Double) {
            let parts = (element("edit.cropRect").value as? String ?? "").split(separator: " ").map(String.init)
            guard parts.count == 5 else { XCTFail("no crop readout"); return ("", 0, 0, 1, 1) }
            return (parts[0], Double(parts[1])!, Double(parts[2])!, Double(parts[3])!, Double(parts[4])!)
        }
        func drag(_ from: CGVector, _ to: CGVector) {
            photo.coordinate(withNormalizedOffset: from)
                .press(forDuration: 0.15, thenDragTo: photo.coordinate(withNormalizedOffset: to), withVelocity: .slow, thenHoldForDuration: 0.1)
            sleep(1)
        }
        let eps = 0.004
        func sides(_ c: (aspect: String, x: Double, y: Double, w: Double, h: Double)) -> [Double] { [c.x, c.y, c.x + c.w, c.y + c.h] }
        /// Which of left, top, right, bottom changed.
        func changed(_ a: [Double], _ b: [Double]) -> [Bool] { zip(a, b).map { abs($0 - $1) > eps } }

        var before = sides(crop())
        XCTAssertEqual(before, [0, 0, 1, 1], "starts as the whole frame")
        saveScreenshot("crop-0-whole")
        let corners: [(String, CGVector, CGVector, [Bool])] = [
            ("top-left", CGVector(dx: 0.01, dy: 0.01), CGVector(dx: 0.12, dy: 0.15), [true, true, false, false]),
            ("top-right", CGVector(dx: 0.99, dy: 0.15), CGVector(dx: 0.88, dy: 0.25), [false, true, true, false]),
            ("bottom-right", CGVector(dx: 0.88, dy: 0.99), CGVector(dx: 0.8, dy: 0.85), [false, false, true, true]),
            ("bottom-left", CGVector(dx: 0.12, dy: 0.85), CGVector(dx: 0.2, dy: 0.75), [true, false, false, true]),
        ]
        for (name, from, to, expected) in corners {
            drag(from, to)
            let after = sides(crop())
            XCTAssertEqual(changed(before, after), expected, "\(name) corner: \(before) → \(after)")
            before = after
            saveScreenshot("crop-corner-\(name)")
        }
        // Edges, at the middle of each side of the current rectangle.
        func mid(_ s: [Double]) -> (x: Double, y: Double) { ((s[0] + s[2]) / 2, (s[1] + s[3]) / 2) }
        let edges: [(String, (([Double]) -> (CGVector, CGVector)), [Bool])] = [
            ("left", { s in (CGVector(dx: s[0], dy: mid(s).y), CGVector(dx: s[0] + 0.05, dy: mid(s).y + 0.04)) }, [true, false, false, false]),
            ("right", { s in (CGVector(dx: s[2], dy: mid(s).y), CGVector(dx: s[2] - 0.05, dy: mid(s).y - 0.04)) }, [false, false, true, false]),
            ("top", { s in (CGVector(dx: mid(s).x, dy: s[1]), CGVector(dx: mid(s).x + 0.04, dy: s[1] + 0.05)) }, [false, true, false, false]),
            ("bottom", { s in (CGVector(dx: mid(s).x, dy: s[3]), CGVector(dx: mid(s).x - 0.04, dy: s[3] - 0.05)) }, [false, false, false, true]),
        ]
        for (name, points, expected) in edges {
            let (from, to) = points(before)
            drag(from, to)
            let after = sides(crop())
            XCTAssertEqual(changed(before, after), expected, "\(name) edge: \(before) → \(after)")
            before = after
            saveScreenshot("crop-edge-\(name)")
        }
        // Move: inside the rectangle; the size stays.
        let size = (before[2] - before[0], before[3] - before[1])
        drag(CGVector(dx: mid(before).x, dy: mid(before).y), CGVector(dx: mid(before).x - 0.06, dy: mid(before).y + 0.05))
        var after = sides(crop())
        XCTAssertEqual(after[2] - after[0], size.0, accuracy: eps); XCTAssertEqual(after[3] - after[1], size.1, accuracy: eps)
        XCTAssertEqual(after[0], before[0] - 0.06, accuracy: 0.01, "moved left"); XCTAssertEqual(after[1], before[1] + 0.05, accuracy: 0.01, "moved down")
        before = after
        saveScreenshot("crop-moved")

        // 1:1 locks the ratio, also while a corner is dragged; Free releases it.
        element("edit.aspect.1:1").tap()
        sleep(1)
        let frame = photo.frame
        func pixelRatio() -> Double { let c = crop(); return c.w * frame.width / (c.h * frame.height) }
        XCTAssertEqual(crop().aspect, "1:1"); XCTAssertEqual(pixelRatio(), 1, accuracy: 0.02)
        before = sides(crop())
        drag(CGVector(dx: before[2], dy: before[3]), CGVector(dx: before[2] - 0.08, dy: before[3] - 0.02))
        XCTAssertEqual(pixelRatio(), 1, accuracy: 0.02, "the corner keeps 1:1")
        saveScreenshot("crop-ratio-locked")
        element("edit.aspect.free").tap()
        sleep(1)
        XCTAssertEqual(crop().aspect, "free")
        before = sides(crop())
        drag(CGVector(dx: before[2], dy: mid(before).y), CGVector(dx: before[2] - 0.1, dy: mid(before).y))
        after = sides(crop())
        XCTAssertEqual(changed(before, after), [false, false, true, false], "Free: the right edge alone")
        saveScreenshot("crop-free-again")

        // Rotate and straighten, then crop.
        element("edit.sub.Rotate").tap()
        element("edit.rotateRight").tap()
        element("edit.sub.Straighten").tap()
        let angle = app.sliders["slider.angle"]
        if angle.waitForExistence(timeout: 5) { angle.adjust(toNormalizedSliderPosition: 0.43) }
        element("edit.sub.Crop").tap()
        sleep(2)
        saveScreenshot("crop-after-rotate-straighten")
        before = sides(crop())
        drag(CGVector(dx: before[0], dy: before[1]), CGVector(dx: before[0] + 0.1, dy: before[1] + 0.08))
        after = sides(crop())
        XCTAssertEqual(changed(before, after), [true, true, false, false], "top-left after rotation: \(before) → \(after)")
        saveScreenshot("crop-after-rotate-straighten-cropped")
        element("edit.sub.Rotate").tap()
        sleep(2)
        saveScreenshot("crop-result-shown")
    }

    /// Owner check 2026-10-05: Cancel → leave the tool → reopen → retry. Cancel returns to the panel (no indicator),
    /// navigation works, reopening does not restart the analysis, and the next Background edit does.
    func testBackgroundCancelLeaveReopenRetry() {
        let mattes = "\(EditorCaptureUITests.repositoryRoot)/ios/Tests/Fixtures/SubjectMattes/portrait_medium_02.png"
        relaunch(arguments: ["--reset-preferences", "--slow-subject-matte", "--open-photo", photoPath("portrait_medium_02"),
                             "--subject-matte-fixture", mattes])
        XCTAssertTrue(element("develop.ruler").waitForExistence(timeout: timeout), "editor did not open")
        element("tool.background").tap()
        XCTAssertTrue(element("background.cancel").waitForExistence(timeout: timeout), "Finding the subject… with Cancel")
        saveScreenshot("cancel-1-finding")
        element("background.cancel").tap()
        XCTAssertTrue(waitFor { !self.element("background.cancel").exists && !self.element("background.separating").exists },
                      "the indicator clears")
        XCTAssertTrue(element("slider.blur").waitForExistence(timeout: timeout), "back to the Focus & Blur controls")
        saveScreenshot("cancel-2-panel")

        element("tool.develop").tap()
        XCTAssertTrue(element("develop.ruler").waitForExistence(timeout: timeout), "navigation works")
        element("tool.background").tap()
        sleep(2)
        XCTAssertFalse(element("background.cancel").exists, "reopening does not restart the cancelled analysis")
        XCTAssertTrue(element("slider.blur").exists)
        saveScreenshot("cancel-3-reopened")

        element("background.mode.change").tap()
        let image = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'background.image.' AND identifier != 'background.image.add'")).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: timeout))
        image.tap()
        XCTAssertTrue(element("background.cancel").waitForExistence(timeout: timeout), "the next edit retries the analysis")
        saveScreenshot("cancel-4-retrying")
        XCTAssertTrue(waitFor(timeout: 60) { !self.element("background.cancel").exists }, "and it finishes")
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled)
        sleep(2)
        saveScreenshot("cancel-5-replaced")
    }

    /// Owner check 2026-10-05: Straighten moved explicitly, then a free crop, then Save copy (to Documents, pulled
    /// and compared with the preview on the host). Writes the photo's frame next to the screenshots.
    func testStraightenThenFreeCropThenSave() throws {
        relaunch(arguments: ["--reset-preferences", "--expose-crop", "--save-to-documents", "straighten-crop.jpg",
                             "--open-photo", photoPath("landscape_02")])
        XCTAssertTrue(element("develop.ruler").waitForExistence(timeout: timeout), "editor did not open")
        element("tool.edit").tap()
        element("edit.sub.Straighten").tap()
        let angle = element("slider.angle")
        XCTAssertTrue(angle.waitForExistence(timeout: timeout))
        // The track runs between the label ("Angle", 18 pt inset + ~45 pt + 12 pt) and the value (12 + 36 + 18 pt).
        let row = angle.frame
        let trackStart = 75.0, trackEnd = row.width - 66
        let centre = angle.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: (trackStart + trackEnd) / 2, dy: row.height / 2))
        centre.press(forDuration: 0.1, thenDragTo: centre.withOffset(CGVector(dx: (trackEnd - trackStart) * 0.1, dy: 0)))
        let degrees = Int(angle.value as? String ?? "") ?? 0
        XCTAssertTrue((5...15).contains(degrees), "Straighten moved: \(String(describing: angle.value))")
        saveScreenshot("straighten-1-angle")
        element("edit.sub.Crop").tap()
        let photo = element("editor.photo")
        func drag(_ from: CGVector, _ to: CGVector) {
            photo.coordinate(withNormalizedOffset: from)
                .press(forDuration: 0.15, thenDragTo: photo.coordinate(withNormalizedOffset: to), withVelocity: .slow, thenHoldForDuration: 0.1)
            sleep(1)
        }
        drag(CGVector(dx: 0.01, dy: 0.01), CGVector(dx: 0.25, dy: 0.1))
        drag(CGVector(dx: 0.99, dy: 0.99), CGVector(dx: 0.85, dy: 0.7))
        let crop = element("edit.cropRect").value as? String ?? ""
        XCTAssertTrue(crop.hasPrefix("free "), crop)
        saveScreenshot("straighten-2-cropping")
        // A sub-tool without marks shows the cropped result as it will be saved.
        element("edit.sub.Rotate").tap()
        sleep(2)
        saveScreenshot("straighten-3-preview")
        if let directory = ProcessInfo.processInfo.environment["LIGHTLY_VERIFY_DIR"] {
            let f = element("editor.photo").frame
            let scale = Double(XCUIScreen.main.screenshot().image.size.width > 0 ? XCUIScreen.main.screenshot().image.scale : 3)
            try "\(f.minX * scale) \(f.minY * scale) \(f.width * scale) \(f.height * scale) \(crop)"
                .write(toFile: "\(directory)/straighten-3-preview.frame", atomically: true, encoding: .utf8)
        }
        app.buttons["editor.saveCopy"].tap()
        XCTAssertTrue(app.staticTexts["Saved as a new photo"].waitForExistence(timeout: 120), "no Saved sheet")
        saveScreenshot("straighten-4-saved")
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
        XCTAssertFalse(element("watermark.place.photo").exists)
        XCTAssertFalse(element("watermark.place.border").exists)
        XCTAssertFalse(element("watermark.position").exists)
        let photo = element("editor.photo")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
            .press(forDuration: 0.1, thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)))
        app.buttons["editor.undo"].tap()
        XCTAssertEqual(element("tool.watermark").value as? String, "Edited")
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


/// Inspection uses the ordinary editor, without changing its recipe or owner session.
final class InspectionZoomUITests: XCTestCase {
    func testZoomSurvivesRenderAndToolChangeAndReturnsToFit() {
        let app = XCUIApplication()
        app.launchArguments = ["--keep-stored-session", "--session-store", "inspection-test", "--open-photo",
            "/Users/sg/Documents/Dev/Projects/lightly/experiments/lut3d/photos/portrait_medium_02.jpg", "--scenario", "dev-preset"]
        app.launch()
        let viewport = app.scrollViews["editor.inspection"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 60))
        let photo = app.descendants(matching: .any)["editor.photo"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        let fit = photo.frame
        let undo = app.buttons["editor.undo"].isEnabled
        viewport.pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(wait { photo.frame.width > fit.width * 1.5 })
        XCTAssertEqual(app.buttons["editor.undo"].isEnabled, undo, "Inspection must not create an edit")
        let auto = app.buttons["develop.auto"]
        let autoSize = auto.frame.size
        auto.tap()
        XCTAssertTrue(wait { photo.frame.width > fit.width * 1.5 })
        XCTAssertEqual(auto.frame.size, autoSize, "Auto chrome must not magnify")
        let scale = viewport.value as? String
        app.buttons["tool.effects"].tap()
        XCTAssertTrue(wait { viewport.value as? String == scale })
        app.buttons["tool.develop"].tap()
        XCTAssertTrue(wait { viewport.value as? String == scale })
        // Return to fit is reversible and does not require leaving the tool.
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(wait { abs(photo.frame.width - fit.width) < 2 })
    }
    private func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline { if condition() { return true }; Thread.sleep(forTimeInterval: 0.1) }
        return condition()
    }
}


final class SliderHitTargetUITests: XCTestCase {
    func testDevelopResetAndFavouritesStartAtFirstPreset() {
        let app = XCUIApplication()
        app.launchArguments = ["--keep-stored-session", "--session-store", "develop-reset-favourites", "--open-photo",
            "/Users/sg/Documents/Dev/Projects/lightly/experiments/lut3d/photos/portrait_medium_02.jpg", "--scenario", "dev-starred"]
        app.launch()
        let reset = app.buttons["develop.clear"]
        XCTAssertTrue(reset.waitForExistence(timeout: 60))
        XCTAssertEqual(reset.label, "Reset preset")
        let categoryY = app.buttons["develop.category.landscape"].frame.midY / app.frame.height
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: categoryY))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: categoryY)))
        app.buttons["develop.category.favourites"].tap()
        XCTAssertTrue(app.buttons["develop.apply"].exists)
        XCTAssertTrue(app.staticTexts["develop.position"].label.hasPrefix("1 / "))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "favourites-first-and-reset"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["develop.apply"].tap()
        XCTAssertFalse(app.buttons["develop.apply"].exists)
        reset.tap()
        XCTAssertFalse(reset.exists)
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(reset.waitForExistence(timeout: 10))
    }

    func testResetAllDarkThemeOnDarkPhoto() {
        let app = XCUIApplication()
        app.launchArguments = ["--keep-stored-session", "--session-store", "reset-dark-test", "--open-photo",
            "/Users/sg/Documents/Dev/Projects/lightly/experiments/lut3d/photos/portrait_deep_03.jpg", "--scenario", "fx-leak",
            "-lightly.preferences.v1.appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["editor.resetAll"].waitForExistence(timeout: 60))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "reset-dark-photo-controls"; shot.lifetime = .keepAlways; add(shot)
    }

    func testResetAllOnPhotoConfirmsAndUndoRestores() {
        let app = XCUIApplication()
        app.launchArguments = ["--keep-stored-session", "--session-store", "reset-ui-test", "--open-photo",
            "/Users/sg/Documents/Dev/Projects/lightly/experiments/lut3d/photos/portrait_medium_02.jpg", "--scenario", "fx-leak"]
        app.launch()
        let reset = app.buttons["editor.resetAll"]
        XCTAssertTrue(reset.waitForExistence(timeout: 60))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "reset-photo-controls"; shot.lifetime = .keepAlways; add(shot)
        reset.tap()
        app.alerts.buttons["Keep editing"].tap()
        XCTAssertTrue(reset.exists)
        reset.tap()
        app.alerts.buttons["Reset all edits"].tap()
        XCTAssertTrue(reset.waitForNonExistence(timeout: 10))
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(reset.waitForExistence(timeout: 10))
    }

    func testForceQuitFromAppSwitcherDoesNotRestorePhoto() {
        let app = XCUIApplication()
        app.launchArguments = ["--keep-stored-session", "--session-store", "force-quit-repro-20261009", "--open-photo",
            "/Users/sg/Documents/Dev/Projects/lightly/experiments/lut3d/photos/portrait_medium_02.jpg", "--scenario", "dev-preset"]
        app.launch()
        XCTAssertTrue(app.buttons["develop.clear"].waitForExistence(timeout: 60))
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.995))
        let middle = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        bottom.press(forDuration: 0.1, thenDragTo: middle, withVelocity: .slow, thenHoldForDuration: 1)
        Thread.sleep(forTimeInterval: 2)
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); before.name = "force-quit-app-switcher"; before.lifetime = .keepAlways; add(before)
        print("APP SWITCHER TREE: \(springboard.debugDescription)")
        let card = springboard.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Lightly")).firstMatch
        guard card.waitForExistence(timeout: 5) else { XCTFail("App-switcher card unavailable; force quit not exercised"); return }
        card.swipeUp()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "The real app-switcher swipe must terminate Lightly")
        app.launchArguments = ["--keep-stored-session", "--session-store", "force-quit-repro-20261009"]
        app.launch()
        let welcome = app.buttons["welcome.choosePhoto"].waitForExistence(timeout: 30)
        let after = XCTAttachment(screenshot: app.screenshot()); after.name = "after-force-quit-relaunch"; after.lifetime = .keepAlways; add(after)
        XCTAssertTrue(welcome, "Force quit must return to Welcome rather than restore the photo")
    }
    func testClearPresetAndSignatureAndNoBorderSignatureOption() {
        let app = XCUIApplication()
        let base = ["--keep-stored-session", "--session-store", "clear-actions-test", "--open-photo",
            "/Users/sg/Documents/Dev/Projects/lightly/experiments/lut3d/photos/portrait_medium_02.jpg", "--scenario"]
        app.launchArguments = base + ["dev-preset"]
        app.launch()
        let clear = app.buttons["develop.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 60))
        let presetShot = XCTAttachment(screenshot: app.screenshot()); presetShot.name = "preset-clear-control"; presetShot.lifetime = .keepAlways; add(presetShot)
        clear.tap()
        XCTAssertFalse(clear.exists)
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = base + ["wm-signature"]
        app.launch()
        let signatureClear = app.buttons["watermark.signature.clear"]
        XCTAssertTrue(signatureClear.waitForExistence(timeout: 60))
        let signatureShot = XCTAttachment(screenshot: app.screenshot()); signatureShot.name = "signature-clear-controls"; signatureShot.lifetime = .keepAlways; add(signatureShot)
        signatureClear.tap()
        XCTAssertTrue(app.buttons["watermark.signature.drawn"].exists)
        XCTAssertFalse(signatureClear.exists)
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(signatureClear.waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = base + ["bd-polaroid"]
        app.launch()
        XCTAssertTrue(app.buttons["border.type.Polaroid"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["border.polaroid.signature"].exists)
    }

    func testAdjacentEffectSlidersOwnTheirVisibleRows() {
        let app = XCUIApplication()
        app.launchArguments = ["--keep-stored-session", "--session-store", "slider-hit-test", "--open-photo",
            "/Users/sg/Documents/Dev/Projects/lightly/experiments/lut3d/photos/portrait_medium_02.jpg", "--scenario", "fx-leak"]
        app.launch()
        let top = app.descendants(matching: .any)["slider.intensity"].firstMatch
        let bottom = app.descendants(matching: .any)["slider.rotation"].firstMatch
        XCTAssertTrue(top.waitForExistence(timeout: 60))
        XCTAssertTrue(bottom.exists)
        for offset in [-10.0, 0.0, 10.0] {
            let unchanged = bottom.value as? String
            let beforeTop = top.value as? String
            let start = top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: offset))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 60, dy: 0)))
            XCTAssertEqual(bottom.value as? String, unchanged, "Upper row touch must not move Rotation; offset \(offset)")
            if offset == -10 { XCTAssertNotEqual(top.value as? String, beforeTop, "The touched slider must move") }
        }
        let unchanged = top.value as? String
        let start = bottom.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -50, dy: 0)))
        XCTAssertEqual(top.value as? String, unchanged, "Lower row must not move Intensity")
    }
}
