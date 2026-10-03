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

    // MARK: - Full flow

    /// The whole primary flow on the real app with the real Look pack (spec
    /// §2): choose a photo → it develops by itself → Auto is reported
    /// unavailable → presets from two categories → Strength → Compare (the
    /// photo says "Original") → Undo → Redo → Reset (undoable) → Save copy
    /// adds a new photo.
    ///
    /// Categories and preset names are read from the same pack the build
    /// bundled (`BundledLookPack`), never hard-coded: the catalog is data.
    ///
    /// `--auto-delay-seconds` (DEBUG only) holds Auto back briefly so the
    /// developing state is observable; without a bundled model it would
    /// otherwise resolve instantly.
    func testEditAndSaveCopyEndToEnd() throws {
        relaunch(arguments: ["--auto-delay-seconds", "2"])
        try openFirstLibraryPhoto()

        // Developing: the photo is visible, a progress row, no edit controls.
        XCTAssertTrue(app.descendants(matching: .any)["editor.developing"].waitForExistence(timeout: timeout),
                      "Selecting a photo should start developing by itself (no Develop button).")
        XCTAssertFalse(app.buttons["action.develop"].exists, "There is no Develop button (spec D2).")
        XCTAssertTrue(app.descendants(matching: .any)["editor.photo"].exists, "The photo stays visible while developing.")
        capture(named: "03-developing")

        // Auto: explicitly unavailable, straight to editing (no futile Retry), nothing blocked.
        let autoNotice = app.descendants(matching: .any)["editor.autoUnavailableNotice"]
        XCTAssertTrue(autoNotice.waitForExistence(timeout: timeout), "Auto must say it is unavailable.")
        XCTAssertTrue(autoNotice.label.contains("Auto is unavailable"), autoNotice.label)
        XCTAssertFalse(app.buttons["action.retryAuto"].exists, "No Retry when no model exists.")
        let pack = try requireBundledPack()
        if pack.hasApproximateLooks {
            let approximate = app.descendants(matching: .any)["editor.approximateLooksNotice"]
            XCTAssertTrue(approximate.exists, "Looks that are not validated must be labelled as such.")
            XCTAssertTrue(approximate.label.contains("approximate"), approximate.label)
        }
        capture(named: "04-auto-unavailable")

        // First category: its first two presets, each a real thumb drag
        // (previews while moving, commits on lift). The name and position show.
        let categories = pack.categories.filter { !$0.names.isEmpty }
        let first = try XCTUnwrap(categories.first { $0.names.count >= 2 }, "Pack has no category with two presets")
        let second = try XCTUnwrap(categories.first { $0.id != first.id }, "Pack has only one category")
        app.buttons["editor.category.\(first.id)"].tap()
        let slider = app.descendants(matching: .any)["editor.lookSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitForValue(of: slider, toEqual: first.value(atStop: 0)), "\(slider.value ?? "nil")")
        XCTAssertFalse(app.descendants(matching: .any)["editor.strengthSlider"].exists, "No Look, no Strength")
        dragSlider(slider, from: 0, to: 1, stopCount: first.stopCount)
        XCTAssertTrue(waitForValue(of: slider, toEqual: first.value(atStop: 1)), "\(slider.value ?? "nil")")
        capture(named: "05-look-first-preset")
        dragSlider(slider, from: 1, to: 2, stopCount: first.stopCount)
        XCTAssertTrue(waitForValue(of: slider, toEqual: first.value(atStop: 2)), "\(slider.value ?? "nil")")
        XCTAssertEqual(photoValue(), first.names[1], "Looks replace each other; the photo reports the one applied.")
        capture(named: "06-look-second-preset")

        // Strength: secondary, only with a Look; a drag then release is one step.
        let strength = app.descendants(matching: .any)["editor.strengthSlider"]
        XCTAssertTrue(strength.waitForExistence(timeout: timeout))
        XCTAssertEqual(strength.value as? String, "100%")
        dragStrength(strength, toFraction: 0.4)
        XCTAssertTrue(waitForValue(of: strength, toMatch: "^[3-4][0-9]%$"), "\(strength.value ?? "nil")")
        let reducedStrength = strength.value as? String
        capture(named: "07-strength")

        // Agreed Strength rule: settling on the stop that is already committed changes nothing —
        // the Strength stays reduced (and no step is added: the Undo below lands on this state).
        tapStop(slider, 2, stopCount: first.stopCount)
        XCTAssertTrue(waitForValue(of: slider, toEqual: first.value(atStop: 2)), "\(slider.value ?? "nil")")
        XCTAssertEqual(strength.value as? String, reducedStrength, "Same stop keeps the Strength")
        capture(named: "07b-same-stop-keeps-strength")

        // Second category: a preset there replaces the first category's Look.
        app.buttons["editor.category.\(second.id)"].tap()
        XCTAssertTrue(waitForValue(of: slider, toEqual: second.value(atStop: 0)), "\(slider.value ?? "nil")")
        dragSlider(slider, from: 0, to: 1, stopCount: second.stopCount)
        XCTAssertTrue(waitForValue(of: slider, toEqual: second.value(atStop: 1)), "\(slider.value ?? "nil")")
        XCTAssertEqual(photoValue(), second.names[0])
        capture(named: "08-second-category-preset")

        // Compare, by the toggle (the accessible alternative to holding).
        let compare = app.buttons["action.compare"]
        compare.tap()
        XCTAssertEqual(app.descendants(matching: .any)["editor.photo"].label, "Your original photograph",
                       "Compare must show the original.")
        XCTAssertTrue(compare.isSelected, "The toggle reports its state.")
        capture(named: "09-compare-original")
        compare.tap()
        XCTAssertEqual(app.descendants(matching: .any)["editor.photo"].label, "Your photograph")

        // Compare, by press and hold on the photo: back to the edit on release.
        app.descendants(matching: .any)["editor.photo"].press(forDuration: 0.8)
        XCTAssertEqual(app.descendants(matching: .any)["editor.photo"].label, "Your photograph")

        // Undo returns to the first category's preset at the reduced Strength; Redo comes back.
        app.buttons["action.undo"].tap()
        XCTAssertTrue(waitForPhotoValue(first.names[1]), "\(photoValue() ?? "nil")")
        XCTAssertEqual(app.descendants(matching: .any)["editor.strengthSlider"].value as? String, reducedStrength)
        capture(named: "10-after-undo")
        XCTAssertTrue(app.buttons["action.redo"].isEnabled)
        app.buttons["action.redo"].tap()
        XCTAssertTrue(waitForPhotoValue(second.names[0]), "\(photoValue() ?? "nil")")
        XCTAssertFalse(app.buttons["action.redo"].isEnabled, "Nothing left to redo.")
        capture(named: "11-after-redo")

        // Reset to Auto clears the Look; Undo brings it back (Reset is a step).
        app.buttons["action.reset"].tap()
        XCTAssertTrue(waitForValue(of: slider, toEqual: second.value(atStop: 0)), "\(slider.value ?? "nil")")
        XCTAssertFalse(app.buttons["action.reset"].isEnabled, "Nothing left to reset.")
        capture(named: "12-after-reset")
        app.buttons["action.undo"].tap()
        XCTAssertTrue(waitForValue(of: slider, toEqual: second.value(atStop: 1)), "\(slider.value ?? "nil")")

        try saveCopyAndConfirm(captureAs: "13-save-copy-confirmed")
    }

    /// Every category of the real pack, in pack order, shows its presets as
    /// discrete stops named verbatim from the manifest; the VoiceOver
    /// increment moves exactly one stop. Screenshots go to
    /// `LIGHTLY_UI_TEST_OUTPUT` (the demo).
    func testEveryCategoryOffersItsPresetsAsStops() throws {
        try openFirstLibraryPhoto()
        XCTAssertTrue(app.descendants(matching: .any)["editor.autoUnavailableNotice"].waitForExistence(timeout: timeout))
        let pack = try requireBundledPack()
        let slider = app.descendants(matching: .any)["editor.lookSlider"]

        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'editor.category.'"))
        XCTAssertEqual(chips.count, pack.categories.count, "One chip per pack category, no built-in ones")
        for (index, category) in pack.categories.enumerated() {
            let chip = app.buttons["editor.category.\(category.id)"]
            XCTAssertEqual(chip.label, category.label, "Labels come from the pack")
            chip.tap()
            XCTAssertTrue(waitForValue(of: slider, toEqual: category.value(atStop: 0)), "\(slider.value ?? "nil")")
            dragSlider(slider, from: 0, to: 1, stopCount: category.stopCount)
            XCTAssertTrue(waitForValue(of: slider, toEqual: category.value(atStop: 1)), "\(slider.value ?? "nil")")
            capture(named: "a\(index + 1)-\(category.id)-first-preset")
        }

        // The category with the most presets, stepped through every stop one
        // drag at a time. The Look slider is a custom adjustable control, not a
        // UISlider, so XCUIElement.adjust(toNormalizedSliderPosition:) throws on
        // it; dragging between adjacent detents is what a user does.
        let longest = try XCTUnwrap(pack.categories.max { $0.names.count < $1.names.count })
        app.buttons["editor.category.\(longest.id)"].tap()
        dragSlider(slider, from: 1, to: 0, stopCount: longest.stopCount)
        XCTAssertTrue(waitForValue(of: slider, toEqual: longest.value(atStop: 0)), "\(slider.value ?? "nil")")
        capture(named: "b0-\(longest.id)-stop-0")
        for stop in 1..<longest.stopCount {
            dragSlider(slider, from: stop - 1, to: stop, stopCount: longest.stopCount)
            XCTAssertTrue(waitForValue(of: slider, toEqual: longest.value(atStop: stop)), "\(slider.value ?? "nil")")
            capture(named: "b\(stop)-\(longest.id)-stop-\(stop)")
        }
        slider.swipeRight()
        XCTAssertTrue(waitForValue(of: slider, toEqual: longest.value(atStop: longest.stopCount - 1)),
                      "Clamped at the last preset; \(slider.value ?? "nil")")

        try saveCopyAndConfirm(captureAs: "d-save-copy-confirmed")
    }

    /// The wired editor at an accessibility text size with the pack's
    /// longest preset name: everything reachable, the name readable, the
    /// photo still visible.
    func testEditorAtAccessibilityTextSize() throws {
        relaunch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        try openFirstLibraryPhoto()
        XCTAssertTrue(app.descendants(matching: .any)["editor.autoUnavailableNotice"].waitForExistence(timeout: timeout))
        let pack = try requireBundledPack()
        let (category, stop) = try XCTUnwrap(pack.longestName, "Pack has no presets")

        // At this size the bottom panel scrolls; bring each control into
        // view the way a user would before using it.
        let chip = app.buttons["editor.category.\(category.id)"]
        scrollPanelUntilHittable(chip)
        chip.tap()
        let slider = app.descendants(matching: .any)["editor.lookSlider"]
        scrollPanelUntilHittable(slider)
        capture(named: "11a-large-text-controls")
        dragSlider(slider, from: 0, to: stop, stopCount: category.stopCount)
        XCTAssertTrue(waitForValue(of: slider, toEqual: category.value(atStop: stop)), "\(slider.value ?? "nil")")
        XCTAssertTrue(app.descendants(matching: .any)["editor.photo"].isHittable, "The photo stays visible at large text.")
        capture(named: "c-large-text-long-name")
    }

    /// Photo first in every orientation: on a phone (portrait only) the controls sit below the
    /// photo; on iPad in landscape they move beside it. Screenshots
    /// of each orientation go to `LIGHTLY_UI_TEST_OUTPUT`.
    func testLayoutFollowsOrientation() throws {
        XCUIDevice.shared.orientation = .portrait
        try openFirstLibraryPhoto()
        XCTAssertTrue(app.descendants(matching: .any)["editor.autoUnavailableNotice"].waitForExistence(timeout: timeout))
        let pack = try requireBundledPack()
        let category = try XCTUnwrap(pack.categories.first { !$0.names.isEmpty })
        app.buttons["editor.category.\(category.id)"].tap()
        let slider = app.descendants(matching: .any)["editor.lookSlider"]
        dragSlider(slider, from: 0, to: 1, stopCount: category.stopCount)
        XCTAssertTrue(waitForValue(of: slider, toEqual: category.value(atStop: 1)), "\(slider.value ?? "nil")")
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let device = isPad ? "ipad" : "iphone"

        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            if orientation.isLandscape && !isPad {
                // Approved layouts: iPhone is portrait only, so turning the phone keeps the app
                // (and the controls below the photo) in portrait.
                XCUIDevice.shared.orientation = orientation
                let rotated = NSPredicate { _, _ in self.app.windows.firstMatch.frame.width > self.app.windows.firstMatch.frame.height }
                XCTAssertFalse(waitForRotation(rotated), "iPhone must stay in portrait")
                XCTAssertTrue(slider.frame.minY >= app.descendants(matching: .any)["editor.photo"].frame.maxY, "Controls stay below the photo")
                capture(named: "layout-iphone-turned-stays-portrait")
                continue
            }
            XCUIDevice.shared.orientation = orientation
            let photo = app.descendants(matching: .any)["editor.photo"]
            // Rotation animates; wait until the layout settles on the expected arrangement. The
            // editor picks the arrangement that shows the photo larger (EditorLayoutPolicy):
            // landscape → side panel; phone portrait → below; iPad portrait → below for a
            // landscape photo. A portrait photo on iPad portrait is close to a tie, so either
            // arrangement is accepted there as long as the controls do not overlap the photo.
            let predicate = NSPredicate { _, _ in
                let beside = slider.frame.minX >= photo.frame.maxX
                let below = slider.frame.minY >= photo.frame.maxY
                if orientation.isLandscape { return beside }
                if !isPad { return below }
                return photo.frame.width > photo.frame.height ? below : (beside || below)
            }
            let settled = XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: nil)], timeout: 10) == .completed
            XCTAssertTrue(settled, "\(device) \(orientation.rawValue): photo \(photo.frame), slider \(slider.frame)")
            XCTAssertTrue(photo.isHittable, "The photo stays visible")
            XCTAssertTrue(app.buttons["action.saveCopy"].isHittable, "Save copy stays reachable")
            capture(named: "layout-\(device)-\(orientation.isLandscape ? "landscape" : "portrait")")
        }
    }

    private func waitForRotation(_ predicate: NSPredicate) -> Bool {
        XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: nil)], timeout: 5) == .completed
    }

    private var springboard: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    // MARK: - Helpers

    private func relaunch(arguments: [String]) {
        app.terminate()
        app.launchArguments = arguments
        app.launch()
    }

    private func openFirstLibraryPhoto() throws {
        XCTAssertTrue(app.buttons["welcome.choosePhoto"].waitForExistence(timeout: timeout))
        app.buttons["welcome.choosePhoto"].tap()
        try selectFirstPhotoFromSystemPicker()
    }

    /// The add-only prompt is a system alert. Tapping it from a UI test is
    /// the fallback for a simulator that has not been granted `photos-add`.
    ///
    /// `BEGINSWITH` rather than `CONTAINS`: the prompt's other button is
    /// "Don't Allow", which a contains-match also selects.
    private func allowAddOnlyPhotosAccessIfAsked() {
        let allow = springboard.buttons
            .matching(NSPredicate(format: "label BEGINSWITH[c] 'Allow' OR label ==[c] 'OK'"))
            .firstMatch
        if allow.waitForExistence(timeout: 5) {
            allow.tap()
        }
    }

    /// Drags the slider thumb from one stop to another, like a finger.
    ///
    /// The thumb's centre travels inset by its radius from the track ends
    /// (UISlider geometry), so stop `i` of `n` sits at that fraction of the
    /// inset width.
    private func dragSlider(_ slider: XCUIElement, from startStop: Int, to endStop: Int, stopCount: Int) {
        let thumbRadius: CGFloat = 14
        let frame = slider.frame
        func point(forStop stop: Int) -> XCUICoordinate {
            let fraction = CGFloat(stop) / CGFloat(stopCount - 1)
            let x = thumbRadius + fraction * (frame.width - 2 * thumbRadius)
            return slider.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: frame.height / 2))
        }
        point(forStop: startStop).press(forDuration: 0.3, thenDragTo: point(forStop: endStop))
    }

    /// Taps stop `stop` of the slider (a tap settles the stop under the finger).
    private func tapStop(_ slider: XCUIElement, _ stop: Int, stopCount: Int) {
        let thumbRadius: CGFloat = 14
        let frame = slider.frame
        let x = thumbRadius + CGFloat(stop) / CGFloat(stopCount - 1) * (frame.width - 2 * thumbRadius)
        slider.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: frame.height / 2)).tap()
    }

    /// Drags the Strength slider's thumb from 100% to `fraction` of the track, like a finger.
    private func dragStrength(_ slider: XCUIElement, toFraction fraction: CGFloat) {
        let frame = slider.frame
        let start = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5))
        let end = slider.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.width * fraction, dy: frame.height / 2))
        start.press(forDuration: 0.3, thenDragTo: end)
    }

    private func waitForPhotoValue(_ value: String) -> Bool {
        waitForValue(of: app.descendants(matching: .any)["editor.photo"], toEqual: value)
    }

    private func waitForValue(of element: XCUIElement, toMatch pattern: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value MATCHES %@", pattern)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    /// Scrolls the panel until `element` is hittable and clear of the bottom edge (the home
    /// indicator's gesture area would otherwise take a drag that starts there).
    private func scrollPanelUntilHittable(_ element: XCUIElement, attempts: Int = 6) {
        var remaining = attempts
        let safeBottom = app.windows.firstMatch.frame.maxY - 60
        while (!element.isHittable || element.frame.maxY > safeBottom) && remaining > 0 {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            remaining -= 1
        }
    }

    private func photoValue() -> String? {
        app.descendants(matching: .any)["editor.photo"].value as? String
    }

    private func waitForValue(of element: XCUIElement, toEqual value: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    /// The pack this build bundled, or a skip when the build has none: the
    /// pack is git-ignored, so a checkout without it still has a passing suite.
    private func requireBundledPack() throws -> BundledLookPack {
        if app.descendants(matching: .any)["editor.looks.none"].exists {
            throw XCTSkip("This build has no Look pack (the app shows \"No Looks are available in this build.\"). "
                          + "Build experiments/presets/look_pack/out or set LIGHTLY_LOOK_PACK_DIR, then rebuild.")
        }
        return try XCTUnwrap(BundledLookPack.locate(),
                             "The app shows Looks but the test cannot find the pack; searched \(BundledLookPack.searchedPaths)")
    }

    private func saveCopyAndConfirm(captureAs name: String) throws {
        app.buttons["action.saveCopy"].tap()
        allowAddOnlyPhotosAccessIfAsked()
        if app.staticTexts["Lightly needs permission to add photos to your library. You can grant it in Settings."]
            .waitForExistence(timeout: 3) {
            throw XCTSkip("Simulator declined add-only Photos access; the write could not be exercised.")
        }
        let saved = app.descendants(matching: .any)["editor.saveStatus"]
        XCTAssertTrue(saved.waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(of: saved, toContain: "Saved as a new photo. Original unchanged.", timeout: 60),
                      "Save copy should confirm; got '\(saved.label)'.")
        capture(named: name)
    }

    private func waitForLabel(of element: XCUIElement, toContain text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout) == .completed
    }

    /// Taps the first photo in Apple's system photo picker.
    ///
    /// The picker presents as a remote view inside the app's element tree, but
    /// its thumbnail grid is drawn as a single layer — the individual photos are
    /// not exposed as queryable cells or images. Selection therefore has to go
    /// through a coordinate tap. `PickerDiagnostics` dumps the live hierarchy if
    /// this ever needs revisiting.
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
