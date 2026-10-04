import XCTest

/// Captures every slice-2 editor screen of the running app for side-by-side comparison with the
/// approved prototype (`docs/ui/tools/shot.js`). It asserts nothing about pixels; in one launch it
/// opens the prototype's own photograph for each screen, applies the screen's state through the
/// DEBUG `--scenario` argument (DebugCaptureDriver) and saves a screenshot named after the screen id.
///
/// Runs only with `LIGHTLY_CAPTURE_DIR` set (`TEST_RUNNER_LIGHTLY_CAPTURE_DIR=<dir>`); otherwise
/// every test skips. `LIGHTLY_CAPTURE_ORIENTATION=landscape` rotates an iPad first;
/// `LIGHTLY_CAPTURE_ONLY=<id,id>` limits the run. Theme and text size come from the simulator.
final class EditorCaptureUITests: XCTestCase {

    private var app: XCUIApplication!
    private var directory: URL!

    /// Prototype photo ids (`PHOTOS` in docs/ui/app/data.js) → files under docs/ui/assets/photos.
    private static let photoFiles = [
        "lake": "docs/ui/assets/photos/landscape_02", "field": "docs/ui/assets/photos/landscape_03",
        "sunset": "docs/ui/assets/photos/sunset_02", "man": "docs/ui/assets/photos/portrait_deep_03",
        "woman": "docs/ui/assets/photos/portrait_medium_02", "smile": "docs/ui/assets/photos/portrait_deep_02",
        "bar": "docs/ui/assets/photos/night_03", "street": "docs/ui/assets/photos/wellexposed_03",
        // The licensed multi-person photo stands in for the prototype's one-face pt-multi.
        "group": "experiments/test-photos/group_three_01"
    ]

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
        ("saved", "lake", ["--fake-library-writer"], "saved.keepEditing"),
        // Slice 3.
        ("bg-focus", "woman", [], "slider.blur"),
        ("bg-soft", "woman", [], "slider.glow"),
        ("bg-swirl", "woman", [], "slider.swirl"),
        ("bg-motion", "woman", [], "slider.direction"),
        ("bg-refine", "woman", [], "background.refine.done"),
        ("bg-change-image", "woman", [], "slider.scale"),
        ("bg-change-colour", "woman", [], "background.remove"),
        ("bg-change-gradient", "woman", [], "background.remove"),
        ("bg-replaced-blur", "woman", [], "slider.blur"),
        ("bg-separating", "woman", [], "background.separating"),
        ("bg-failed", "woman", [], "background.retry"),
        ("bg-no-subject", "lake", [], "slider.blur"),
        ("pt-skin", "man", [], "slider.smoothing"),
        ("pt-under", "man", [], "slider.softenlines"),
        ("pt-eyes", "man", [], "slider.clarity"),
        ("pt-teeth", "smile", [], "slider.brighten"),
        ("pt-hair", "man", [], "slider.definition"),
        ("pt-landscape-photo", "smile", [], "slider.smoothing"),
        ("pt-multi", "group", [], "portrait.face.3"),
        ("pt-no-usable-face", "bar", [], "tool.portrait"),
        ("pt-hidden", "field", [], "develop.ruler"),
        // Slice 4.
        ("ed-crop", "lake", [], "edit.aspect.4:5"),
        ("ed-rotate", "field", [], "edit.flipHorizontal"),
        ("ed-straighten", "field", [], "slider.angle"),
        ("ed-perspective", "street", [], "slider.vertical"),
        ("ed-adjust-light", "lake", [], "slider.exposure"),
        ("ed-adjust-colour", "lake", [], "slider.temperature"),
        ("ed-adjust-detail", "lake", [], "slider.noisereduction"),
        ("ed-remove", "field", [], "edit.remove.undoStroke"),
        ("ed-removing", "field", [], "edit.removing"),
        ("ed-remove-failed", "field", [], "edit.remove.retry"),
        ("fx-leak", "sunset", [], "effects.leak.warm"),
        ("fx-grain", "lake", [], "effects.grain.film"),
        ("fx-vignette", "lake", [], "slider.softness"),
        ("fx-combined", "sunset", [], "slider.softness"),
        ("fx-preset-conflict", "lake", [], "develop.notice")
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

    /// Polls a small file every 10 ms (an NSPredicate expectation is evaluated about once a second).
    static func waitForFile(_ url: URL, toContain expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? String(contentsOf: url, encoding: .utf8)) == expected { return true }
            usleep(10_000)
        }
        return false
    }

    /// Measurement: the app's events (`--capture-timing`) and the test's own, same clock.
    private var appTimingPath: String { directory.appendingPathComponent("app-timing.log").path }

    private func mark(_ event: String, _ screen: String) {
        let line = "\(Int64(Date().timeIntervalSince1970 * 1000)) test \(event) \(screen)\n"
        let url = directory.appendingPathComponent("test-timing.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// The Simulator cannot run Vision's foreground mask; the app may stand in the matte the same
    /// request computed on macOS (ios/Tests/Fixtures/SubjectMattes, DEBUG Simulator only).
    static func matteFixtureArguments(_ photo: String) -> [String] {
        let name = URL(fileURLWithPath: photoFiles[photo]!).lastPathComponent
        let directory = "\(repositoryRoot)/ios/Tests/Fixtures/SubjectMattes"
        let png = "\(directory)/\(name).png", none = "\(directory)/\(name).none"
        if FileManager.default.fileExists(atPath: png) { return ["--subject-matte-fixture", png] }
        if FileManager.default.fileExists(atPath: none) { return ["--subject-matte-fixture", none] }
        return []
    }

    /// The tool version recorded with every capture (bump when the capture method changes).
    static let toolVersion = "editor-capture-5 (one launch per cell, app ready signal, macOS matte fixtures in the Simulator)"

    func testCaptureEditorScreens() throws {
        let only = ProcessInfo.processInfo.environment["LIGHTLY_CAPTURE_ONLY"].flatMap { $0.isEmpty ? nil : Set($0.split(separator: ",").map(String.init)) }
        let screens = Self.screens.filter { only?.contains($0.id) ?? true }
        if ProcessInfo.processInfo.environment["LIGHTLY_CAPTURE_MODE"] == "launch" {
            captureRelaunchingPerScreen(screens)
        } else {
            try captureInOneLaunch(screens)
        }
    }

    /// One launch per cell: the app's DEBUG capture driver takes each screen's arguments from a
    /// command file, closes the previous screen and waits until its work has stopped, resets
    /// preferences, favourites and caches, and opens the screen's photo. The test waits for the
    /// driver's acknowledgement, then for `capture.ready.<n>`, which the editor shows only once
    /// the screen's renders have landed and the frame is on the display. No fixed waits.
    private func captureInOneLaunch(_ screens: [(id: String, photo: String, arguments: [String], ready: String)]) throws {
        let commandFile = directory.appendingPathComponent(".capture-command")
        let acknowledgement = commandFile.appendingPathExtension("ack")
        try? FileManager.default.removeItem(at: commandFile)
        try? FileManager.default.removeItem(at: acknowledgement)
        try? FileManager.default.removeItem(at: commandFile.appendingPathExtension("ready"))
        app.launchArguments = ["--reset-preferences", "--capture-commands", commandFile.path, "--capture-timing", appTimingPath]
        mark("launch-start", "-")
        app.launch()
        mark("launch-end", "-")
        for (sequence, screen) in screens.enumerated() {
            let photo = "\(Self.repositoryRoot)/\(Self.photoFiles[screen.photo]!).jpg"
            let arguments = ["--reset-preferences", "--open-photo", photo, "--scenario", screen.id] + screen.arguments
                + Self.matteFixtureArguments(screen.photo)
            mark("command-sent", screen.id)
            try ([String(sequence)] + arguments).joined(separator: "\t").write(to: commandFile, atomically: true, encoding: .utf8)
            XCTAssertTrue(Self.waitForFile(acknowledgement, toContain: String(sequence), timeout: 60),
                          "\(screen.id): the capture driver did not open the photo")
            // The app reports readiness in `<command file>.ready`; polling a file costs
            // milliseconds, where an accessibility query is refreshed about once a second.
            XCTAssertTrue(Self.waitForFile(commandFile.appendingPathExtension("ready"), toContain: String(sequence), timeout: 90),
                          "\(screen.id): never reported ready")
            mark("ready-seen", screen.id)
            XCTAssertTrue(app.descendants(matching: .any)[screen.ready].firstMatch.exists, "\(screen.id): \(screen.ready) missing")
            mark("shot-start", screen.id)
            let data = XCUIScreen.main.screenshot().pngRepresentation
            try? data.write(to: directory.appendingPathComponent("\(screen.id).png"))
            mark("shot-end", screen.id)
        }
        app.terminate()
    }

    /// The previous method, kept only to validate the one-launch runner against it: a fresh
    /// launch per screen and fixed settle times.
    private func captureRelaunchingPerScreen(_ screens: [(id: String, photo: String, arguments: [String], ready: String)]) {
        for screen in screens {
            let photo = "\(Self.repositoryRoot)/\(Self.photoFiles[screen.photo]!).jpg"
            mark("launch-start", screen.id)
            app.terminate()
            app.launchArguments = ["--reset-preferences", "--open-photo", photo, "--scenario", screen.id] + screen.arguments
                + Self.matteFixtureArguments(screen.photo) + ["--capture-timing", appTimingPath]
            app.launch()
            mark("launch-end", screen.id)
            let ready = app.descendants(matching: .any)[screen.ready].firstMatch
            XCTAssertTrue(ready.waitForExistence(timeout: 30), "\(screen.id): \(screen.ready) missing")
            mark("ready-seen", screen.id)
            Thread.sleep(forTimeInterval: screen.id == "saved" ? 1.5 : screen.id.hasPrefix("bg-") || screen.id.hasPrefix("pt-") ? 8 : 2.5)
            mark("shot-start", screen.id)
            let data = XCUIScreen.main.screenshot().pngRepresentation
            try? data.write(to: directory.appendingPathComponent("\(screen.id).png"))
            mark("shot-end", screen.id)
        }
    }
}
