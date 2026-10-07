import XCTest

/// The expected VoiceOver route (2026-10-07): for each screen of the owner's spoken check, the accessibility elements
/// in tree order with their label, traits and identifier, written to /tmp/lightly-a11y/voiceover-route-<screen>.txt.
/// Tree order is what VoiceOver's swipe order normally follows; this records expectations only. Whether VoiceOver
/// actually speaks them in this order, and nothing is missed or misread, is established only by a person listening.
final class VoiceOverRouteUITests: XCTestCase {
    private static let output = URL(fileURLWithPath: "/tmp/lightly-a11y")

    override func setUp() { continueAfterFailure = true }

    private func dump(_ app: XCUIApplication, _ screen: String) throws {
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        let text = app.debugDescription
        try text.write(to: Self.output.appendingPathComponent("voiceover-route-\(screen).txt"), atomically: true, encoding: .utf8)
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-preferences", "--fake-library-writer"] + arguments
        app.launch()
        return app
    }

    func testRecordTheExpectedRoute() throws {
        let welcome = launch([])
        XCTAssertTrue(welcome.buttons["welcome.choosePhoto"].waitForExistence(timeout: 30))
        try dump(welcome, "1-welcome")
        welcome.terminate()

        let photo = "\(EditorCaptureUITests.repositoryRoot)/\(EditorCaptureUITests.photoFiles["woman"]!).jpg"
        let develop = launch(["--open-photo", photo, "--scenario", "dev-preset"] + EditorCaptureUITests.matteFixtureArguments("woman"))
        XCTAssertTrue(develop.descendants(matching: .any)["develop.ruler"].waitForExistence(timeout: 40))
        try dump(develop, "2-develop")
        develop.buttons["editor.saveCopy"].tap()
        XCTAssertTrue(develop.descendants(matching: .any)["saved.title"].waitForExistence(timeout: 60))
        try dump(develop, "3-saved")
        develop.terminate()

        let remove = launch(["--open-photo", photo, "--scenario", "ed-remove"] + EditorCaptureUITests.matteFixtureArguments("woman"))
        XCTAssertTrue(remove.descendants(matching: .any)["edit.sub.Remove"].waitForExistence(timeout: 60))
        try dump(remove, "4-edit-remove")
        remove.terminate()
    }
}
