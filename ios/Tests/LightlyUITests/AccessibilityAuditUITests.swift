import Vision
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
        ("ed-crop-workspace", "lake", "editor.photo"),
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

    // MARK: - Largest text: layout checks without a pixel reference

    /// Owner, 2026-10-21: the largest-text Welcome and More have no approved screen to compare pixels with, so their
    /// snapshot references are pending; they must still be checked for clipping, overlap, scrolling and usable
    /// controls. Runs at AX3 (the snapshot tests' size) and AX5 (the largest), in light and dark (owner, 2026-10-21).
    /// Icons need not grow with the text.
    /// Split from More so each runs inside one heavy job on one simulator; run on iPhone 17 and iPhone SE 3 (owner,
    /// 2026-10-22: scrolling, taps and clipping at AX3 and AX5 in both themes on both).
    func testWelcomeAtLargestTextHasNoClippingOverlapOrUnreachableControls() throws {
        XCTAssertFalse(Self.largestTextConfigurations.isEmpty, "LIGHTLY_LARGEST_TEXT_THEME selects no theme")
        for (sizeName, arguments) in Self.largestTextConfigurations {
            let welcome = ["welcome.more", "welcome.choosePhoto", "welcome.camera", "welcome.privacyPolicy"]
            var app = launch(Self.screens[0], extra: arguments)
            try checkLayout(app, screen: "welcome \(sizeName)", identifiers: welcome)

            // Taps, each control scrolled into view first and checked to do its job. A fresh launch for each, so every
            // tap starts from Welcome at the top.
            app.terminate()
            app = launch(Self.screens[0], extra: arguments)
            tapAfterScrolling(app, "welcome.privacyPolicy", screen: sizeName)
            XCTAssertTrue(app.descendants(matching: .any)["more.page.privacyPolicy"].waitForExistence(timeout: 10),
                          "Privacy Policy did not open from Welcome at \(sizeName)")
            saveScreenshot(app, named: "welcome \(sizeName) tapped privacy")
            app.terminate()

            for identifier in ["welcome.choosePhoto", "welcome.camera"] {
                // Camera asks for access first; reset it so the system prompt (a response to the tap) appears each time.
                if identifier == "welcome.camera" { XCUIApplication().resetAuthorizationStatus(for: .camera) }
                app = launch(Self.screens[0], extra: arguments)
                tapAfterScrolling(app, identifier, screen: sizeName)
                // Welcome is covered by what the tap presents (the photo picker; the camera access prompt or page).
                let springboardAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
                let covered = NSPredicate { _, _ in !app.buttons["welcome.more"].isHittable || springboardAlert.exists }
                let presented = expectation(for: covered, evaluatedWith: NSObject())
                XCTAssertEqual(XCTWaiter.wait(for: [presented], timeout: 10), .completed, "\(identifier) did nothing at \(sizeName)")
                saveScreenshot(app, named: "welcome \(sizeName) tapped \(identifier)")
                // The system prompt outlives the app and would sit over the next launch (its audit then fails with
                // "Invalid target app"); declining it leaves nothing behind, and the next camera tap resets it again.
                if springboardAlert.exists { springboardAlert.buttons.element(boundBy: 0).tap() }
                app.terminate()
            }
        }
    }

    func testMoreAtLargestTextHasNoClippingOverlapOrUnreachableControls() throws {
        XCTAssertFalse(Self.largestTextConfigurations.isEmpty, "LIGHTLY_LARGEST_TEXT_THEME selects no theme")
        for (sizeName, arguments) in Self.largestTextConfigurations {
            let theme = sizeName.hasSuffix("dark") ? "dark" : "light"
            let app = launch(Self.screens[0], extra: arguments)
            app.buttons["welcome.more"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["more.page.menu"].waitForExistence(timeout: 10), "More did not open at \(sizeName)")
            // The theme really applied: More's Appearance shows it selected.
            XCTAssertTrue(appearanceOption(app, theme).isSelected, "\(theme) not selected at \(sizeName)")
            let more = ["appearance.system", "appearance.light", "appearance.dark",
                        "preferences.favourites", "preferences.signature", "preferences.preferredBorder", "more.row.about", "more.row.legal"]
            try checkLayout(app, screen: "more \(sizeName)", identifiers: more)
            // Usable after scrolling: the last row opens its page.
            app.buttons["more.row.legal"].tap()
            // "Terms of Use" alone labels a row only on the Legal page (More's Legal row reads "Legal, Privacy Policy, …").
            XCTAssertTrue(app.buttons["Terms of Use"].waitForExistence(timeout: 10), "Legal did not open from More at \(sizeName)")
            saveScreenshot(app, named: "legal \(sizeName)")
            app.terminate()

            // Appearance: each option, scrolled into view, takes the tap and becomes the one selected; the launch's
            // theme last, so the screen ends as it started.
            let tapsApp = launch(Self.screens[0], extra: arguments)
            tapsApp.buttons["welcome.more"].tap()
            XCTAssertTrue(tapsApp.descendants(matching: .any)["more.page.menu"].waitForExistence(timeout: 10))
            for option in ["system", "light", "dark"].filter({ $0 != theme }) + [theme] {
                tapAfterScrolling(tapsApp, "appearance.\(option)", screen: sizeName)
                let selected = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: appearanceOption(tapsApp, option))
                XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed, "appearance.\(option) not selected after its tap at \(sizeName)")
                saveScreenshot(tapsApp, named: "more \(sizeName) tapped appearance.\(option)")
            }
            tapsApp.terminate()
        }
    }

    private static let capsuleButtons = ["welcome.choosePhoto", "welcome.camera", "cameraOff.openSettings", "cameraOff.choosePhoto",
                                         "loadFailed.chooseAnother", "loadFailed.tryAgain"]

    /// The two recovery screens share Welcome's scroll container (FillingScrollView), changed by AX5 revision 3 (owner,
    /// 2026-10-22: check them at large text). Their buttons do not use revision 3's label insets, which were approved
    /// for Welcome only, so the padding check reports what they show today.
    func testPhotoCannotBeOpenedAtLargestTextHasNoClippingOverlapOrUnreachableControls() throws {
        XCTAssertFalse(Self.largestTextConfigurations.isEmpty, "LIGHTLY_LARGEST_TEXT_THEME selects no theme")
        let ready = "loadFailed.chooseAnother"
        for (sizeName, arguments) in Self.largestTextConfigurations {
            let launchArguments = arguments + ["--open-unreadable-photo"]
            var app = launchRecovery(launchArguments, ready: ready, screen: sizeName)
            try checkLayout(app, screen: "load-failed \(sizeName)", identifiers: ["recovery.close", "loadFailed.chooseAnother", "loadFailed.tryAgain"])
            // Close returns to Welcome.
            tapAfterScrolling(app, "recovery.close", screen: sizeName)
            XCTAssertTrue(app.buttons["welcome.choosePhoto"].waitForExistence(timeout: 10), "Close did not return to Welcome at \(sizeName)")
            app.terminate()
            // Choose another photo presents the photo picker over the screen.
            app = launchRecovery(launchArguments, ready: ready, screen: sizeName)
            tapAfterScrolling(app, "loadFailed.chooseAnother", screen: sizeName)
            assertCovered(app, by: "loadFailed.chooseAnother", screen: sizeName)
            app.terminate()
            // Try again re-reads the same unreadable bytes, so the screen comes back; the check is that the control
            // takes the tap (scrolled into view, hittable) and the app stays on this screen without failing.
            app = launchRecovery(launchArguments, ready: ready, screen: sizeName)
            tapAfterScrolling(app, "loadFailed.tryAgain", screen: sizeName)
            XCTAssertTrue(app.buttons[ready].waitForExistence(timeout: 10), "load-failed did not come back after Try again at \(sizeName)")
            saveScreenshot(app, named: "load-failed \(sizeName) tapped tryAgain")
            app.terminate()
        }
    }

    func testCameraAccessOffAtLargestTextHasNoClippingOverlapOrUnreachableControls() throws {
        XCTAssertFalse(Self.largestTextConfigurations.isEmpty, "LIGHTLY_LARGEST_TEXT_THEME selects no theme")
        for (sizeName, arguments) in Self.largestTextConfigurations {
            // Camera access declined once; every later Camera tap then goes straight to this screen.
            XCUIApplication().resetAuthorizationStatus(for: .camera)
            var app = launchCameraAccessOff(arguments, screen: sizeName, declineFirst: true)
            try checkLayout(app, screen: "camera-off \(sizeName)", identifiers: ["recovery.close", "cameraOff.openSettings", "cameraOff.choosePhoto"])
            tapAfterScrolling(app, "recovery.close", screen: sizeName)
            XCTAssertTrue(app.buttons["welcome.choosePhoto"].waitForExistence(timeout: 10), "Close did not return to Welcome at \(sizeName)")
            app.terminate()
            app = launchCameraAccessOff(arguments, screen: sizeName, declineFirst: false)
            tapAfterScrolling(app, "cameraOff.choosePhoto", screen: sizeName)
            assertCovered(app, by: "cameraOff.choosePhoto", screen: sizeName)
            app.terminate()
            // Open Settings leaves the app for the Settings app.
            app = launchCameraAccessOff(arguments, screen: sizeName, declineFirst: false)
            tapAfterScrolling(app, "cameraOff.openSettings", screen: sizeName)
            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 10), "Open Settings did not open Settings at \(sizeName)")
            settings.terminate()
            app.terminate()
        }
    }

    private func launchRecovery(_ arguments: [String], ready: String, screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-preferences"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons[ready].waitForExistence(timeout: timeout), "\(ready) not shown at \(screen)")
        return app
    }

    /// Welcome › Camera with access declined: the system prompt first when [declineFirst], else straight through.
    private func launchCameraAccessOff(_ arguments: [String], screen: String, declineFirst: Bool) -> XCUIApplication {
        let app = launch(Self.screens[0], extra: arguments)
        tapAfterScrolling(app, "welcome.camera", screen: screen)
        if declineFirst {
            let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 10), "no camera prompt at \(screen)")
            alert.buttons["Don’t Allow"].exists ? alert.buttons["Don’t Allow"].tap() : alert.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(app.buttons["cameraOff.openSettings"].waitForExistence(timeout: 10), "camera-off not shown at \(screen)")
        return app
    }

    /// Something (the photo picker) now covers the screen that held [identifier].
    private func assertCovered(_ app: XCUIApplication, by identifier: String, screen: String) {
        let covered = NSPredicate { _, _ in !app.buttons[identifier].exists || !app.buttons[identifier].isHittable }
        let presented = expectation(for: covered, evaluatedWith: NSObject())
        XCTAssertEqual(XCTWaiter.wait(for: [presented], timeout: 10), .completed, "\(identifier) did nothing at \(screen)")
        saveScreenshot(app, named: "\(screen) tapped \(identifier)")
    }

    /// AX3 (the snapshot tests' size) and AX5 (the largest), each in light and dark. LIGHTLY_LARGEST_TEXT_THEME (set as
    /// TEST_RUNNER_LIGHTLY_LARGEST_TEXT_THEME) limits a run to one theme, so a slow simulator fits scripts/heavy's
    /// 600 s cap; both themes must still be run.
    private static let largestTextConfigurations: [(name: String, arguments: [String])] = {
        var configurations: [(name: String, arguments: [String])] = []
        let only = ProcessInfo.processInfo.environment["LIGHTLY_LARGEST_TEXT_THEME"].flatMap { $0.isEmpty ? nil : $0 }
        for theme in ["light", "dark"] where only == nil || only == theme {
            for (size, category) in [("AX3", "UICTContentSizeCategoryAccessibilityXL"), ("AX5", "UICTContentSizeCategoryAccessibilityXXXL")] {
                configurations.append(("\(size) \(theme)", ["-UIPreferredContentSizeCategoryName", category, "-lightly.preferences.v1.appearance", theme]))
            }
        }
        return configurations
    }()

    private func appearanceOption(_ app: XCUIApplication, _ option: String) -> XCUIElement {
        app.descendants(matching: .any)["appearance.\(option)"].firstMatch
    }

    /// A screenshot once two taken 0.3 s apart are identical (up to 3 s; then the last one).
    private func stableScreenshot(_ app: XCUIApplication) -> XCUIScreenshot {
        var previous = app.screenshot()
        for _ in 0..<10 {
            usleep(300_000)
            let current = app.screenshot()
            if current.pngRepresentation == previous.pngRepresentation { return current }
            previous = current
        }
        return previous
    }

    /// Swipes up until [identifier] is hittable, then taps it.
    private func tapAfterScrolling(_ app: XCUIApplication, _ identifier: String, screen: String) {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(screen): \(identifier) missing")
        var swipes = 0
        while !element.isHittable, swipes < 10 { app.swipeUp(velocity: .slow); swipes += 1 }
        XCTAssertTrue(element.isHittable, "\(screen): \(identifier) cannot be scrolled into a tappable position")
        element.tap()
    }

    /// Scrolls each element in [identifiers] into view (in order, swiping up as needed) and checks, at every scroll
    /// position: the element is hittable and lies inside the window's width; no two visible controls overlap (one
    /// containing another, a row and its own label, is allowed); and Xcode's audit finds no clipped text and no hit
    /// region too small. Fails with the screen, element and frames.
    private func checkLayout(_ app: XCUIApplication, screen: String, identifiers: [String]) throws {
        let window = app.windows.firstMatch.frame
        try auditClippingAndHitRegions(app, screen: "\(screen) top")
        try assertRenderedLayout(app, screen: "\(screen) top")
        saveScreenshot(app, named: "\(screen) 0 top")
        var lastFrame = CGRect.null
        for (index, identifier) in identifiers.enumerated() {
            let element = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 5), "\(screen): \(identifier) missing")
            var swipes = 0
            while !element.isHittable, swipes < 10 { app.swipeUp(velocity: .slow); swipes += 1 }
            XCTAssertTrue(element.isHittable, "\(screen): \(identifier) cannot be scrolled into a tappable position")
            // The system scroll indicator stays over the right end of the buttons for a moment after a swipe, and a
            // still screenshot does not wait for it (SE 3, 2026-10-22: read as Camera's content touching its outline).
            if swipes > 0 { sleep(2) }
            XCTAssertGreaterThanOrEqual(element.frame.minX, window.minX - 0.5, "\(screen): \(identifier) clipped on the left \(element.frame)")
            XCTAssertLessThanOrEqual(element.frame.maxX, window.maxX + 0.5, "\(screen): \(identifier) clipped on the right \(element.frame)")
            assertNoOverlap(app, screen: "\(screen) at \(identifier)")
            try assertRenderedLayout(app, screen: "\(screen) at \(identifier)")
            // One screenshot per distinct scroll position, so every part of the page is on record.
            let scrollFrame = app.scrollViews.firstMatch.exists ? app.scrollViews.firstMatch.descendants(matching: .any).firstMatch.frame : .null
            if scrollFrame != lastFrame { saveScreenshot(app, named: "\(screen) \(index + 1) \(identifier)"); lastFrame = scrollFrame }
        }
        try auditClippingAndHitRegions(app, screen: "\(screen) end")
    }

    /// Frames are compared as shown: a control inside a scroll view only by its part inside the scroll view, so a row
    /// scrolled up behind More's opaque pinned header (title and close) does not count as overlapping the close button.
    private func assertNoOverlap(_ app: XCUIApplication, screen: String) {
        let window = app.windows.firstMatch.frame
        let scroll = app.scrollViews.firstMatch
        let scrolled = scroll.exists ? (scroll.buttons.allElementsBoundByIndex + scroll.switches.allElementsBoundByIndex) : []
        let scrolledKeys = Set(scrolled.map { "\($0.identifier)|\($0.label)|\(NSCoder.string(for: $0.frame))" })
        let visibleArea = scroll.exists ? scroll.frame.intersection(window) : window
        let controls = (app.buttons.allElementsBoundByIndex + app.switches.allElementsBoundByIndex)
            .filter { $0.exists && $0.isHittable }
            .map { element -> (label: String, frame: CGRect) in
                let inScroll = scrolledKeys.contains("\(element.identifier)|\(element.label)|\(NSCoder.string(for: element.frame))")
                return (element.identifier.isEmpty ? element.label : element.identifier, element.frame.intersection(inScroll ? visibleArea : window))
            }
            .filter { !$0.frame.isNull && $0.frame.width > 1 && $0.frame.height > 1 }
        for (i, a) in controls.enumerated() {
            for b in controls[(i + 1)...] {
                let shared = a.frame.intersection(b.frame)
                guard !shared.isNull, shared.width > 1, shared.height > 1 else { continue }
                if a.frame.contains(b.frame) || b.frame.contains(a.frame) { continue }
                XCTFail("\(screen): \(a.label) \(a.frame) overlaps \(b.label) \(b.frame)")
                saveScreenshot(app, named: "overlap \(screen)")
            }
        }
    }

    /// The screen as it was when a layout check failed, for review (and attached to the result).
    private func saveScreenshot(_ app: XCUIApplication, named name: String, shot analysed: XCUIScreenshot? = nil) {
        let shot = analysed ?? app.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try? FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        let device = UIDevice.current.name.replacingOccurrences(of: " ", with: "_")
        try? shot.pngRepresentation.write(to: Self.output.appendingPathComponent("\(device)-" + name.replacingOccurrences(of: " ", with: "_") + ".png"))
    }

    // MARK: - Rendered-layout checks (owner, 2026-10-21: verify actual wrapping and visible bounds)

    /// The rendered screen, as pixels, plus what the accessibility tree says is on it. Every check below reads what was
    /// drawn, not what the layout intended: Xcode's audit counts neither a word broken across lines nor a clipped image
    /// as clipping, and passed on all four AX5 defects found on 2026-10-21.
    private func assertRenderedLayout(_ app: XCUIApplication, screen: String) throws {
        // The screen must be still: after a swipe, the scroll indicator fades over the right end of the buttons and
        // the content may still be decelerating (SE 3, 2026-10-22: a button 17 pt clear of its outline measured 0 pt).
        let shot = stableScreenshot(app)
        guard let pixels = ScreenPixels(shot.image) else { return XCTFail("\(screen): screenshot unreadable") }
        let window = app.windows.firstMatch.frame
        let scroll = app.scrollViews.firstMatch
        let visible = scroll.exists ? scroll.frame.intersection(window) : window
        var failed = false
        func fail(_ message: String) { XCTFail("\(screen): \(message)"); failed = true }

        // 1. No word broken across lines: OCR each fully visible text and button, and check every line break falls
        //    between words of its accessibility label ("Lightl / y", "Syste / m" fail).
        let texts = (app.staticTexts.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex)
            .filter { $0.exists && !$0.label.isEmpty && visible.contains($0.frame.insetBy(dx: 1, dy: 1)) && $0.frame.height > 1 }
        for element in texts {
            for problem in Self.midWordBreaks(in: pixels.crop(element.frame), label: element.label) {
                fail("\"\(element.label)\" breaks a word across lines: \(problem) \(element.frame)")
            }
        }

        // Welcome stays in the accessibility tree under More's sheet, so its checks run on Welcome only.
        let moreOpen = app.descendants(matching: .any)["more.page.menu"].exists
        let onWelcome = !moreOpen && app.buttons["welcome.choosePhoto"].exists
        // 2. The Welcome mark is wholly visible: its coloured rays span as much height as width (the mark is square).
        //    Checked unscrolled only: once Welcome scrolls (short screens at AX5), the mark leaving the top is scrolling,
        //    not clipping.
        if onWelcome, screen.hasSuffix(" top"), let wordmark = app.staticTexts["Lightly"].firstMatch.exists ? app.staticTexts["Lightly"].firstMatch.frame : nil,
           app.buttons["welcome.choosePhoto"].exists {
            let region = CGRect(x: window.midX - 100, y: window.minY, width: 200, height: max(0, wordmark.minY - window.minY))
            if let mark = pixels.saturatedBounds(in: region) {
                if mark.height < mark.width * 0.9 { fail("the mark is clipped: visible \(mark) is \(Int(mark.width)) wide but \(Int(mark.height)) tall") }
            } else { fail("the mark is not visible above the wordmark") }
        }

        // 3. Button content keeps clear of its capsule: at least the mockup's 6 pt (its buttons set no horizontal
        //    padding, so they keep the browser's default 6 px) between any drawn content and the outline.
        //    Every full-width capsule button on the screen: Welcome's two and the recovery screens' two each.
        for identifier in moreOpen ? [] : Self.capsuleButtons {
            let button = app.buttons[identifier].firstMatch
            guard button.exists, visible.contains(button.frame.insetBy(dx: 1, dy: 1)) else { continue }
            if let nearest = pixels.minimumGapToCapsule(button.frame), nearest.gap < 6 {
                fail("\(identifier)'s content is \(String(format: "%.1f", nearest.gap)) pt from its outline (minimum 6) \(button.frame); "
                     + "nearest content at \(nearest.at), colour \(nearest.colour); screenshot scale \(pixels.scale)")
            }
        }
        // The analysed screenshot itself, so the failure can be checked against exactly what was measured.
        if failed { saveScreenshot(app, named: "layout \(screen)", shot: shot) }
    }

    /// Line breaks inside a word, read from the rendered text: Vision's lines, top to bottom; a break is mid-word when
    /// the end of one line and the start of the next join into one word of the label.
    private static func midWordBreaks(in image: CGImage?, label: String) -> [String] {
        guard let image else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? [])
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }
        guard lines.count > 1 else { return [] }
        let words = Set(Self.words(label))
        var problems: [String] = []
        for (upper, lower) in zip(lines, lines.dropFirst()) {
            guard let end = Self.words(upper).last, let start = Self.words(lower).first else { continue }
            if words.contains(end + start) && !(words.contains(end) && words.contains(start)) {
                problems.append("\"\(upper)\" / \"\(lower)\"")
            }
        }
        return problems
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    }

    private func auditClippingAndHitRegions(_ app: XCUIApplication, screen: String) throws {
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion]) { issue in
            XCTFail("\(screen): \(issue.compactDescription) — \(issue.element?.identifier ?? "") \(issue.element?.label ?? "") \(issue.element.map { NSCoder.string(for: $0.frame) } ?? "")")
            return true
        }
    }

    private func write(_ rows: [[String: String]], named name: String) throws {
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        let device = UIDevice.current.name.replacingOccurrences(of: " ", with: "_")
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.output.appendingPathComponent("\(device)-\(name).json"))
    }
}

/// A screenshot's pixels in points (RGBA, top-left origin), for the rendered-layout checks.
private struct ScreenPixels {
    let image: CGImage
    let scale: CGFloat
    private let bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cg = image.cgImage else { return nil }
        self.image = cg
        scale = CGFloat(cg.width) / image.size.width
        var buffer = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        guard let context = CGContext(data: &buffer, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        bytes = buffer
    }

    func crop(_ rect: CGRect) -> CGImage? {
        image.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral)
    }

    private func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let i = (y * image.width + x) * 4
        return (Double(bytes[i]) / 255, Double(bytes[i + 1]) / 255, Double(bytes[i + 2]) / 255)
    }

    /// Bounds, in points, of the strongly coloured pixels in [rect] (the mark's rays; text and backgrounds are grey).
    func saturatedBounds(in rect: CGRect) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        let r = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !r.isNull else { return nil }
        for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) {
            let (red, green, blue) = rgb(x, y)
            let high = max(red, green, blue), low = min(red, green, blue)
            if high > 0.45, high - low > 0.45 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        } }
        guard minX <= maxX else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    /// The smallest distance, in points, from any drawn content (pixels unlike the button's own fill) to the capsule
    /// outline of a button filling [frame]; nil when no content is found. The outline stroke itself (within 1.5 pt) is
    /// not content. Measured to the drawn edge found in the pixels, not to a modelled circle.
    func minimumGapToCapsule(_ frame: CGRect) -> (gap: CGFloat, at: CGPoint, colour: String)? {
        let radius = frame.height / 2
        func inwardDistance(_ p: CGPoint) -> CGFloat {
            let cx = min(max(p.x, frame.minX + radius), frame.maxX - radius)
            return radius - hypot(p.x - cx, p.y - frame.midY)
        }
        // The fill: the commonest colour inside the capsule, away from the outline.
        var counts: [Int: Int] = [:]
        var samples: [(CGPoint, (Double, Double, Double))] = []
        let step = 1 / scale
        var y = frame.minY
        while y < frame.maxY { var x = frame.minX
            while x < frame.maxX {
                let p = CGPoint(x: x, y: y)
                if inwardDistance(p) > 1.5 {
                    let c = rgb(Int(x * scale), Int(y * scale))
                    samples.append((p, c))
                    counts[Int(c.0 * 15) << 8 | Int(c.1 * 15) << 4 | Int(c.2 * 15), default: 0] += 1
                }
                x += step }
            y += step }
        guard let fillKey = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let fill = (Double(fillKey >> 8) / 15, Double((fillKey >> 4) & 15) / 15, Double(fillKey & 15) / 15)
        func differs(_ a: (Double, Double, Double), _ b: (Double, Double, Double), by limit: Double) -> Bool {
            abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) > limit
        }
        // The drawn edge, located in the pixels rather than modelled (2026-10-22). SwiftUI's `Capsule` has continuous
        // ends, which on a tall (wrapped) button sit several points inside circular ends near where they meet the
        // straight edges; there, measured against a circle, anti-aliased edge pixels read as content 0 pt from the
        // outline. Colour cannot tell those blends from text (dark text on a dark page), so the edge is found by
        // position: along every row and column through the frame, the outermost pixel unlike the page beside the
        // button is the outline (content never lies outside it unless it overflows, which still fails below).
        let page = rgb(max(0, Int((frame.minX - 3) * scale)), Int(frame.midY * scale))
        func notPage(_ x: CGFloat, _ y: CGFloat) -> Bool {
            guard x >= 0, y >= 0, Int(x * scale) < image.width, Int(y * scale) < image.height else { return false }
            return differs(rgb(Int(x * scale), Int(y * scale)), page, by: 0.1)
        }
        var edge: [CGPoint] = []
        var row = frame.minY - 2
        while row < frame.maxY + 2 {
            var x = frame.minX - 3; while x < frame.midX, !notPage(x, row) { x += step }
            if x < frame.midX { edge.append(CGPoint(x: x, y: row)) }
            x = frame.maxX + 3; while x > frame.midX, !notPage(x, row) { x -= step }
            if x > frame.midX { edge.append(CGPoint(x: x, y: row)) }
            row += step }
        var column = frame.minX - 2
        while column < frame.maxX + 2 {
            var y = frame.minY - 3; while y < frame.midY, !notPage(column, y) { y += step }
            if y < frame.midY { edge.append(CGPoint(x: column, y: y)) }
            y = frame.maxY + 3; while y > frame.midY, !notPage(column, y) { y -= step }
            if y > frame.midY { edge.append(CGPoint(x: column, y: y)) }
            column += step }
        // Edge points bucketed in 8 pt cells, so each content pixel compares only with the edge near it.
        let cell: CGFloat = 8
        func cellKey(_ x: CGFloat, _ y: CGFloat) -> Int { Int(floor(x / cell)) << 16 | Int(floor(y / cell)) & 0xFFFF }
        var buckets: [Int: [CGPoint]] = [:]
        for point in edge { buckets[cellKey(point.x, point.y), default: []].append(point) }
        var nearest: (gap: CGFloat, at: CGPoint, colour: String)?
        for (p, c) in samples where differs(c, fill, by: 0.6) {
            var closest = CGFloat.infinity
            for dx in [-cell, 0, cell] { for dy in [-cell, 0, cell] {
                for e in buckets[cellKey(p.x + dx, p.y + dy)] ?? [] { closest = min(closest, hypot(e.x - p.x, e.y - p.y)) }
            } }
            // Within 1.5 pt of the edge is the outline stroke and its anti-aliasing, not content; no edge point in
            // the neighbouring cells means at least 8 pt clear.
            guard closest.isFinite, closest > 1.5 else { continue }
            let d = closest - 1.5
            if d < nearest?.gap ?? .infinity { nearest = (d, p, String(format: "%.2f %.2f %.2f", c.0, c.1, c.2)) }
        }
        return nearest
    }
}
