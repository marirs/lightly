import XCTest

/// The owner amendments of 2026-10-11 in the running app: double tap on empty space cycles the theme (Welcome, More,
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

        // ✕ deletes the layer: the panel goes back to Add text.
        element("text.delete").tap()
        XCTAssertTrue(element("text.add").waitForExistence(timeout: 5))
        XCTAssertFalse(element("text.handle").exists)
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
