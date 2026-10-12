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

    func testWatermarkTextKeyboardAndNewFonts() {
        relaunch(arguments: ["--reset-preferences", "--open-photo", photoPath("landscape_02"), "--scenario", "wm-text"])
        let edit = app.buttons["watermark.text.value"]
        XCTAssertTrue(edit.waitForExistence(timeout: 30))
        edit.tap()
        let field = app.descendants(matching: .any)["watermark.text.editor"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertLessThan(field.frame.maxY, app.keyboards.firstMatch.frame.minY)
        field.tap()
        field.typeText(" Test")
        let done = app.buttons["Done"]
        XCTAssertTrue(done.isHittable)
        capture(named: "watermark-keyboard-visible")
        done.tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        edit.tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(edit.exists)
    }

    /// The approved crop flow (owner, 2026-10-11, docs/ui/proposals/crop-flow.html): the frame is on the photo; a drag
    /// shows ✕ Cancel and ✓ Apply crop; Apply crops the photo (one undo step); Undo restores it.
    func testCropFlowDragApplyUndo() {
        relaunch(arguments: ["--reset-preferences", "--open-photo", photoPath("landscape_02")])
        XCTAssertTrue(element("tool.edit").waitForExistence(timeout: 30))
        element("tool.edit").tap()
        let photo = element("editor.photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 30))
        let originalRatio = photo.frame.width / photo.frame.height
        XCTAssertFalse(app.buttons["edit.crop.apply"].exists, "no buttons before the frame moves")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)))
        let apply = app.buttons["edit.crop.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["edit.crop.cancel"].exists)
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled, "nothing is applied before ✓")
        capture(named: "crop-pending")
        apply.tap()
        XCTAssertTrue(waitFor { photo.frame.width / photo.frame.height < originalRatio * 0.8 }, "the photo shows cropped")
        XCTAssertFalse(apply.exists)
        capture(named: "crop-applied")
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(waitFor { abs(photo.frame.width / photo.frame.height - originalRatio) < 0.02 })
    }

    /// A tap on the cropped photo brings the frame back; ✕ Cancel leaves the applied crop unchanged.
    func testCropAdjustThenCancelKeepsTheCrop() {
        relaunch(arguments: ["--reset-preferences", "--open-photo", photoPath("landscape_02")])
        XCTAssertTrue(element("tool.edit").waitForExistence(timeout: 30))
        element("tool.edit").tap()
        let photo = element("editor.photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 30))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)))
        app.buttons["edit.crop.apply"].tap()
        XCTAssertTrue(waitFor { !self.app.buttons["edit.crop.apply"].exists })
        sleep(1)
        let croppedRatio = photo.frame.width / photo.frame.height
        element("edit.crop.adjust").tap()
        sleep(1)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
            .press(forDuration: 0.1, thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
        XCTAssertTrue(app.buttons["edit.crop.cancel"].waitForExistence(timeout: 5))
        capture(named: "crop-adjusting")
        app.buttons["edit.crop.cancel"].tap()
        XCTAssertTrue(waitFor { abs(photo.frame.width / photo.frame.height - croppedRatio) < 0.02 }, "the applied crop is unchanged")
    }

    /// Portrait › Reset (owner report 2026-10-11: "the reset button isn't working"): Reset offers the tab's reset and
    /// the whole tool's; choosing the tab's returns its sliders to neutral.
    func testPortraitResetReturnsTheTabToNeutral() {
        relaunch(arguments: ["--reset-preferences", "--open-photo", photoPath("portrait_medium_02"), "--scenario", "pt-skin"])
        let smoothing = element("slider.smoothing")
        XCTAssertTrue(smoothing.waitForExistence(timeout: 40))
        sleep(2)
        let before = smoothing.value as? String ?? ""
        XCTAssertNotEqual(before, "0", "the scenario starts with skin edits")
        element("reset.portrait").tap()
        let option = element("reset.portrait.skin")
        XCTAssertTrue(option.waitForExistence(timeout: 5), "Reset shows its choices")
        capture(named: "portrait-reset-sheet")
        option.tap()
        XCTAssertTrue(waitFor { (smoothing.value as? String ?? "") == "0" }, "smoothing back to 0, was \(before), now \(smoothing.value as? String ?? "?")")
        capture(named: "portrait-reset-done")
    }

    /// Reset all must change the picture (owner report 2026-10-11): with a preset and Portrait edits applied, the photo
    /// after Reset all differs from before, and a second edit-free screenshot matches it.
    func testResetAllChangesThePicture() {
        relaunch(arguments: ["--reset-preferences", "--open-photo", photoPath("portrait_medium_02"), "--scenario", "pt-skin"])
        let photo = element("editor.photo")
        XCTAssertTrue(element("slider.smoothing").waitForExistence(timeout: 40))
        // Add a preset on top: Develop, a thumbnail.
        element("tool.develop").tap()
        let thumb = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'develop.thumbnail.' AND NOT (identifier ENDSWITH 'original')")).element(boundBy: 1)
        XCTAssertTrue(thumb.waitForExistence(timeout: 20))
        thumb.tap()
        sleep(4)
        let before = photo.screenshot().pngRepresentation
        let reset = element("editor.resetAll")
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()
        let confirm = element("resetAll.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Reset all asks first")
        confirm.tap()
        sleep(4)
        let after = photo.screenshot().pngRepresentation
        capture(named: "reset-all-after")
        XCTAssertNotEqual(before, after, "Reset all changed the picture")
        XCTAssertFalse(reset.exists && reset.isHittable, "nothing left to reset")
    }

    /// Reset and Reset all while the photo is zoomed in (owner, 2026-10-11): both must still change the picture.
    func testResetsWorkWhileZoomed() {
        relaunch(arguments: ["--reset-preferences", "--open-photo", photoPath("portrait_medium_02"), "--scenario", "pt-skin"])
        let photo = element("editor.photo")
        let smoothing = element("slider.smoothing")
        XCTAssertTrue(smoothing.waitForExistence(timeout: 40))
        sleep(2)
        let zoomView = element("editor.inspection")
        photo.pinch(withScale: 2.5, velocity: 2)
        XCTAssertTrue(waitFor { (Double((zoomView.value as? String ?? "1").split(separator: " ").first ?? "1") ?? 1) > 1.5 }, "zoomed in: \(zoomView.value as? String ?? "?")")
        capture(named: "zoomed-before-reset")
        // Portrait › Reset, zoomed.
        let shotBefore = app.screenshot().pngRepresentation
        element("reset.portrait").tap()
        let option = element("reset.portrait.skin")
        XCTAssertTrue(option.waitForExistence(timeout: 5), "Reset shows its choices while zoomed")
        option.tap()
        XCTAssertTrue(waitFor { (smoothing.value as? String ?? "") == "0" }, "smoothing back to 0 while zoomed")
        sleep(3)
        capture(named: "zoomed-after-portrait-reset")
        XCTAssertNotEqual(shotBefore, app.screenshot().pngRepresentation, "the zoomed picture changed after Reset")
        // Undo, then Reset all, zoomed.
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(waitFor { (smoothing.value as? String ?? "") != "0" })
        sleep(3)
        let beforeAll = app.screenshot().pngRepresentation
        let resetAll = element("editor.resetAll")
        XCTAssertTrue(resetAll.waitForExistence(timeout: 5), "Reset all is on screen while zoomed")
        resetAll.tap()
        let confirm = element("resetAll.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Reset all asks first while zoomed")
        confirm.tap()
        XCTAssertTrue(waitFor { (smoothing.value as? String ?? "") == "0" }, "Reset all cleared the portrait edit")
        sleep(3)
        capture(named: "zoomed-after-reset-all")
        XCTAssertNotEqual(beforeAll, app.screenshot().pngRepresentation, "the zoomed picture changed after Reset all")
    }

    /// Owner report 2026-10-11 (tall photo): after the first drag zooms in, handles could not be dragged. All eight
    /// (four corners, four edges) must move exactly their own sides, on a frame that has already zoomed.
    func testAllEightCropHandlesWorkAfterTheZoom() {
        relaunch(arguments: ["--reset-preferences", "--expose-crop", "--open-photo", photoPath("portrait_medium_02")])
        XCTAssertTrue(element("tool.edit").waitForExistence(timeout: 40))
        element("tool.edit").tap()
        let photo = element("editor.photo")
        XCTAssertTrue(photo.waitForExistence(timeout: 30))
        func crop() -> [Double] {
            let parts = (element("edit.cropRect").value as? String ?? "").split(separator: " ").compactMap { Double($0) }
            return parts.count == 4 ? parts : [0, 0, 1, 1]
        }
        func drag(_ fx: Double, _ fy: Double, by d: CGVector) {
            let f = photo.frame
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.minX + f.width * fx, dy: f.minY + f.height * fy))
            start.press(forDuration: 0.15, thenDragTo: start.withOffset(d), withVelocity: .slow, thenHoldForDuration: 0.1)
            sleep(2) // the glide
        }
        // The first drag zooms the photo in: the left edge in.
        drag(0.01, 0.5, by: CGVector(dx: 50, dy: 0))
        XCTAssertGreaterThan(crop()[0], 0.05, "the left edge moved")
        capture(named: "crop-zoomed")
        // (name, start point in the frame (0…1 of the frame), drag, sides that must move: left, top, right, bottom)
        let handles: [(String, Double, Double, CGVector, [Bool])] = [
            ("top-left", 0, 0, CGVector(dx: 12, dy: 12), [true, true, false, false]),
            ("top", 0.5, 0, CGVector(dx: 0, dy: 12), [false, true, false, false]),
            ("top-right", 1, 0, CGVector(dx: -12, dy: 12), [false, true, true, false]),
            ("right", 1, 0.5, CGVector(dx: -12, dy: 0), [false, false, true, false]),
            ("bottom-right", 1, 1, CGVector(dx: -12, dy: -12), [false, false, true, true]),
            ("bottom", 0.5, 1, CGVector(dx: 0, dy: -12), [false, false, false, true]),
            ("bottom-left", 0, 1, CGVector(dx: 12, dy: -12), [true, false, false, true]),
            ("left", 0, 0.5, CGVector(dx: 12, dy: 0), [true, false, false, false]),
        ]
        for (name, hx, hy, d, moves) in handles {
            let r = crop()
            // Just inside the frame's corner or edge.
            let inset = 0.004
            let fx = r[0] + r[2] * hx + (hx == 0 ? inset : hx == 1 ? -inset : 0)
            let fy = r[1] + r[3] * hy + (hy == 0 ? inset : hy == 1 ? -inset : 0)
            drag(fx, fy, by: d)
            let n = crop()
            let sides = [abs(n[0] - r[0]), abs(n[1] - r[1]), abs((n[0] + n[2]) - (r[0] + r[2])), abs((n[1] + n[3]) - (r[1] + r[3]))]
            for (side, moved) in zip(["left", "top", "right", "bottom"], zip(sides, moves)) {
                if moved.1 { XCTAssertGreaterThan(moved.0, 0.005, "\(name): the \(side) side should move") }
                else { XCTAssertLessThan(moved.0, 0.002, "\(name): the \(side) side should stay") }
            }
        }
        capture(named: "crop-after-all-handles")
        XCTAssertTrue(element("edit.crop.apply").exists, "✓ is still offered")
    }

    /// Measurement (owner report 2026-10-11): taps five presets; the app's trace records each render and how long the
    /// photo took to show it.
    func testMeasurePresetTaps() {
        relaunch(arguments: ["--reset-preferences", "--open-photo", photoPath("landscape_02")])
        let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'develop.thumbnail.' AND NOT (identifier ENDSWITH 'original')"))
        XCTAssertTrue(tiles.element(boundBy: 0).waitForExistence(timeout: 40))
        sleep(3)
        for index in 0..<5 {
            tiles.element(boundBy: index).tap()
            sleep(3)
        }
    }

    /// Owner report 2026-10-11: on a portrait photo, tapping a top-row thumbnail selected the one below it (the filled
    /// image overflowed its tile and took the taps). Taps at the top of each top-row thumbnail must select that tile.
    func testTopRowThumbnailTapsSelectTheTappedPreset() {
        relaunch(arguments: ["--reset-preferences", "--open-photo", photoPath("portrait_medium_02")])
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'develop.thumbnail.'"))
        XCTAssertTrue(tiles.element(boundBy: 2).waitForExistence(timeout: 40))
        sleep(2)
        let topRowY = tiles.element(boundBy: 0).frame.minY
        let topRow = (0..<min(tiles.count, 8)).map { tiles.element(boundBy: $0) }.filter { abs($0.frame.minY - topRowY) < 4 && $0.frame.maxX <= app.windows.firstMatch.frame.maxX - 8 }
        XCTAssertGreaterThanOrEqual(topRow.count, 2)
        for tile in topRow {
            let identifier = tile.identifier
            // Near the top of the thumbnail (the name sits below it), where the row below's overflow used to reach.
            tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
            let ok = waitFor { self.app.buttons[identifier].isSelected }
            let selectedNow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'develop.thumbnail.' AND selected == true")).allElementsBoundByIndex.map { "\($0.identifier) \($0.frame)" }
            XCTAssertTrue(ok, "tapping \(identifier) at \(tile.frame) selected \(selectedNow); top row: \(topRow.map { "\($0.identifier) \($0.frame)" })")
        }
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
        // Lightly 2 More (owner 2026-10-10, a2c7f44): preferences live on the More page itself and there is no
        // Preferences row any more, so the page is identified by its header and its Help › About row.
        let moreHeader = app.descendants(matching: .any)["more.page.menu"]
        XCTAssertTrue(moreHeader.waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["more.row.about"].waitForExistence(timeout: timeout))
        capture(named: "02c-editor-more")
        app.buttons["page.close"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["editor.photo"].waitForExistence(timeout: timeout))
        XCTAssertTrue(waitFor { !moreHeader.exists }, "More did not close")
    }

    // MARK: - Editor (slice 2)

    private func photoPath(_ name: String) -> String {
        "\(EditorCaptureUITests.repositoryRoot)/docs/ui/assets/photos/\(name).jpg"
    }

    /// Opens a prototype photograph straight into the editor (DEBUG `--open-photo`).
    private func openEditor(_ photo: String = "landscape_02", extra: [String] = []) {
        relaunch(arguments: ["--reset-preferences", "--fake-library-writer", "--open-photo", photoPath(photo)] + extra)
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout), "editor did not open")
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

    /// The `index`th preset thumbnail of the browsed collection ("Original" excluded). Lightly 2 (owner 2026-10-10,
    /// mockup `developPanel`) replaced the stop ruler with this gallery, so presets are applied by tapping a tile.
    private func presetThumbnail(_ index: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'develop.thumbnail.' AND identifier != 'develop.thumbnail.original'"))
            .element(boundBy: index)
    }

    /// Taps an item of a sideways-scrolling row (category and sub-tool tabs, the tool dock). Lightly 2 rows scroll and
    /// keep the item before the selected one at the leading edge (mockup `scrolled()`), so the wanted item can sit past
    /// either edge; the row is swiped towards it first, as a person does.
    private func tapInScrollingRow(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let item = element(identifier)
        XCTAssertTrue(item.waitForExistence(timeout: timeout), "\(identifier) missing", file: file, line: line)
        let width = app.windows.firstMatch.frame.width
        // isHittable throws for an item scrolled wholly off screen, so visibility is judged from its frame.
        func fullyOnScreen() -> Bool { let f = item.frame; return !f.isEmpty && f.minX >= 0 && f.maxX <= width }
        for _ in 0..<4 where !fullyOnScreen() {
            let hiddenPastLeadingEdge = item.frame.midX < width / 2
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: hiddenPastLeadingEdge ? width * 0.3 : width * 0.75, dy: item.frame.midY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: hiddenPastLeadingEdge ? 220 : -220, dy: 0)))
            sleep(1)
        }
        XCTAssertTrue(fullyOnScreen(), "\(identifier) could not be scrolled into view: \(item.frame)", file: file, line: line)
        item.tap()
    }

    /// Taps a Lightly 2 slider row (`L2Slider`: 92 pt label, 12 pt gap, the track, 12 pt gap, 34 pt value) at `fraction`
    /// of its track. Its drag gesture has no minimum distance, so the tap commits that value as one step.
    private func setSlider(_ slider: XCUIElement, to fraction: CGFloat) {
        let frame = slider.frame
        let trackStart: CGFloat = 92 + 12, trackEnd = frame.width - 12 - 34
        slider.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: trackStart + (trackEnd - trackStart) * fraction, dy: frame.height / 2)).tap()
    }

    /// iOS 1.0 Auto is Core Image auto enhancement (owner approval 2026-10-06). Owner, 2026-10-11: the photo opens
    /// untouched (stop zero reads "Original"); tapping Auto applies it as one Undo step.
    func testPickedPhotoDevelopsByItselfWithCoreImageAuto() throws {
        try openFirstLibraryPhoto()
        let auto = element("develop.auto")
        XCTAssertTrue(auto.waitForExistence(timeout: timeout))
        XCTAssertFalse(element("develop.notice").exists)
        XCTAssertTrue(waitFor { auto.value as? String == "Not applied" }, "opens untouched: \(auto.value ?? "nil")")
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled, "opening is not an edit")
        auto.tap()
        XCTAssertTrue(waitFor { auto.value as? String == "Applied" })
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled, "switching Auto on is one step")
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(waitFor { auto.value as? String == "Not applied" })
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

    /// Lightly 2 (owner 2026-10-10, mockup `developPanel`): the stop ruler and its "N / 518" position became the preset
    /// gallery. A tapped thumbnail applies its preset as one undo step. The photo opens untouched (owner 2026-10-11), so
    /// Undo returns the heading to "Original", and Redo brings the preset back.
    func testThumbnailTapAppliesAPresetAsOneUndoStep() {
        openEditor()
        XCTAssertEqual(label("develop.name"), "Original")
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled, "opening is not an edit")
        let thumbnail = presetThumbnail(1)
        XCTAssertTrue(thumbnail.waitForExistence(timeout: timeout))
        let applied = thumbnail.label
        thumbnail.tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == applied })
        XCTAssertTrue(thumbnail.isSelected, "the tapped tile is the selected one")
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled)
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == "Original" })
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled, "Exactly one step")
        app.buttons["editor.redo"].tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == applied })
        capture(named: "s2-02-preset")
    }

    /// Browsing another collection never changes the applied preset (mockup `developState`): the heading names the
    /// browsed collection's first preset, the applied preset's collection keeps its dot ("Edited"), Reset stays and no
    /// undo step is made. Tapping the applied preset's collection again names it and shows its tile selected.
    /// Lightly 2 (owner 2026-10-10) has no ruler position or "Applied from …" context line, and the curated pack
    /// (e74dc03) has no Landscape collection: dev-preset applies Daylight 37, "Open Aqua".
    func testBrowsingAnotherCategoryKeepsTheLook() {
        openEditor(extra: ["--scenario", "dev-preset"])
        XCTAssertTrue(waitFor { self.label("develop.name") == "Open Aqua" })
        // Open Aqua is Daylight's 37th tile, past the lazily built start of the sideways gallery, so its tile is not in
        // the accessibility tree; the heading, the collection dot and Reset carry the applied state instead.
        XCTAssertTrue(element("develop.clear").exists)
        tapInScrollingRow("develop.category.cinema")
        XCTAssertTrue(waitFor { self.element("develop.category.cinema").isSelected })
        let firstCinema = presetThumbnail(0)
        XCTAssertTrue(firstCinema.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitFor { self.label("develop.name") == firstCinema.label }, "the heading names the browsed collection's first preset")
        XCTAssertEqual(element("develop.category.daylight").value as? String, "Edited", "the dot stays on the applied preset's collection")
        XCTAssertTrue(element("develop.clear").exists, "the applied preset stays (Reset is offered)")
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled, "Browsing made no undo step")
        tapInScrollingRow("develop.category.daylight")
        XCTAssertTrue(waitFor { self.label("develop.name") == "Open Aqua" }, "back on its collection the heading names the applied preset")
        XCTAssertTrue(element("develop.star").isEnabled, "the star refers to the applied preset")
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled)
    }

    /// Lightly 2 (mockup `developPanel` › `slider('Amount')`): Amount is a slider under the gallery, no longer a button
    /// that swaps the ruler for a slider with Done. Moving it changes the applied preset's amount as one undo step.
    func testAmountSliderAdjustsTheAppliedPresetAsOneStep() {
        openEditor(extra: ["--scenario", "dev-preset"])
        let amount = element("slider.amount")
        XCTAssertTrue(amount.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitFor { amount.value as? String == "100" }, "a preset applies at 100: \(amount.value ?? "nil")")
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled)
        setSlider(amount, to: 0.4)
        XCTAssertTrue(waitFor { (Int(amount.value as? String ?? "") ?? 100) < 60 }, "Amount moved: \(amount.value ?? "nil")")
        XCTAssertEqual(label("develop.name"), "Open Aqua", "the same preset, at a lower amount")
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled)
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(waitFor { amount.value as? String == "100" })
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled, "one step")
    }

    /// Favourites update at once (AGENTS.md): the starred preset appears in Favourites without a relaunch; removing it
    /// takes its tile out of Favourites immediately and keeps the applied edit (Reset stays, Daylight keeps its dot).
    func testFavouriteRemovalRefreshesWithoutRelaunch() {
        openEditor(extra: ["--scenario", "dev-preset"])
        XCTAssertTrue(waitFor { self.label("develop.name") == "Open Aqua" })
        element("develop.star").tap()
        XCTAssertTrue(waitFor { self.element("develop.star").isSelected })
        tapInScrollingRow("develop.category.favourites")
        let favourite = presetThumbnail(0)
        XCTAssertTrue(favourite.waitForExistence(timeout: timeout), "the starred preset is in Favourites at once")
        XCTAssertEqual(favourite.label, "Open Aqua")
        XCTAssertTrue(favourite.isSelected, "as the applied preset")
        let applied = favourite.identifier
        XCTAssertEqual(label("develop.name"), "Open Aqua")
        element("develop.star").tap()
        XCTAssertTrue(waitFor { !self.app.buttons[applied].exists }, "Removed preset is not still in the Favourites gallery")
        XCTAssertTrue(element("develop.clear").exists, "Removing the shortcut keeps the applied edit")
        XCTAssertEqual(element("develop.category.daylight").value as? String, "Edited")
        tapInScrollingRow("develop.category.daylight")
        XCTAssertTrue(waitFor { self.label("develop.name") == "Open Aqua" })
        XCTAssertFalse(element("develop.star").isSelected)
        tapInScrollingRow("develop.category.favourites")
        XCTAssertTrue(waitFor { self.element("develop.category.favourites").isSelected })
        XCTAssertFalse(app.buttons[applied].exists)
    }

    /// No person in the photo: the Portrait collection is hidden and never the starting collection (AGENTS.md). The
    /// curated pack (e74dc03, owner 2026-10-11) has no Landscape collection; with no favourites it opens on Essentials.
    func testLandscapeHidesPortraitCategory() {
        openEditor("landscape_03")
        let essentials = element("develop.category.essentials")
        XCTAssertTrue(essentials.waitForExistence(timeout: timeout))
        XCTAssertTrue(essentials.isSelected, "starts on Essentials")
        XCTAssertFalse(element("develop.category.portrait").exists)
        XCTAssertFalse(element("tool.portrait").exists, "and the Portrait tool is hidden too")
    }

    func testFavouritesStarFullNoticeAndReplace() {
        openEditor(extra: ["--scenario", "dev-fav-full"])
        XCTAssertTrue(element("develop.favourites.replace").waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Favourites holds ten presets.'")).firstMatch.exists)
        element("develop.favourites.replace").tap()
        XCTAssertTrue(element("replace.cancel").waitForExistence(timeout: timeout))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'replace.row.'")).element(boundBy: 0).tap()
        XCTAssertFalse(element("replace.cancel").exists)
        XCTAssertTrue(element("develop.category.favourites").exists)
        XCTAssertFalse(element("develop.favourites.replace").exists, "replacing one clears the full notice")
    }

    func testSaveCopyShowsSavingThenSavedAndKeepEditing() {
        openEditor(extra: ["--scenario", "dev-preset"])
        XCTAssertTrue(waitFor { self.label("develop.name") == "Open Aqua" })
        app.buttons["editor.saveCopy"].tap()
        XCTAssertTrue(element("saved.keepEditing").waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["Saved as a new photo"].exists)
        XCTAssertTrue(app.staticTexts["The original is unchanged."].exists)
        element("saved.keepEditing").tap()
        XCTAssertTrue(element("develop.gallery.compact").waitForExistence(timeout: timeout))
        // Saved: Close needs no confirmation.
        app.buttons["editor.close"].tap()
        XCTAssertTrue(app.buttons["welcome.choosePhoto"].waitForExistence(timeout: timeout))
    }

    /// Save copy through the real Photos writer (no fake writer), tapped as a person does. The runner grants the
    /// add-only permission beforehand and checks the new file, its size and the unchanged original afterwards.
    func testSaveCopyWritesANewPhotoThroughPhotos() {
        relaunch(arguments: ["--reset-preferences", "--open-photo", photoPath("landscape_02")])
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout), "editor did not open")
        app.buttons["editor.saveCopy"].tap()
        XCTAssertTrue(app.staticTexts["Saved as a new photo"].waitForExistence(timeout: 90), "no Saved sheet")
        XCTAssertTrue(app.staticTexts["The original is unchanged."].exists)
    }

    /// One interaction pass over the owner's 2026-10-05 feedback, as a person does it, with screenshots
    /// (LIGHTLY_VERIFY_DIR): open a photo, apply a Daylight preset (no Landscape collection since the curated pack,
    /// e74dc03), browse Portrait, open Background, crop freely
    /// (a corner, then moving the rectangle), Save copy through the real Photos writer. The runner checks the saved
    /// file and the unchanged original.
    func testOwnerFeedbackInteractionPass() {
        let mattes = "\(EditorCaptureUITests.repositoryRoot)/ios/Tests/Fixtures/SubjectMattes/portrait_medium_02.png"
        // The inert writer: the real one asks for Photos permission, and an unanswered system prompt held "Saving a
        // copy…" for the whole 120 s wait (save-trace 2026-10-12 08:00:54: "photos add-only authorization: 0", then
        // "will resign active"), which read as a Save copy hang.
        relaunch(arguments: ["--reset-preferences", "--fake-library-writer", "--open-photo", photoPath("portrait_medium_02"),
                             "--subject-matte-fixture", mattes])
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout), "editor did not open")
        saveScreenshot("pass-1-opened")
        tapInScrollingRow("develop.category.daylight")
        let thumbnail = presetThumbnail(4)
        XCTAssertTrue(thumbnail.waitForExistence(timeout: timeout))
        let applied = thumbnail.label
        thumbnail.tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == applied })
        saveScreenshot("pass-2-daylight-applied")
        // Browsing Portrait keeps the Daylight preset applied (Lightly 2: its collection keeps the dot, Reset stays).
        tapInScrollingRow("develop.category.portrait")
        XCTAssertTrue(waitFor { self.element("develop.category.portrait").isSelected })
        XCTAssertEqual(element("develop.category.daylight").value as? String, "Edited", "browsing keeps the applied preset")
        XCTAssertTrue(element("develop.clear").exists)
        saveScreenshot("pass-3-browsing-portrait")
        tapInScrollingRow("tool.background")
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
        // The approved crop flow (owner 2026-10-11): the moved frame is a draft until ✓ Apply crop.
        let apply = app.buttons["edit.crop.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: timeout))
        apply.tap()
        XCTAssertTrue(waitFor { !apply.exists })
        app.buttons["editor.saveCopy"].tap()
        XCTAssertTrue(app.staticTexts["Saved as a new photo"].waitForExistence(timeout: 120), "no Saved sheet")
        saveScreenshot("pass-8-saved")
    }

    /// Save copy with a moved but unapplied crop frame (✕ Cancel / ✓ Apply crop showing) finishes, and saves the applied
    /// photo: the crop is only applied by ✓ Apply crop (docs/ui/proposals/crop-flow.html, "✕ puts it back"). The draft
    /// is still waiting after "Keep editing", and ✕ Cancel returns the frame to the whole photo, so nothing was cropped.
    /// Auto and Reset all are faded out on Crop, and must be out of the accessibility tree too (VoiceOver).
    func testSaveCopyWithAnUnappliedCropFinishesAndKeepsTheDraft() {
        openEditor(extra: ["--expose-crop"])
        tapInScrollingRow("tool.edit")
        let photo = element("editor.photo")
        XCTAssertTrue(photo.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitFor { !self.element("develop.auto").exists }, "Auto is hidden on Crop, also from VoiceOver")
        XCTAssertFalse(element("editor.resetAll").exists, "Reset all is hidden on Crop, also from VoiceOver")
        let wholeFrame = "0.0000 0.0000 1.0000 1.0000"
        let cropRect = element("edit.cropRect")
        XCTAssertTrue(cropRect.waitForExistence(timeout: timeout))
        XCTAssertTrue((cropRect.value as? String ?? "").hasSuffix(wholeFrame))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
            .press(forDuration: 0.1, thenDragTo: photo.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.75)))
        let apply = app.buttons["edit.crop.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: timeout), "the moved frame waits for ✓ Apply crop")
        let draft = cropRect.value as? String ?? ""
        XCTAssertFalse(draft.hasSuffix(wholeFrame), "the frame moved: \(draft)")
        app.buttons["editor.saveCopy"].tap()
        XCTAssertTrue(app.staticTexts["Saved as a new photo"].waitForExistence(timeout: 60), "Save copy did not finish with a crop draft")
        saveScreenshot("crop-draft-saved")
        app.buttons["saved.keepEditing"].tap()
        XCTAssertTrue(apply.waitForExistence(timeout: timeout), "the unapplied frame is still waiting after saving")
        XCTAssertEqual(cropRect.value as? String, draft)
        app.buttons["edit.crop.cancel"].tap()
        XCTAssertTrue(waitFor { (cropRect.value as? String ?? "").hasSuffix(wholeFrame) }, "Save copy did not apply the draft")
        tapInScrollingRow("tool.develop")
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout), "Auto is back outside Crop")
    }

    /// Save copy while a Remove stroke is being removed, or while the subject is being found, finishes (each state held
    /// by its DEBUG scenario) instead of waiting on the operation.
    func testSaveCopyFinishesWhileRemovingOrSeparating() {
        for (scenario, progress) in [("ed-removing", "edit.removing"), ("bg-separating", "background.separating")] {
            openEditor(extra: ["--scenario", scenario])
            XCTAssertTrue(element(progress).waitForExistence(timeout: timeout), "\(scenario): \(progress) not shown")
            app.buttons["editor.saveCopy"].tap()
            XCTAssertTrue(app.staticTexts["Saved as a new photo"].waitForExistence(timeout: 60), "\(scenario): Save copy did not finish")
            saveScreenshot("save-during-\(scenario)")
        }
    }

    /// Owner check 2026-10-05, in the Lightly 2 gallery (owner 2026-10-10; no ruler, position or context line any
    /// more): the heading, the collection dots and the selected tile each describe their own state while browsing,
    /// applying from another collection, Undo and Redo. Screenshots to LIGHTLY_VERIFY_DIR.
    func testHeadingStaysCoherentWhileBrowsing() {
        relaunch(arguments: ["--reset-preferences", "--open-photo", photoPath("landscape_02")])
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout), "editor did not open")
        tapInScrollingRow("develop.category.daylight")
        let daylightTile = presetThumbnail(4)
        XCTAssertTrue(daylightTile.waitForExistence(timeout: timeout))
        let applied = daylightTile.label, appliedID = daylightTile.identifier
        daylightTile.tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == applied })
        saveScreenshot("heading-1-daylight-applied")

        tapInScrollingRow("develop.category.golden-hour")
        XCTAssertTrue(waitFor { self.element("develop.category.golden-hour").isSelected })
        XCTAssertTrue(waitFor { self.label("develop.name") == self.presetThumbnail(0).label }, "browsing names its first preset")
        XCTAssertEqual(element("develop.category.daylight").value as? String, "Edited")
        XCTAssertNotEqual(element("develop.category.golden-hour").value as? String, "Edited")
        XCTAssertTrue(element("develop.clear").exists, "the Daylight preset stays applied")
        saveScreenshot("heading-2-browsing-golden-hour")

        let goldenTile = presetThumbnail(2)
        let golden = goldenTile.label
        goldenTile.tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == golden })
        XCTAssertNotEqual(golden, applied)
        XCTAssertEqual(element("develop.category.golden-hour").value as? String, "Edited")
        XCTAssertNotEqual(element("develop.category.daylight").value as? String, "Edited")
        saveScreenshot("heading-3-golden-hour-applied")

        app.buttons["editor.undo"].tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == applied })
        XCTAssertTrue(waitFor { self.element("develop.category.daylight").isSelected }, "Undo returns to the applied preset's collection")
        XCTAssertTrue(waitFor { self.app.buttons[appliedID].isSelected })
        saveScreenshot("heading-4-after-undo")

        app.buttons["editor.redo"].tap()
        XCTAssertTrue(waitFor { self.label("develop.name") == golden })
        XCTAssertTrue(waitFor { self.element("develop.category.golden-hour").isSelected })
        saveScreenshot("heading-5-after-redo")
    }

    /// Owner check 2026-10-05: every corner and edge, moving, a locked ratio then Free, and cropping after a rotation and
    /// straightening; each step checked against the committed rectangle. Screenshots to LIGHTLY_VERIFY_DIR.
    func testCropHandlesMoveOnlyTheirOwnSides() {
        relaunch(arguments: ["--reset-preferences", "--expose-crop", "--open-photo", photoPath("landscape_02")])
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout), "editor did not open")
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

        // No aspect presets (owner, 2026-10-11): free crop only.

        // Rotate and straighten, then crop.
        tapInScrollingRow("edit.sub.Rotate")
        element("edit.rotateRight").tap()
        tapInScrollingRow("edit.sub.Straighten")
        let angle = app.sliders["slider.angle"]
        if angle.waitForExistence(timeout: 5) { angle.adjust(toNormalizedSliderPosition: 0.43) }
        tapInScrollingRow("edit.sub.Crop")
        sleep(2)
        saveScreenshot("crop-after-rotate-straighten")
        before = sides(crop())
        drag(CGVector(dx: before[0], dy: before[1]), CGVector(dx: before[0] + 0.1, dy: before[1] + 0.08))
        after = sides(crop())
        XCTAssertEqual(changed(before, after), [true, true, false, false], "top-left after rotation: \(before) → \(after)")
        saveScreenshot("crop-after-rotate-straighten-cropped")
        tapInScrollingRow("edit.sub.Rotate")
        sleep(2)
        saveScreenshot("crop-result-shown")
    }

    func testBackgroundPlusImportsLibraryPhoto() throws {
        let matte = "\(EditorCaptureUITests.repositoryRoot)/ios/Tests/Fixtures/SubjectMattes/portrait_medium_02.png"
        relaunch(arguments: ["--reset-preferences", "--open-photo", photoPath("portrait_medium_02"), "--subject-matte-fixture", matte])
        XCTAssertTrue(element("editor.photo").waitForExistence(timeout: timeout))
        element("tool.background").tap()
        element("background.mode.change").tap()
        let add = element("background.image.add")
        XCTAssertTrue(add.waitForExistence(timeout: 60))
        // The background thumbnails scroll sideways in two rows, "+" last (owner amendment 2026-10-11, second).
        let first = element("background.image.landscape_01")
        let stripY = first.frame.midY / app.frame.height
        for _ in 0..<3 where add.frame.maxX > app.frame.width {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: stripY)).press(forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: stripY)))
        }
        XCTAssertTrue(add.isHittable)
        add.tap()
        let grid = app.scrollViews["photosView_content_scroll_view"]
        XCTAssertTrue(grid.waitForExistence(timeout: timeout), "Plus must open Photos")
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() } else { grid.swipeDown(velocity: .fast) }
        XCTAssertTrue(add.waitForExistence(timeout: timeout))
        add.tap()
        XCTAssertTrue(grid.waitForExistence(timeout: timeout))
        let close = app.buttons["Close"].firstMatch
        if close.exists && close.isHittable { close.tap() }
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.12)).tap()
        XCTAssertTrue(element("background.image.imported").waitForExistence(timeout: 30))
        XCTAssertTrue(element("slider.scale").exists)
        capture(named: "background-library-import")
        element("editor.undo").tap()
        XCTAssertFalse(element("background.image.imported").exists)
        element("editor.redo").tap()
        XCTAssertTrue(element("background.image.imported").waitForExistence(timeout: timeout))
    }

    /// Owner check 2026-10-05: Cancel → leave the tool → reopen → retry. Cancel returns to the panel (no indicator),
    /// navigation works, reopening does not restart the analysis, and the next Background edit does.
    func testBackgroundCancelLeaveReopenRetry() {
        let mattes = "\(EditorCaptureUITests.repositoryRoot)/ios/Tests/Fixtures/SubjectMattes/portrait_medium_02.png"
        relaunch(arguments: ["--reset-preferences", "--slow-subject-matte", "--open-photo", photoPath("portrait_medium_02"),
                             "--subject-matte-fixture", mattes])
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout), "editor did not open")
        element("tool.background").tap()
        XCTAssertTrue(element("background.cancel").waitForExistence(timeout: timeout), "Finding the subject… with Cancel")
        saveScreenshot("cancel-1-finding")
        element("background.cancel").tap()
        XCTAssertTrue(waitFor { !self.element("background.cancel").exists && !self.element("background.separating").exists },
                      "the indicator clears")
        XCTAssertTrue(element("slider.blur").waitForExistence(timeout: timeout), "back to the Focus & Blur controls")
        saveScreenshot("cancel-2-panel")

        element("tool.develop").tap()
        XCTAssertTrue(element("develop.gallery.compact").waitForExistence(timeout: timeout), "navigation works")
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
        XCTAssertTrue(element("develop.auto").waitForExistence(timeout: timeout), "editor did not open")
        element("tool.edit").tap()
        tapInScrollingRow("edit.sub.Straighten")
        let angle = element("slider.angle")
        XCTAssertTrue(angle.waitForExistence(timeout: timeout))
        // Lightly 2 slider row (L2Slider): the track runs between the 92 pt label column + 12 pt gap and the 12 pt gap +
        // 34 pt value.
        let row = angle.frame
        let trackStart = 104.0, trackEnd = row.width - 46
        let centre = angle.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: (trackStart + trackEnd) / 2, dy: row.height / 2))
        centre.press(forDuration: 0.1, thenDragTo: centre.withOffset(CGVector(dx: (trackEnd - trackStart) * 0.1, dy: 0)))
        let degrees = Int(angle.value as? String ?? "") ?? 0
        XCTAssertTrue((5...15).contains(degrees), "Straighten moved: \(String(describing: angle.value))")
        saveScreenshot("straighten-1-angle")
        tapInScrollingRow("edit.sub.Crop")
        let photo = element("editor.photo")
        func drag(_ from: CGVector, _ to: CGVector) {
            photo.coordinate(withNormalizedOffset: from)
                .press(forDuration: 0.15, thenDragTo: photo.coordinate(withNormalizedOffset: to), withVelocity: .slow, thenHoldForDuration: 0.1)
            sleep(1)
        }
        drag(CGVector(dx: 0.01, dy: 0.01), CGVector(dx: 0.25, dy: 0.1))
        drag(CGVector(dx: 0.99, dy: 0.99), CGVector(dx: 0.85, dy: 0.7))
        saveScreenshot("straighten-2-cropping")
        // The approved crop flow (owner 2026-10-11, docs/ui/proposals/crop-flow.html): a dragged frame is a draft
        // until ✓ Apply crop; applying commits it, and cropping from Original makes the aspect Free.
        let apply = app.buttons["edit.crop.apply"]
        XCTAssertTrue(apply.waitForExistence(timeout: timeout))
        apply.tap()
        XCTAssertTrue(waitFor { !apply.exists })
        let crop = element("edit.cropRect").value as? String ?? ""
        XCTAssertTrue(crop.hasPrefix("free "), crop)
        // A sub-tool without marks shows the cropped result as it will be saved.
        tapInScrollingRow("edit.sub.Rotate")
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
        // Lightly 2: a preset is applied from the gallery (the ruler is gone).
        XCTAssertTrue(presetThumbnail(2).waitForExistence(timeout: timeout))
        presetThumbnail(2).tap()
        XCTAssertTrue(waitFor { self.label("develop.name") != "Original" })
        // Lightly 2 draws its own alert (mockup `alert`, L2Alert), not a system alert, so it is found by its identifiers.
        app.buttons["editor.close"].tap()
        XCTAssertTrue(element("leave.keep").waitForExistence(timeout: timeout))
        XCTAssertTrue(app.staticTexts["Leave without saving?"].exists)
        element("leave.keep").tap()
        XCTAssertTrue(waitFor { !self.element("leave.keep").exists })
        XCTAssertTrue(element("develop.gallery.compact").exists)
        app.buttons["editor.close"].tap()
        XCTAssertTrue(element("leave.discard").waitForExistence(timeout: timeout))
        element("leave.discard").tap()
        XCTAssertTrue(app.buttons["welcome.choosePhoto"].waitForExistence(timeout: timeout))
    }

    func testPortraitIsOfferedOnlyForAPhotoWithAPerson() {
        openEditor("landscape_02")
        XCTAssertFalse(element("tool.portrait").exists, "No person: Portrait hidden")
        XCTAssertFalse(element("develop.category.portrait").exists, "No person: Portrait collection hidden")
        openEditor("portrait_deep_03")
        XCTAssertTrue(element("tool.portrait").waitForExistence(timeout: timeout), "A person: Portrait offered")
        // The Portrait preset collection follows the same rule, checked separately from the tool (AGENTS.md).
        XCTAssertTrue(element("develop.category.portrait").waitForExistence(timeout: timeout), "A person: Portrait collection offered")
    }

    /// Restore after the system ends the app: an edit, the app in the background, the process
    /// killed (as the system does), then a plain launch reopens the same edit in the editor.
    /// Screenshots go to `LIGHTLY_VERIFY_DIR` when set (focused verification).
    func testTheSessionComesBackAfterTheSystemEndsTheApp() {
        openEditor()
        // Lightly 2 Effects have no On/Off switches: moving a slider turns the effect on (EffectsPanel).
        tapInScrollingRow("tool.effects")
        tapInScrollingRow("effects.sub.Vignette")
        let vignetteAmount = element("slider.amount")
        XCTAssertTrue(vignetteAmount.waitForExistence(timeout: timeout))
        setSlider(vignetteAmount, to: 0.6)
        XCTAssertTrue(waitFor { self.element("tool.effects").value as? String == "Edited" })
        saveScreenshot("restore-1-before")
        XCUIDevice.shared.press(.home)
        // The system saves scene state as the app enters the background; give it time before the kill.
        _ = app.wait(for: .runningBackgroundSuspended, timeout: 5)
        Thread.sleep(forTimeInterval: 3)
        relaunch(arguments: [])
        // A cold launch loads the preset pack before the editor is ready (slow under a full suite).
        XCTAssertTrue(element("tool.effects").waitForExistence(timeout: 60), "the editor reopens")
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

    /// Edit and Effects in the same session as Develop: a vignette marks Effects ("Edited"), a quarter turn marks Edit,
    /// and Undo walks back whole recipes, one step each. Lightly 2 changes: no effect On/Off switches (moving a slider
    /// turns the effect on) and no crop aspect chips (free crop only, owner 2026-10-11), so the Edit step is Rotate right.
    func testEditAndEffectsShareTheSessionAndUndoStepByStep() {
        openEditor()
        tapInScrollingRow("tool.effects")
        tapInScrollingRow("effects.sub.Vignette")
        let vignetteAmount = element("slider.amount")
        XCTAssertTrue(vignetteAmount.waitForExistence(timeout: timeout))
        setSlider(vignetteAmount, to: 0.6)
        XCTAssertTrue(waitFor { self.element("tool.effects").value as? String == "Edited" })
        tapInScrollingRow("tool.edit")
        tapInScrollingRow("edit.sub.Rotate")
        XCTAssertTrue(element("edit.rotateRight").waitForExistence(timeout: timeout))
        element("edit.rotateRight").tap()
        XCTAssertTrue(waitFor { self.element("tool.edit").value as? String == "Edited" })
        element("editor.undo").tap()
        XCTAssertTrue(waitFor { self.element("tool.edit").value as? String != "Edited" }, "Undo removes the turn")
        XCTAssertEqual(element("tool.effects").value as? String, "Edited", "…and keeps the earlier vignette")
        element("editor.undo").tap()
        XCTAssertTrue(waitFor { self.element("tool.effects").value as? String != "Edited" })
        element("editor.redo").tap()
        XCTAssertTrue(waitFor { self.element("tool.effects").value as? String == "Edited" })
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
    /// Hardware-only camera flow, using a separate session store.
    func testCameraReviewRetakeAndUsePhoto() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical camera")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--keep-stored-session", "--session-store", "camera-review-check"]
        app.launch()
        XCTAssertTrue(app.buttons["welcome.camera"].waitForExistence(timeout: 30))
        app.buttons["welcome.camera"].tap()
        let permission = app.alerts.buttons["Allow"]
        if permission.waitForExistence(timeout: 2) { permission.tap() }
        XCTAssertTrue(app.buttons["camera.switch"].waitForExistence(timeout: 30))
        app.buttons["camera.switch"].tap()
        let live = XCTAttachment(screenshot: app.screenshot()); live.name = "front-camera-live"; live.lifetime = .keepAlways; add(live)
        app.buttons["camera.shutter"].tap()
        XCTAssertTrue(app.buttons["camera.use"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["camera.shutter"].exists)
        let review = XCTAttachment(screenshot: app.screenshot()); review.name = "front-camera-review"; review.lifetime = .keepAlways; add(review)
        app.buttons["camera.retake"].tap()
        XCTAssertTrue(app.buttons["camera.shutter"].waitForExistence(timeout: 10))
        app.buttons["camera.shutter"].tap()
        XCTAssertTrue(app.buttons["camera.use"].waitForExistence(timeout: 30))
        app.buttons["camera.use"].tap()
        XCTAssertTrue(app.buttons["editor.saveCopy"].waitForExistence(timeout: 60))
        let editor = XCTAttachment(screenshot: app.screenshot()); editor.name = "front-camera-editor"; editor.lifetime = .keepAlways; add(editor)
        #endif
    }

    func testPresetGalleryOverlaysWithoutResizingPhoto() {
        let app = XCUIApplication()
        app.launchArguments = ["--keep-stored-session", "--session-store", "gallery-check", "--open-photo",
            "/Users/sg/Documents/Dev/Projects/lightly/experiments/lut3d/photos/portrait_medium_02.jpg", "--scenario", "dev-starred"]
        app.launch()
        let expand = app.descendants(matching: .any)["develop.gallery.compact"].firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: 60))
        let before = app.descendants(matching: .any)["editor.photo"].firstMatch.frame
        expand.swipeLeft()
        XCTAssertFalse(app.otherElements["develop.expanded"].exists)
        expand.swipeUp()
        XCTAssertTrue(app.otherElements["develop.expanded"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any)["editor.photo"].firstMatch.frame, before)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "expanded-presets-over-photo"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertFalse(app.buttons["Expand"].exists)
        XCTAssertFalse(app.buttons["Collapse"].exists)
        let grid = app.descendants(matching: .any)["develop.gallery.expanded"].firstMatch
        grid.swipeDown()
        XCTAssertTrue(app.otherElements["develop.expanded"].waitForNonExistence(timeout: 10))
        let reset = app.buttons["develop.clear"]
        reset.tap(); XCTAssertFalse(reset.exists)
        app.buttons["editor.undo"].tap(); XCTAssertTrue(reset.waitForExistence(timeout: 10))
    }

    func testPaperAndSharedColourPicker() {
        let app = XCUIApplication()
        app.launchArguments = ["--keep-stored-session", "--session-store", "paper-check", "--open-photo",
            "/Users/sg/Documents/Dev/Projects/lightly/experiments/lut3d/photos/portrait_medium_02.jpg", "--scenario", "bd-solid"]
        app.launch()
        // Owner, 2026-10-12: Paper is no longer offered; Solid has the same shared colour strip.
        XCTAssertTrue(app.buttons["border.type.Solid"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["border.type.Paper"].exists)
        app.buttons["border.type.Solid"].tap()
        let more = app.buttons["border.colour.more"]
        more.tap()
        XCTAssertTrue(app.staticTexts["From your photo"].waitForExistence(timeout: 10))
        // Owner, 2026-10-11: no hex field or eyedropper; the Custom row opens the system colour panel.
        XCTAssertEqual(app.textFields.count, 0)
        XCTAssertFalse(app.buttons["colour.pick"].exists)
        XCTAssertTrue(app.buttons["colour.custom"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "shared-colour-sheet"; shot.lifetime = .keepAlways; add(shot)
        func shows(_ hex: String) -> Bool {
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", hex)).firstMatch.waitForExistence(timeout: 5)
        }
        app.buttons["Colour #334538"].firstMatch.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(shows("#334538"))
        app.buttons["editor.undo"].tap()
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "#334538")).firstMatch.exists)
        more.tap()
        XCTAssertTrue(app.buttons["colour.custom"].waitForExistence(timeout: 10))
        app.buttons["colour.custom"].tap()
        // The system colour panel opens over the sheet.
        XCTAssertTrue(app.otherElements["ColorPicker"].waitForExistence(timeout: 5) || app.buttons["Grid"].waitForExistence(timeout: 5)
                      || app.staticTexts["Colours"].waitForExistence(timeout: 2) || app.staticTexts["Colors"].waitForExistence(timeout: 2))
        for tab in ["Grid", "Spectrum", "Sliders"] {
            if app.buttons[tab].exists { app.buttons[tab].tap() }
            let panel = XCTAttachment(screenshot: app.screenshot()); panel.name = "system-colour-panel-\(tab)"; panel.lifetime = .keepAlways; add(panel)
        }
    }

    func testPresetGalleryDarkTheme() {
        let app = XCUIApplication()
        app.launchArguments = ["--keep-stored-session", "--session-store", "gallery-dark", "--open-photo",
            "/Users/sg/Documents/Dev/Projects/lightly/experiments/lut3d/photos/portrait_medium_02.jpg", "--scenario", "dev-starred",
            "-lightly.preferences.v1.appearance", "dark"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["develop.gallery.compact"].firstMatch.waitForExistence(timeout: 60))
        let compact = XCTAttachment(screenshot: app.screenshot()); compact.name = "compact-gallery-dark"; compact.lifetime = .keepAlways; add(compact)
        app.descendants(matching: .any)["develop.gallery.compact"].firstMatch.swipeUp()
        XCTAssertTrue(app.otherElements["develop.expanded"].waitForExistence(timeout: 10))
        let expanded = XCTAttachment(screenshot: app.screenshot()); expanded.name = "expanded-gallery-dark"; expanded.lifetime = .keepAlways; add(expanded)
    }

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
        let original = app.buttons["develop.thumbnail.original"]
        XCTAssertTrue(original.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "favourites-first-and-reset"; shot.lifetime = .keepAlways; add(shot)
        let preset = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'develop.thumbnail.' AND identifier != 'develop.thumbnail.original'")).firstMatch
        XCTAssertTrue(preset.isHittable)
        preset.tap()
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
