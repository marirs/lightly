import XCTest

/// The owner amendments of 2026-10-11 (both) in the running app: double tap on empty space cycles the theme (Welcome, More,
/// the editor stage outside the photo, never the photo), and the Text tool's add → type → Done → drag flow.
final class OwnerAmendmentsUITests: XCTestCase {

    private var app: XCUIApplication!
    private let timeout: TimeInterval = 30

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ arguments: [String]) {
        app.launchArguments = arguments
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func photoPath(_ name: String) -> String {
        "\(EditorCaptureUITests.repositoryRoot)/docs/ui/assets/photos/\(name).jpg"
    }

    /// Double taps the window at a point given in fractions of the screen.
    private func doubleTapScreen(x: CGFloat, y: CGFloat) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).doubleTap()
    }

    /// The toast's text once it shows ("" if none showed).
    private func toastText() -> String {
        let toast = element("editor.toast")
        return toast.waitForExistence(timeout: 3) ? toast.label : ""
    }

    private func waitForToastToGo() {
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: element("editor.toast"))
        waitForExpectations(timeout: 5)
    }

    func testDoubleTapOnEmptySpaceCyclesTheTheme() {
        launch(["--reset-preferences"])
        XCTAssertTrue(app.buttons["welcome.choosePhoto"].waitForExistence(timeout: timeout))
        // Welcome: the empty top-leading corner beside ⋮ More.
        doubleTapScreen(x: 0.2, y: 0.09)
        XCTAssertEqual(toastText(), "Light theme")
        waitForToastToGo()
        doubleTapScreen(x: 0.2, y: 0.09)
        XCTAssertEqual(toastText(), "Dark theme")
        waitForToastToGo()

        // More shows the same preference, and its own empty space cycles it on.
        app.buttons["welcome.more"].tap()
        XCTAssertTrue(element("appearance.dark").waitForExistence(timeout: timeout))
        XCTAssertTrue(element("appearance.dark").isSelected, "the cycle wrote More › Appearance")
        let title = element("more.page.menu")
        title.coordinate(withNormalizedOffset: CGVector(dx: 2.2, dy: 0.5)).doubleTap()
        XCTAssertEqual(toastText(), "System theme")
        XCTAssertTrue(element("appearance.system").isSelected)
        app.buttons["page.close"].tap()

        // The editor: outside the photo cycles, the photo itself does not (it keeps its zoom).
        app.terminate()
        launch(["--fake-library-writer", "--open-photo", photoPath("landscape_02")])
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout))
        let stage = element("editor.inspection"), photo = element("editor.photo")
        XCTAssertTrue(stage.waitForExistence(timeout: timeout))
        XCTAssertGreaterThan(photo.frame.minX - stage.frame.minX, 20, "a tall photo leaves stage space at its sides")
        stage.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).doubleTap()
        XCTAssertEqual(toastText(), "Light theme", "the preference persisted across the relaunch (System → Light)")
        waitForToastToGo()
        // The photo keeps its inspection zoom (it zooms in, and then fills the stage) and never cycles the theme.
        photo.doubleTap()
        XCTAssertEqual(toastText(), "", "a double tap on the photo never changes the theme")
        let zoom = element("editor.inspection")
        XCTAssertTrue(waitFor { (zoom.value as? String).map { $0 != "1.0 times" } ?? false }, "the photo zoomed instead: \(zoom.value ?? "nil")")
    }

    func testTextToolAddTypeDoneAndDrag() {
        launch(["--reset-preferences", "--fake-library-writer", "--open-photo", photoPath("landscape_03")])
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout))
        let tool = element("tool.text")
        XCTAssertTrue(tool.exists, "Text is in the dock")
        tool.tap()
        let add = element("text.add")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled)

        // Add → the sheet with the keyboard below the field; Done waits for words.
        add.tap()
        let field = element("text.sheet.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertLessThan(field.frame.maxY, app.keyboards.firstMatch.frame.minY, "the keyboard never covers the field")
        let done = element("text.sheet.done")
        XCTAssertFalse(done.isEnabled, "Done is off while the text is blank")
        field.typeText("Summer")
        XCTAssertTrue(done.isEnabled)
        done.tap()

        let chip = element("text.layer.1")
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        XCTAssertEqual(chip.label, "Summer")
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled, "adding is one step")
        XCTAssertEqual(element("tool.text").value as? String, "Edited")
        let handle = element("text.handle")
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "the selected text shows its handles")
        XCTAssertTrue(element("text.delete").exists)

        // Drag inside the text (it starts at the photo's centre): it follows the finger; one undo step.
        let before = handle.frame
        let photo = element("editor.photo")
        let start = photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 50, dy: -40)))
        XCTAssertTrue(waitFor { abs(handle.frame.midX - before.midX - 50) < 8 && abs(handle.frame.midY - before.midY + 40) < 8 },
                      "moved: \(before) → \(handle.frame)")
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(waitFor { abs(handle.frame.midX - before.midX) < 3 && abs(handle.frame.midY - before.midY) < 3 },
                      "Undo returns the text in one step")
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled, "the add is still there to undo")

        // The corner handle (owner report 2026-10-11): visible and hittable, and dragging it away from the centre
        // enlarges the text as one undo step, the handle following the finger.
        // (`isHittable` is not used: XCUITest reports it false for elements hosted inside the photo's zoom view.)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(handle.frame), "the whole handle is on screen: \(handle.frame)")
        let handleBefore = handle.frame
        let grip = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.press(forDuration: 0.1, thenDragTo: grip.withOffset(CGVector(dx: 40, dy: 20)))
        XCTAssertTrue(waitFor { handle.frame.midX > handleBefore.midX + 20 }, "resized: \(handleBefore) → \(handle.frame)")
        keep("tx-resized")
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(waitFor { abs(handle.frame.midX - handleBefore.midX) < 3 && abs(handle.frame.midY - handleBefore.midY) < 3 },
                      "Undo returns the size in one step")

        // ✕ deletes the layer: the panel goes back to Add text.
        element("text.delete").tap()
        XCTAssertTrue(element("text.add").waitForExistence(timeout: 5))
        XCTAssertFalse(element("text.handle").exists)
    }

    /// Owner report 2026-10-11: on a photo with no clear subject, the panel shows the approved `bg-no-subject` state:
    /// the notice and the Blur slider. Owner amendment 2026-10-11 (second): Focus & Blur is the tab shown, and Change
    /// background is greyed out and cannot be chosen.
    func testNoSubjectGreysChangeBackgroundAndShowsTheNoticeAndBlur() {
        launch(["--reset-preferences", "--fake-library-writer", "--open-photo", photoPath("landscape_02")]
               + EditorCaptureUITests.matteFixtureArguments("lake"))
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout))
        element("tool.background").tap()
        let notice = element("panel.notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 60), "the no-subject notice shows")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'No clear subject found.'")).firstMatch.exists,
                      "the approved copy")
        XCTAssertTrue(element("slider.blur").exists)
        let focus = element("background.mode.focus"), change = element("background.mode.change")
        XCTAssertTrue(focus.isSelected, "Focus & Blur is the tab shown")
        XCTAssertFalse(change.isEnabled, "Change background is greyed out")
        keep("bg-no-subject")
        change.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(focus.isSelected, "tapping the greyed tab changes nothing")
        XCTAssertFalse(change.isSelected)
        XCTAssertTrue(notice.exists)
        XCTAssertTrue(element("slider.blur").exists, "Blur still works")
        XCTAssertFalse(element("background.kind.Image").exists, "Change background's options are not offered")
        XCTAssertFalse(element("background.image.add").exists)
    }

    /// Owner amendment 2026-10-11 (second) in the Text panel: the smaller lime "Add text" pill at the leading edge, and
    /// the Thin · Regular · Bold row (one undo step; a single-weight font greys Thin and Bold).
    func testAddTextPillAndWeightRow() {
        launch(["--reset-preferences", "--fake-library-writer", "--open-photo", photoPath("sunset_02")])
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout))
        element("tool.text").tap()
        let add = element("text.add")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertEqual(add.frame.height, 40, accuracy: 1, "40 pt pill")
        XCTAssertLessThan(add.frame.width, app.windows.firstMatch.frame.width / 2, "not full width")
        XCTAssertLessThan(add.frame.minX, 40, "at the leading edge")
        keep("tx-empty")
        add.tap()
        let field = element("text.sheet.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Summer in Lisbon")
        element("text.sheet.done").tap()

        let thin = element("text.weight.thin"), regular = element("text.weight.regular"), bold = element("text.weight.bold")
        XCTAssertTrue(regular.waitForExistence(timeout: 5))
        XCTAssertTrue(regular.isSelected, "new text is regular")
        XCTAssertEqual(regular.frame.height, 36, accuracy: 1)
        XCTAssertGreaterThan(thin.frame.minY, element("text.font.Inter").frame.maxY, "below the fonts row")
        bold.tap()
        XCTAssertTrue(waitFor { bold.isSelected })
        keep("tx-bold")
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(waitFor { regular.isSelected }, "one undo step")

        // A single-weight font: Thin and Bold greyed and not selectable.
        let bebas = element("text.font.Bebas Neue")
        bebas.tap()
        XCTAssertTrue(waitFor { !thin.isEnabled && !bold.isEnabled })
        XCTAssertTrue(regular.isEnabled && regular.isSelected)
        keep("tx-single")

        // The three new fonts follow Space Mono.
        for name in ["Retro Romance", "Velomino", "Vectipede Thin"] {
            XCTAssertTrue(element("text.font.\(name)").exists, name)
        }
        XCTAssertGreaterThan(element("text.font.Retro Romance").frame.minX, element("text.font.Space Mono").frame.minX)
    }

    /// Owner amendment 2026-10-11 (second): Change background › Image in two rows, column by column, "+" last; (third)
    /// the tiles fill the row, four across.
    func testBackgroundImagesInTwoRowsWithChooseAPhotoLast() {
        launch(["--reset-preferences", "--fake-library-writer", "--open-photo", photoPath("portrait_medium_02")]
               + EditorCaptureUITests.matteFixtureArguments("woman"))
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout))
        element("tool.background").tap()
        let change = element("background.mode.change")
        XCTAssertTrue(change.waitForExistence(timeout: timeout))
        change.tap()
        let add = element("background.image.add")
        XCTAssertTrue(add.waitForExistence(timeout: 60))
        let first = element("background.image.landscape_01"), second = element("background.image.sunset_03")
        let third = element("background.image.wellexposed_02"), last = element("background.image.wellexposed_03")
        XCTAssertEqual(second.frame.minX, first.frame.minX, accuracy: 1, "column-major: the second tile under the first")
        XCTAssertEqual(second.frame.minY - first.frame.maxY, 10, accuracy: 1, "10 pt between rows")
        XCTAssertEqual(third.frame.minX - first.frame.maxX, 8, accuracy: 1, "8 pt between columns")
        // Owner amendment 2026-10-11 (third): four across fill the row, (grid width − 3 × 8) / 4, the grid 2 pt inside.
        let grid = element("background.images")
        XCTAssertEqual(first.frame.width, (grid.frame.width - 4 - 24) / 4, accuracy: 1)
        XCTAssertEqual(first.frame.height, first.frame.width, accuracy: 1, "square")
        XCTAssertEqual(add.frame.maxX, grid.frame.maxX - 2, accuracy: 1, "the fourth column ends at the row's end")
        XCTAssertEqual(add.frame.minX, last.frame.minX, accuracy: 1, "+ shares the last column")
        XCTAssertGreaterThan(add.frame.minY, last.frame.minY, "+ is the last tile")
        keep("bg-image-two-rows")
    }

    /// Owner amendment 2026-10-11 (third): Effects › Light Leaks is a two-row gallery, None first and chosen while the
    /// effect is off; choosing a leak turns it on (one undo step), None turns it off; a drag with None does nothing.
    func testLightLeakGallery() {
        launch(["--reset-preferences", "--fake-library-writer", "--open-photo", photoPath("sunset_02")])
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout))
        element("tool.effects").tap()
        let none = element("effects.leak.none")
        XCTAssertTrue(none.waitForExistence(timeout: timeout))
        XCTAssertTrue(none.isSelected, "off: None is chosen")
        XCTAssertFalse(element("effects.leak.warm").exists, "the four style chips are gone")
        // With None chosen, dragging on the photo does nothing (rendering-v2 revision 8, 080003a).
        let photo = element("editor.photo")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        XCTAssertTrue(none.isSelected, "a drag with None chosen turns nothing on")
        XCTAssertNotEqual(element("tool.effects").value as? String, "Edited")
        let first = element("effects.leak.leak-edf0a0ecd85d"), second = element("effects.leak.leak-fc36430bd1c4")
        guard first.waitForExistence(timeout: 5) else {
            XCTFail("no leak tiles: was the app built without shared/leaks/out?"); return
        }
        XCTAssertEqual(none.frame.width, 96, accuracy: 1)
        XCTAssertEqual(first.frame.minX, none.frame.minX, accuracy: 1, "column-major: the first leak under None")
        XCTAssertGreaterThan(first.frame.minY, none.frame.maxY)
        XCTAssertEqual(second.frame.minX - none.frame.maxX, 12, accuracy: 1, "12 pt between columns")
        XCTAssertEqual(first.label, "Gold Fringe")
        first.tap()
        XCTAssertTrue(waitFor { first.isSelected })
        XCTAssertFalse(none.isSelected)
        XCTAssertEqual(element("tool.effects").value as? String, "Edited")
        keep("fx-leak-gallery")
        none.tap()
        XCTAssertTrue(waitFor { none.isSelected })
        XCTAssertNotEqual(element("tool.effects").value as? String, "Edited")
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(waitFor { first.isSelected }, "undo brings the leak back")
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(waitFor { none.isSelected }, "one undo step per choice")
    }

    /// Owner amendment 2026-10-11 (second): Watermark › Text has thirteen fonts, the seven signature scripts after Lora,
    /// and the row scrolls to the chosen one.
    func testWatermarkSignatureFonts() {
        launch(["--reset-preferences", "--fake-library-writer", "--open-photo", photoPath("sunset_02")])
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout))
        element("tool.watermark").tap()
        XCTAssertTrue(element("watermark.type.Text").waitForExistence(timeout: timeout))
        element("watermark.type.Text").tap()
        XCTAssertTrue(element("watermark.font.Lora").waitForExistence(timeout: timeout))
        let names = ["Carpenters", "Sourdough Script", "Jaybird", "Astoria", "Bonskin", "Shareit", "Monttee"]
        for name in names { XCTAssertTrue(element("watermark.font.\(name)").exists, name) }
        XCTAssertGreaterThan(element("watermark.font.Carpenters").frame.minX, element("watermark.font.Lora").frame.minX)
        // Choose Carpenters by scrolling the row to it: it then stays in view with Lora at the leading edge.
        let row = element("watermark.font.Lora")
        for _ in 0..<4 where !app.windows.firstMatch.frame.contains(element("watermark.font.Carpenters").frame) {
            let grip = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            grip.press(forDuration: 0.05, thenDragTo: grip.withOffset(CGVector(dx: -160, dy: 0)))
        }
        element("watermark.font.Carpenters").tap()
        XCTAssertTrue(waitFor { self.element("watermark.font.Carpenters").isSelected })
        Thread.sleep(forTimeInterval: 1)
        keep("wm-text-carpenters")
    }

    /// Screenshots of the amended screens for side-by-side review with the mockup (pt-smile, tx-*, dock-*, pill tabs),
    /// kept as attachments of the result bundle. It asserts only that each state was reached.
    func testCaptureAmendedScreens() {
        launch(["--reset-preferences", "--fake-library-writer", "--open-photo", photoPath("sunset_02")])
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout))
        Thread.sleep(forTimeInterval: 2)
        keep("dock-start-develop-tabs")
        element("tool.text").tap()
        XCTAssertTrue(element("text.add").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        keep("tx-empty")
        element("text.add").tap()
        let field = element("text.sheet.field")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Summer in Lisbon")
        keep("tx-edit")
        element("text.sheet.done").tap()
        XCTAssertTrue(element("text.handle").waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        keep("tx-selected")
        element("text.addMore").tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("2026")
        element("text.sheet.done").tap()
        element("text.font.Bebas Neue").tap()
        Thread.sleep(forTimeInterval: 2)
        keep("tx-two")
        element("tool.edit").tap()
        Thread.sleep(forTimeInterval: 1)
        keep("edit-pill-tabs")
        app.terminate()
        launch(["--reset-preferences", "--fake-library-writer", "--open-photo", photoPath("portrait_deep_02")])
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout))
        XCTAssertTrue(element("tool.portrait").waitForExistence(timeout: timeout))
        element("tool.portrait").tap()
        let smile = element("portrait.tab.Smile")
        XCTAssertTrue(smile.waitForExistence(timeout: timeout))
        smile.tap()
        Thread.sleep(forTimeInterval: 1)
        keep("pt-smile")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).doubleTap()
        Thread.sleep(forTimeInterval: 0.5)
        keep("theme-cycle-toast")
        Thread.sleep(forTimeInterval: 2)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).doubleTap()
        Thread.sleep(forTimeInterval: 2)
        keep("pt-smile-dark")
    }

    private func keep(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }
}
