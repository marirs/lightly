import XCTest

/// Diagnostic: dumps the element tree of the system photo picker.
///
/// Kept in the suite because the picker is out-of-process and its hierarchy
/// changes between iOS releases; when the flow test stops finding photos, this
/// is how to find out what it looks like now.
final class PickerDiagnostics: XCTestCase {

    func testDumpPickerHierarchy() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Lightly"].waitForExistence(timeout: 20))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Photo Library"].waitForExistence(timeout: 20))
        app.staticTexts["Photo Library"].tap()

        // Give the out-of-process picker time to present.
        _ = app.otherElements.firstMatch.waitForExistence(timeout: 8)

        let report = """
        ===== APP UNDER TEST =====
        \(app.debugDescription)

        ===== COUNTS (app) =====
        images: \(app.images.count)
        cells: \(app.cells.count)
        buttons: \(app.buttons.count)
        collectionViews: \(app.collectionViews.count)
        scrollViews: \(app.scrollViews.count)
        """

        let attachment = XCTAttachment(string: report)
        attachment.name = "picker-hierarchy"
        attachment.lifetime = .keepAlways
        add(attachment)

        if let directory = ProcessInfo.processInfo.environment["LIGHTLY_UI_TEST_OUTPUT"] {
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("picker-hierarchy.txt")
            try? report.write(to: url, atomically: true, encoding: .utf8)

            let shot = XCUIScreen.main.screenshot()
            try? shot.pngRepresentation.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("picker.png")
            )
        }
    }
}
