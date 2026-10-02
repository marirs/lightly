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

    // MARK: - Wide screens: controls beside the photo

    /// iPhone 17 landscape, iPad Pro 11-inch portrait and landscape (points, safe area ignored).
    static let wideCanvases: [(name: String, size: CGSize)] = [
        ("iPhone landscape", CGSize(width: 874, height: 402)),
        ("iPad portrait", CGSize(width: 834, height: 1_210)),
        ("iPad landscape", CGSize(width: 1_210, height: 834))
    ]

    func testWideScreensPutTheControlsBesideThePhoto() async throws {
        for (name, canvas) in Self.wideCanvases {
            let viewModel = try await EditorFixtures.readyEditor(lookStop: 1)
            let probe = layout(viewModel, size: .large, canvas: canvas)
            defer { probe.tearDown() }
            let panel = try XCTUnwrap(probe.frame("editor.sidePanel"), "\(name): no side panel; have \(probe.frames.keys.sorted())")
            let photo = try XCTUnwrap(probe.frame("editor.photo"), name)
            let area = try XCTUnwrap(probe.frame("editor.photoArea"), name)

            XCTAssertNil(probe.frame("editor.bottomControls"), "\(name): controls are not below the photo")
            XCTAssertTrue(EditorLayoutPolicy.sidePanelWidthRange.contains(panel.width.rounded()), "\(name): panel \(panel.width) pt")
            XCTAssertLessThanOrEqual(photo.maxX, panel.minX + 0.5, "\(name): the panel covers the photo")
            // The host window has safe-area insets, so "full height" is measured with some slack.
            XCTAssertGreaterThanOrEqual(panel.height, canvas.height * 0.85, "\(name): the panel runs the full height")
            XCTAssertGreaterThanOrEqual(area.height, canvas.height * 0.65, "\(name): the photo keeps most of the height")
            for anchor in ["editor.lookSlider", "editor.strength", "editor.control.action.undo", "editor.control.action.redo",
                           "editor.control.action.reset", "editor.control.action.compare", "editor.control.action.saveCopy"] {
                XCTAssertNotNil(probe.frame(anchor), "\(name): \(anchor) missing")
            }
        }
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
        let probe = layout(viewModel, size: .large, canvas: CGSize(width: 834, height: 1_210))
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
        XCTAssertEqual(Policy.arrangement(for: CGSize(width: 402, height: 874), isAccessibilitySize: false),
                       .stacked(panelMaximumHeight: 874 * 0.35, photoMinimumHeight: 874 * 0.4))
        XCTAssertEqual(Policy.arrangement(for: CGSize(width: 402, height: 874), isAccessibilitySize: true),
                       .stacked(panelMaximumHeight: 874 * 0.45, photoMinimumHeight: 874 * 0.4))
        XCTAssertEqual(Policy.arrangement(for: CGSize(width: 874, height: 402), isAccessibilitySize: false), .sidePanel(panelWidth: 320))
        XCTAssertEqual(Policy.arrangement(for: CGSize(width: 834, height: 1_210), isAccessibilitySize: false), .sidePanel(panelWidth: 320))
        XCTAssertEqual(Policy.arrangement(for: CGSize(width: 1_210, height: 834), isAccessibilitySize: false), .sidePanel(panelWidth: 380))
        XCTAssertEqual(Policy.arrangement(for: CGSize(width: 1_000, height: 1_366), isAccessibilitySize: false),
                       .sidePanel(panelWidth: 360), "Between the bounds the panel is 36% of the width")
        // Too narrow beside a 320 pt panel: stacked even though wider than tall.
        XCTAssertEqual(Policy.arrangement(for: CGSize(width: 600, height: 400), isAccessibilitySize: false),
                       .stacked(panelMaximumHeight: 400 * 0.35, photoMinimumHeight: 400 * 0.4))
        if case .sidePanel = Policy.arrangement(for: CGSize(width: 375, height: 1_210), isAccessibilitySize: false) {
            XCTFail("A narrow split view stacks")
        }
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
