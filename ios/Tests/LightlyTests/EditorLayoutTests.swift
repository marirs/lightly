import SwiftUI
import UIKit
import XCTest
@testable import Lightly

/// The photograph is the subject of the editor (spec D4): no control may
/// cover it, at any text size, and it must keep a usable share of the
/// screen even at the largest accessibility sizes.
@MainActor
final class EditorLayoutTests: XCTestCase {

    private func layout(
        _ viewModel: LUTEditorViewModel, size: DynamicTypeSize, canvas: CGSize = SnapshotAssertion.defaultSize
    ) -> LayoutProbe {
        LayoutProbe(EditorView(viewModel: viewModel, onBack: {}), size: canvas, dynamicTypeSize: size)
    }

    private func assertPhotoUncoveredAndVisible(
        _ viewModel: LUTEditorViewModel, size: DynamicTypeSize,
        minimumPhotoShare: CGFloat, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let probe = layout(viewModel, size: size)
        defer { probe.tearDown() }
        let photo = try XCTUnwrap(probe.frame("editor.photo"), "photo not laid out; have \(probe.frames.keys.sorted())", file: file, line: line)
        let controls = try XCTUnwrap(probe.frame("editor.bottomControls"), "controls not laid out at \(size)", file: file, line: line)

        let covered = photo.intersection(controls)
        XCTAssertTrue(covered.isNull || covered.height < 0.5,
                      "Controls cover \(covered.height) pt of the photo at \(size)", file: file, line: line)
        // The fixture photo is portrait (3:4), so its fitted height is the
        // limiting dimension.
        let share = photo.height / SnapshotAssertion.defaultSize.height
        XCTAssertGreaterThanOrEqual(share, minimumPhotoShare,
                                    "Photo is only \(Int(share * 100))% of the screen height at \(size)", file: file, line: line)
    }

    func testReadyEditorAtStandardSize() async throws {
        try assertPhotoUncoveredAndVisible(try await EditorFixtures.readyEditor(lookStop: 1), size: .large, minimumPhotoShare: 0.4)
    }

    /// Agreed UX: at accessibility sizes the photo keeps ≥ 40% of the height on a phone in
    /// portrait; the panel scrolls instead. (Was 20%: the panel could take half the screen.)
    func testReadyEditorAtAccessibility3() async throws {
        try assertPhotoUncoveredAndVisible(try await EditorFixtures.readyEditor(lookStop: 1), size: .accessibility3, minimumPhotoShare: 0.4)
    }

    func testReadyEditorAtAccessibility5() async throws {
        try assertPhotoUncoveredAndVisible(try await EditorFixtures.readyEditor(lookStop: 1), size: .accessibility5, minimumPhotoShare: 0.4)
    }

    func testDevelopingEditorAtAccessibility5() throws {
        let viewModel = try EditorFixtures.developingEditor()
        defer { viewModel.close() }
        try assertPhotoUncoveredAndVisible(viewModel, size: .accessibility5, minimumPhotoShare: 0.4)
    }

    /// The photo's area (not only a portrait photo) keeps 40% at AX5 with every notice showing.
    func testPhotoAreaKeepsFortyPercentAtAccessibility5WithNotices() async throws {
        let viewModel = try await EditorFixtures.readyEditor(lookStop: 1)
        viewModel.commitLookStrength(0.5)
        viewModel.saveCopy()
        await viewModel.saveTask?.value
        let probe = layout(viewModel, size: .accessibility5)
        defer { probe.tearDown() }
        let area = try XCTUnwrap(probe.frame("editor.photoArea"))
        XCTAssertGreaterThanOrEqual(area.height / SnapshotAssertion.defaultSize.height, 0.4)
    }

    /// Spec D4: the bottom panel takes at most 35% of the height on a
    /// compact screen at standard text size.
    func testBottomPanelStaysWithinItsShareAtStandardSize() async throws {
        let probe = layout(try await EditorFixtures.readyEditor(), size: .large)
        defer { probe.tearDown() }
        let controls = try XCTUnwrap(probe.frame("editor.bottomControls"))

        XCTAssertLessThanOrEqual(controls.height, SnapshotAssertion.defaultSize.height * 0.35 + 0.5)
    }

    /// Every edit action stays on screen (reachable) at AX5, scrolled or not.
    func testEveryActionIsLaidOutAtAccessibility5() async throws {
        let probe = layout(try await EditorFixtures.readyEditor(lookStop: 1), size: .accessibility5)
        defer { probe.tearDown() }
        for anchor in ["editor.lookSlider", "editor.strength", "editor.control.action.undo", "editor.control.action.redo",
                       "editor.control.action.reset", "editor.control.action.compare", "editor.control.action.saveCopy"] {
            XCTAssertNotNil(probe.frame(anchor), "\(anchor) missing at AX5; have \(probe.frames.keys.sorted())")
        }
    }

    /// A long preset name wraps onto more lines at large text instead of
    /// being truncated, and stays inside the panel.
    func testLongPresetNameWrapsAtAccessibility3() async throws {
        func stopNameFrame(category: String, stop: Int) async throws -> CGRect {
            let viewModel = try await EditorFixtures.readyEditor()
            viewModel.selectCategory(category)
            viewModel.settleStop(stop)
            let probe = layout(viewModel, size: .accessibility3)
            defer { probe.tearDown() }
            return try XCTUnwrap(probe.frame("editor.lookStopName"), "have \(probe.frames.keys.sorted())")
        }
        let short = try await stopNameFrame(category: "cat-gamma", stop: 1)          // "Fixture Fade"
        let long = try await stopNameFrame(category: "cat-beta", stop: 2)            // "Fixture Long Preset Name Tone (11)"

        XCTAssertGreaterThan(long.height, short.height * 1.5, "The long name should wrap, not truncate")
        XCTAssertLessThanOrEqual(long.maxX, SnapshotAssertion.defaultSize.width)
        XCTAssertGreaterThanOrEqual(long.minX, 0)
    }

    // MARK: - Arrangement chosen by displayed photo area

    static let phonePortrait = CGSize(width: 402, height: 874)
    static let phoneLandscape = CGSize(width: 874, height: 402)
    /// iPad Pro 11-inch (points, safe area ignored).
    static let padPortrait = CGSize(width: 834, height: 1_210)
    static let padLandscape = CGSize(width: 1_210, height: 834)

    /// (canvas, photo, expects the side panel). Portrait photo 3:4, landscape photo 4:3.
    static let arrangementCases: [(name: String, canvas: CGSize, landscapePhoto: Bool, sidePanel: Bool)] = [
        ("iPhone portrait, portrait photo", phonePortrait, false, false),
        ("iPhone portrait, landscape photo", phonePortrait, true, false),
        ("iPhone landscape, portrait photo", phoneLandscape, false, true),
        ("iPhone landscape, landscape photo", phoneLandscape, true, true),
        ("iPad portrait, landscape photo", padPortrait, true, false),
        // Not listed: a 3:4 photo on iPad portrait is within a few percent either way, so the
        // outcome depends on the host window's safe-area insets; `testLayoutPolicy` pins it for
        // an exact size instead.
        ("iPad landscape, landscape photo", padLandscape, true, true),
        ("iPad landscape, portrait photo", padLandscape, false, true)
    ]

    /// Laid out for real: the arrangement the policy picks is the one on screen, the panel never
    /// covers the photo, every action is reachable and Save copy is visible without scrolling.
    func testArrangementFollowsThePhotoAreaOnPhoneAndPad() async throws {
        for testCase in Self.arrangementCases {
            let photo = testCase.landscapePhoto ? EditorFixtures.landscapePhoto() : TestFixtures.makePhoto()
            let viewModel = try await EditorFixtures.readyEditor(lookStop: 1, photo: photo)
            let probe = layout(viewModel, size: .large, canvas: testCase.canvas)
            defer { probe.tearDown() }
            let name = testCase.name
            let photoFrame = try XCTUnwrap(probe.frame("editor.photo"), name)
            let area = try XCTUnwrap(probe.frame("editor.photoArea"), name)
            let save = try XCTUnwrap(probe.frame("editor.control.action.saveCopy"), "\(name): Save copy missing")

            if testCase.sidePanel {
                let panel = try XCTUnwrap(probe.frame("editor.sidePanel"), "\(name): no side panel; have \(probe.frames.keys.sorted())")
                XCTAssertNil(probe.frame("editor.bottomControls"), "\(name): controls are not below the photo")
                XCTAssertTrue(EditorLayoutPolicy.sidePanelWidthRange.contains(panel.width.rounded()), "\(name): panel \(panel.width) pt")
                XCTAssertLessThanOrEqual(photoFrame.maxX, panel.minX + 0.5, "\(name): the panel covers the photo")
                // The host window has safe-area insets, so "full height" is measured with some slack.
                XCTAssertGreaterThanOrEqual(panel.height, testCase.canvas.height * 0.85, "\(name): the panel runs the full height")
                XCTAssertGreaterThanOrEqual(area.height, testCase.canvas.height * 0.65, "\(name): the photo keeps most of the height")
            } else {
                let controls = try XCTUnwrap(probe.frame("editor.bottomControls"), "\(name): controls not below; have \(probe.frames.keys.sorted())")
                XCTAssertNil(probe.frame("editor.sidePanel"), name)
                XCTAssertLessThanOrEqual(photoFrame.maxY, controls.minY + 0.5, "\(name): the panel covers the photo")
                XCTAssertGreaterThanOrEqual(area.height, testCase.canvas.height * 0.4, "\(name): photo area ≥ 40%")
            }
            // Save copy sits in the top bar, inside the window, above the photo: never scrolled away.
            XCTAssertGreaterThanOrEqual(save.minY, 0, name)
            XCTAssertLessThanOrEqual(save.maxY, photoFrame.minY + 0.5, name)
            XCTAssertLessThanOrEqual(save.maxX, testCase.canvas.width + 0.5, name)
            for anchor in ["editor.lookSlider", "editor.strength", "editor.control.action.undo", "editor.control.action.redo",
                           "editor.control.action.reset", "editor.control.action.compare"] {
                XCTAssertNotNil(probe.frame(anchor), "\(name): \(anchor) missing")
            }
        }
    }

    /// The prime case of the design pass: on iPad portrait a landscape photo is shown larger with
    /// the controls below than squeezed beside a side panel.
    func testLandscapePhotoOnPadPortraitIsShownLargerWithControlsBelow() async throws {
        let viewModel = try await EditorFixtures.readyEditor(lookStop: 1, photo: EditorFixtures.landscapePhoto())
        let probe = layout(viewModel, size: .large, canvas: Self.padPortrait)
        defer { probe.tearDown() }
        let photo = try XCTUnwrap(probe.frame("editor.photo"))

        XCTAssertNotNil(probe.frame("editor.bottomControls"))
        // Beside a 320 pt panel the photo column would be 514 pt wide at most.
        XCTAssertGreaterThan(photo.width, Self.padPortrait.width - EditorLayoutPolicy.sidePanelWidthRange.lowerBound + 100,
                             "The photo uses the full width: \(photo.width) pt")
    }

    /// A narrow window on a large screen (iPad split view) stacks like a phone.
    func testNarrowSplitViewStacks() async throws {
        let viewModel = try await EditorFixtures.readyEditor(lookStop: 1)
        let probe = layout(viewModel, size: .large, canvas: CGSize(width: 375, height: 1_210))
        defer { probe.tearDown() }

        XCTAssertNotNil(probe.frame("editor.bottomControls"))
        XCTAssertNil(probe.frame("editor.sidePanel"))
    }

    func testLandscapePhoneAtAccessibility5KeepsThePhotoAndScrollsThePanel() async throws {
        let viewModel = try await EditorFixtures.readyEditor(lookStop: 1)
        let canvas = CGSize(width: 874, height: 402)
        let probe = layout(viewModel, size: .accessibility5, canvas: canvas)
        defer { probe.tearDown() }
        let panel = try XCTUnwrap(probe.frame("editor.sidePanel"))
        let photo = try XCTUnwrap(probe.frame("editor.photo"))

        XCTAssertLessThanOrEqual(photo.maxX, panel.minX + 0.5)
        XCTAssertLessThanOrEqual(panel.height, canvas.height + 0.5, "The panel scrolls rather than growing")
        XCTAssertGreaterThanOrEqual(photo.height, canvas.height * 0.6)
    }

    /// In a 320 pt side panel, five pack categories must not truncate: the chips wrap to more
    /// rows instead (a regression seen on iPad, "Nat…").
    func testCategoryChipsWrapRatherThanTruncateInTheSidePanel() async throws {
        let labels = ["Natural", "Warm", "Cool", "Film", "Mono"]
        let fixture = try LookPackFixture.write(labels.enumerated().map { index, label in
            LookPackFixture.Category(id: "cat-\(index)", label: label, looks: [
                LookPackFixture.Look(id: "look-\(index)", name: "Look \(index)", transform: LookPackFixture.warm)
            ])
        })
        defer { fixture.remove() }
        let viewModel = try await EditorFixtures.readyEditor(lookStop: 1, lookBook: fixture.load().book)
        // iPhone landscape: the narrowest (320 pt) side panel, whatever the photo's shape.
        let probe = layout(viewModel, size: .large, canvas: Self.phoneLandscape)
        defer { probe.tearDown() }

        let font = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        for (index, label) in labels.enumerated() {
            let chip = try XCTUnwrap(probe.frame("editor.category.cat-\(index)"))
            let needed = (label as NSString).size(withAttributes: [.font: font]).width + 2 * LightlySpacing.xs
            XCTAssertGreaterThanOrEqual(chip.width, needed, "\(label) would be truncated in a \(chip.width) pt chip")
        }
    }

    // MARK: - Policy

    func testLayoutPolicy() {
        typealias Policy = EditorLayoutPolicy
        let portrait: CGFloat = 3.0 / 4.0
        let landscape: CGFloat = 4.0 / 3.0
        func arrangement(_ size: CGSize, _ ratio: CGFloat, ax: Bool = false) -> Policy.Arrangement {
            Policy.arrangement(for: size, photoAspectRatio: ratio, isAccessibilitySize: ax)
        }
        let phone = Self.phonePortrait
        // Phone portrait: a side panel would leave 82 pt for the photo, so never; AX keeps 40%.
        XCTAssertEqual(arrangement(phone, portrait), .stacked(panelMaximumHeight: 874 * 0.35, photoMinimumHeight: 874 * 0.4))
        XCTAssertEqual(arrangement(phone, landscape), .stacked(panelMaximumHeight: 874 * 0.35, photoMinimumHeight: 874 * 0.4))
        XCTAssertEqual(arrangement(phone, portrait, ax: true), .stacked(panelMaximumHeight: 874 * 0.45, photoMinimumHeight: 874 * 0.4))
        // Phone landscape: either photo is larger beside a 320 pt panel.
        XCTAssertEqual(arrangement(Self.phoneLandscape, portrait), .sidePanel(panelWidth: 320))
        XCTAssertEqual(arrangement(Self.phoneLandscape, landscape), .sidePanel(panelWidth: 320))
        XCTAssertEqual(arrangement(Self.phoneLandscape, landscape, ax: true), .sidePanel(panelWidth: 320))
        // iPad portrait: controls below for a landscape photo (and, by area, a 3:4 one too).
        XCTAssertEqual(arrangement(Self.padPortrait, landscape), .stacked(panelMaximumHeight: 1_210 * 0.35, photoMinimumHeight: 1_210 * 0.4))
        XCTAssertEqual(arrangement(Self.padPortrait, portrait), .stacked(panelMaximumHeight: 1_210 * 0.35, photoMinimumHeight: 1_210 * 0.4))
        // A tall (9:16) photo on iPad portrait is larger beside the panel: area decides, not the device.
        XCTAssertEqual(arrangement(Self.padPortrait, 9.0 / 16.0), .sidePanel(panelWidth: 320))
        // iPad landscape: side panel (380 pt, the upper bound) for both shapes.
        XCTAssertEqual(arrangement(Self.padLandscape, landscape), .sidePanel(panelWidth: 380))
        XCTAssertEqual(arrangement(Self.padLandscape, portrait), .sidePanel(panelWidth: 380))
        // A very wide panorama on iPad landscape is larger full width.
        XCTAssertEqual(arrangement(Self.padLandscape, 3), .stacked(panelMaximumHeight: 834 * 0.35, photoMinimumHeight: 834 * 0.4))
        // Between the bounds the panel is 36% of the width.
        XCTAssertEqual(arrangement(CGSize(width: 1_000, height: 700), portrait), .sidePanel(panelWidth: 360))
        // Too narrow beside a 320 pt panel: stacked even though wider than tall.
        XCTAssertEqual(arrangement(CGSize(width: 600, height: 400), portrait), .stacked(panelMaximumHeight: 400 * 0.35, photoMinimumHeight: 400 * 0.4))
        // A narrow split view stacks whatever the photo.
        if case .sidePanel = arrangement(CGSize(width: 375, height: 1_210), 9.0 / 16.0) { XCTFail("A narrow split view stacks") }
        // A degenerate ratio does not crash or divide by zero.
        _ = arrangement(Self.padPortrait, 0)
    }

    /// Whatever it picks, the policy picks the arrangement with the larger displayed photo.
    func testThePolicyPicksTheLargerDisplayedPhoto() {
        typealias Policy = EditorLayoutPolicy
        let sizes = [Self.phonePortrait, Self.phoneLandscape, Self.padPortrait, Self.padLandscape,
                     CGSize(width: 1_000, height: 700), CGSize(width: 700, height: 1_000), CGSize(width: 1_366, height: 1_024)]
        for size in sizes {
            for ratio: CGFloat in [9.0 / 16.0, 3.0 / 4.0, 1, 4.0 / 3.0, 16.0 / 9.0, 3] {
                for ax in [false, true] {
                    let chosen = Policy.arrangement(for: size, photoAspectRatio: ratio, isAccessibilitySize: ax)
                    let share = ax ? Policy.accessibilityPanelShare : Policy.standardPanelShare
                    let stacked = Policy.Arrangement.stacked(panelMaximumHeight: size.height * share, photoMinimumHeight: size.height * Policy.photoMinimumShare)
                    let panelWidth = Policy.sidePanelWidth(forContainerWidth: size.width)
                    let chosenArea = Policy.displayedPhotoArea(for: chosen, in: size, photoAspectRatio: ratio)
                    XCTAssertGreaterThanOrEqual(chosenArea, Policy.displayedPhotoArea(for: stacked, in: size, photoAspectRatio: ratio), "\(size) \(ratio)")
                    if size.width - panelWidth >= Policy.minimumPhotoWidthBesidePanel {
                        let side = Policy.displayedPhotoArea(for: .sidePanel(panelWidth: panelWidth), in: size, photoAspectRatio: ratio)
                        XCTAssertGreaterThanOrEqual(chosenArea, side, "\(size) \(ratio)")
                    } else {
                        XCTAssertEqual(chosen, stacked, "\(size): no room for a panel beside the photo")
                    }
                }
            }
        }
    }

    func testFittedArea() {
        XCTAssertEqual(EditorLayoutPolicy.fittedArea(aspectRatio: 4.0 / 3.0, in: CGSize(width: 400, height: 600)), 400 * 300, accuracy: 0.01)
        XCTAssertEqual(EditorLayoutPolicy.fittedArea(aspectRatio: 3.0 / 4.0, in: CGSize(width: 400, height: 400)), 300 * 400, accuracy: 0.01)
        XCTAssertEqual(EditorLayoutPolicy.fittedArea(aspectRatio: 1, in: CGSize(width: 0, height: 400)), 0)
    }

    // MARK: - Indicators

    func testStrengthIsLaidOutOnlyWhileALookIsApplied() async throws {
        let without = layout(try await EditorFixtures.readyEditor(), size: .large)
        XCTAssertNil(without.frame("editor.strength"))
        without.tearDown()

        let with = layout(try await EditorFixtures.readyEditor(lookStop: 1), size: .large)
        defer { with.tearDown() }
        let strength = try XCTUnwrap(with.frame("editor.strength"))
        let slider = try XCTUnwrap(with.frame("editor.lookSlider"))
        XCTAssertGreaterThan(strength.minY, slider.maxY, "Secondary: below the preset slider")
    }

    func testOriginalBadgeShowsOnThePhotoOnlyWhileComparing() async throws {
        let viewModel = try await EditorFixtures.readyEditor(lookStop: 1)
        let editing = layout(viewModel, size: .large)
        XCTAssertNil(editing.frame("editor.originalBadge"))
        editing.tearDown()

        viewModel.toggleCompare()
        let comparing = layout(viewModel, size: .large)
        defer { comparing.tearDown() }
        let badge = try XCTUnwrap(comparing.frame("editor.originalBadge"))
        let photo = try XCTUnwrap(comparing.frame("editor.photo"))
        XCTAssertTrue(photo.insetBy(dx: -0.5, dy: -0.5).contains(badge), "The badge is on the photo: \(badge) in \(photo)")
    }

    func testSaveCopyIsInTheTopBarAboveThePhoto() async throws {
        let probe = layout(try await EditorFixtures.readyEditor(), size: .large)
        defer { probe.tearDown() }
        let save = try XCTUnwrap(probe.frame("editor.control.action.saveCopy"))
        let photo = try XCTUnwrap(probe.frame("editor.photo"))
        XCTAssertLessThanOrEqual(save.maxY, photo.minY)
    }

    func testStepMarkersSitOnePerStopAndSpanTheTrack() {
        let positions = SteppedTrack.stopPositions(count: 5, width: 300)
        XCTAssertEqual(positions.count, 5)
        XCTAssertEqual(positions.first, SteppedTrack.thumbDiameter / 2)
        XCTAssertEqual(positions.last, 300 - SteppedTrack.thumbDiameter / 2)
        let gaps = zip(positions.dropFirst(), positions).map { $0 - $1 }
        XCTAssertTrue(gaps.allSatisfy { abs($0 - gaps[0]) < 0.001 }, "Evenly spaced")
        XCTAssertEqual(SteppedTrack.nearestStop(to: positions[3] + 10, positions: positions), 3)
        XCTAssertEqual(SteppedTrack.nearestStop(to: -50, positions: positions), 0)
        XCTAssertEqual(SteppedTrack.nearestStop(to: 999, positions: positions), 4)
        // Drags are relative to the stop where they began and clamp at the ends.
        let spacing = positions[1] - positions[0]
        XCTAssertEqual(SteppedTrack.stop(from: 1, dragged: 2 * spacing + 5, positions: positions), 3)
        XCTAssertEqual(SteppedTrack.stop(from: 4, dragged: 40, positions: positions), 4, "Right from the last stays last")
        XCTAssertEqual(SteppedTrack.stop(from: 2, dragged: -10 * spacing, positions: positions), 0)
        XCTAssertEqual(SteppedTrack.stop(from: 2, dragged: 0.4 * spacing, positions: positions), 2)
    }
}
