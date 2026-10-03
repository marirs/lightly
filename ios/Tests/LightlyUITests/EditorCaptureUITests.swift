import XCTest

/// Captures every slice-2 editor screen of the running app for side-by-side comparison with the
/// approved prototype (`docs/ui/tools/shot.js`). It asserts nothing about pixels; it opens the
/// prototype's own photograph for each screen, applies the screen's state through the DEBUG
/// `--scenario` argument and saves a screenshot named after the screen id.
///
/// Runs only with `LIGHTLY_CAPTURE_DIR` set (`TEST_RUNNER_LIGHTLY_CAPTURE_DIR=<dir>`); otherwise
/// every test skips. `LIGHTLY_CAPTURE_ORIENTATION=landscape` rotates an iPad first;
/// `LIGHTLY_CAPTURE_ONLY=<id,id>` limits the run. Theme and text size come from the simulator.
final class EditorCaptureUITests: XCTestCase {

    private var app: XCUIApplication!
    private var directory: URL!

    /// Prototype photo ids (`PHOTOS` in docs/ui/app/data.js) → files under docs/ui/assets/photos.
    private static let photoFiles = ["lake": "landscape_02", "field": "landscape_03", "sunset": "sunset_02", "man": "portrait_deep_03"]

    /// Screen id → (photo, extra launch arguments, element to wait for).
    private static let screens: [(id: String, photo: String, arguments: [String], ready: String)] = [
        ("loading", "lake", ["--hold-phase", "opening"], "loading.opening"),
        ("developing", "lake", ["--hold-phase", "developing"], "loading.developing"),
        ("model-unavailable", "lake", [], "develop.ruler"),
        ("develop-failed", "lake", ["--auto-fails"], "develop.auto.retry"),
        ("dev-original", "lake", [], "develop.ruler"),
        ("dev-preset", "lake", [], "develop.ruler"),
        ("dev-dragging", "lake", [], "develop.ruler.fine"),
        ("dev-browse", "lake", [], "develop.ruler"),
        ("dev-large", "lake", [], "develop.ruler"),
        ("dev-long-name", "field", [], "develop.ruler"),
        ("dev-amount", "lake", [], "develop.amount.done"),
        ("dev-starred", "lake", [], "develop.ruler"),
        ("dev-favourites", "man", [], "develop.ruler"),
        ("dev-fav-full", "lake", [], "develop.favourites.replace"),
        ("dev-fav-replace", "lake", [], "replace.cancel"),
        ("dev-bw", "man", [], "develop.ruler"),
        ("dev-landscape-photo", "sunset", [], "develop.ruler"),
        ("dev-portrait-photo", "man", [], "develop.ruler"),
        ("compare", "lake", [], "editor.originalBadge"),
        ("saving", "lake", ["--slow-library-writer"], "saving.cancel"),
        ("saved", "lake", ["--fake-library-writer"], "saved.keepEditing")
    ]

    static var repositoryRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // ios/
            .deletingLastPathComponent().path
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let path = ProcessInfo.processInfo.environment["LIGHTLY_CAPTURE_DIR"] else {
            throw XCTSkip("Design captures run only with LIGHTLY_CAPTURE_DIR set.")
        }
        directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCUIDevice.shared.orientation = ProcessInfo.processInfo.environment["LIGHTLY_CAPTURE_ORIENTATION"] == "landscape"
            ? .landscapeLeft : .portrait
        app = XCUIApplication()
    }

    func testCaptureEditorScreens() {
        let only = ProcessInfo.processInfo.environment["LIGHTLY_CAPTURE_ONLY"].flatMap { $0.isEmpty ? nil : Set($0.split(separator: ",").map(String.init)) }
        for screen in Self.screens where only?.contains(screen.id) ?? true {
            let photo = "\(Self.repositoryRoot)/docs/ui/assets/photos/\(Self.photoFiles[screen.photo]!).jpg"
            app.terminate()
            app.launchArguments = ["--reset-preferences", "--open-photo", photo, "--scenario", screen.id] + screen.arguments
            app.launch()
            let ready = app.descendants(matching: .any)[screen.ready].firstMatch
            XCTAssertTrue(ready.waitForExistence(timeout: 30), "\(screen.id): \(screen.ready) missing")
            // Let renders (spatial stages included) and presentation settle.
            Thread.sleep(forTimeInterval: screen.id == "saved" ? 1.5 : 2.5)
            let data = XCUIScreen.main.screenshot().pngRepresentation
            try? data.write(to: directory.appendingPathComponent("\(screen.id).png"))
        }
    }
}
