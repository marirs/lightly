import XCTest

/// A11 accessibility pass (completion plan, 2026-10-07): Xcode's accessibility audit (labels, hit regions, clipped text,
/// Dynamic Type, contrast, element traits) on the main screens at the default size and the largest accessibility size,
/// with every issue written to /tmp/lightly-a11y/<device>.json for review. The audit test records; it does not fail on
/// issues, so one run lists them all. The tablet test checks the top bar against the system status bar and Save copy's
/// hit area (M2: drawn from the approved 24 pt, the top 6 pt of the top-bar buttons fell in iPadOS's 32 pt status strip
/// and did not take taps, so M2 stays an owner decision).
final class AccessibilityAuditUITests: XCTestCase {
    private static let output = URL(fileURLWithPath: "/tmp/lightly-a11y")
    private let timeout: TimeInterval = 40

    /// (screen id, photo, element that signals the screen is ready); "welcome" and "more" need no photo.
    private static let screens: [(id: String, photo: String?, ready: String)] = [
        ("welcome", nil, "welcome.choosePhoto"),
        ("more", nil, "welcome.choosePhoto"),
        ("dev-preset", "lake", "develop.ruler"),
        ("dev-amount", "lake", "develop.amount.done"),
        ("ed-crop", "lake", "edit.aspect.4:5"),
        ("ed-adjust-light", "lake", "slider.exposure"),
        ("bg-change-colour", "woman", "background.remove"),
    ]

    private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUp() { continueAfterFailure = true }

    private func launch(_ screen: (id: String, photo: String?, ready: String), extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["--reset-preferences"]
        if let photo = screen.photo {
            let path = "\(EditorCaptureUITests.repositoryRoot)/\(EditorCaptureUITests.photoFiles[photo]!).jpg"
            arguments += ["--open-photo", path, "--scenario", screen.id] + EditorCaptureUITests.matteFixtureArguments(photo)
        }
        app.launchArguments = arguments + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)[screen.ready].waitForExistence(timeout: timeout), "\(screen.id) not ready")
        if screen.id == "more" {
            app.buttons["welcome.more"].tap()
            _ = app.buttons.element(boundBy: 0).waitForExistence(timeout: 5)
            sleep(1)
        }
        return app
    }

    func testAuditMainScreensAtDefaultAndLargestText() throws {
        var issues: [[String: String]] = []
        for (sizeName, extra) in [("default", [String]()), ("AX5", Self.largestText)] {
            for screen in Self.screens {
                let app = launch(screen, extra: extra)
                try app.performAccessibilityAudit(for: .all) { issue in
                    let element = issue.element
                    issues.append([
                        "size": sizeName, "screen": screen.id, "type": String(describing: issue.auditType),
                        "description": issue.compactDescription,
                        "identifier": element?.identifier ?? "", "label": element?.label ?? "",
                        "frame": element.map { NSCoder.string(for: $0.frame) } ?? "",
                    ])
                    return true // recorded, not failed: the whole list is reviewed
                }
                app.terminate()
            }
        }
        try write(issues, named: "audit")
    }

    /// On a tablet the top bar must not overlap the status bar's content, and Save copy's whole hit area (its top edge
    /// included) must start the save; y33 probes just below iPadOS's 32 pt status strip (recorded, not asserted).
    func testTabletTopBarClearsStatusBarAndSaveCopyIsTappableAtItsTopEdge() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("tablet only") }
        let app = launch(("dev-preset", "lake", "develop.ruler"), extra: [])
        let save = app.buttons["editor.saveCopy"]
        XCTAssertTrue(save.waitForExistence(timeout: timeout))
        // The status bar's items belong to SpringBoard; its time, Wi-Fi and battery elements sit in the top strip.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let statusItems = springboard.descendants(matching: .any).allElementsBoundByIndex
            .filter { $0.exists && $0.frame.minY < 40 && $0.frame.height > 0 && $0.frame.height < 40 && $0.frame.width < 400 }
        let statusBottom = statusItems.map(\.frame.maxY).max() ?? 0
        var result: [[String: String]] = [[
            "saveCopyFrame": NSCoder.string(for: save.frame),
            "statusItemsBottom": "\(statusBottom)",
            "statusItems": statusItems.map { "\($0.label) \(NSCoder.string(for: $0.frame))" }.joined(separator: "; "),
        ]]
        XCTAssertGreaterThanOrEqual(save.frame.minY, statusBottom, "Save copy overlaps the status bar's content")
        // Save copy's hit area: a tap 2 pt inside its top edge, and (control, fresh launch) a tap at its centre, must each
        // show the Saving overlay. The fake, slow library writer keeps the overlay up and avoids the Photos prompt.
        for (name, dy) in [("topEdge", 2.0), ("y33", 7.0), ("centre", -1.0)] {
            app.terminate()
            let run = launch(("dev-preset", "lake", "develop.ruler"), extra: ["--fake-library-writer", "--slow-library-writer"])
            let button = run.buttons["editor.saveCopy"]
            XCTAssertTrue(button.waitForExistence(timeout: timeout))
            let point = dy < 0 ? button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                : button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: dy))
            point.tap()
            let started = run.descendants(matching: .any)["saving"].waitForExistence(timeout: 10)
            result[0]["\(name)TapStartedSave"] = "\(started)"
            XCTAssertTrue(started, "a tap at Save copy's \(name) did not start the save")
        }
        try write(result, named: "tablet-topbar")
    }

    private func write(_ rows: [[String: String]], named name: String) throws {
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        let device = UIDevice.current.name.replacingOccurrences(of: " ", with: "_")
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.output.appendingPathComponent("\(device)-\(name).json"))
    }
}
