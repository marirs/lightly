import XCTest
@testable import Lightly

/// Covers the edit-history structure required from day one by spec §27.
final class EditHistoryTests: XCTestCase {

    func testStartsEmptyAtTheOriginal() {
        let history = EditHistory()

        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.hasDevelopedVersion)
        XCTAssertNil(history.currentDevelopRecipe)
    }

    func testRecordsTheSpecifiedOperationSequence() {
        // The exact stack from spec §27:
        // Original → Develop → Look → Intensity → Crop → Repair
        var history = EditHistory()
        history.record(.develop(.unmodified))
        history.record(.look(id: "film.golden-memory", recipe: .unmodified))
        history.record(.intensity(0.8))
        history.record(.crop)
        history.record(.repair)

        XCTAssertEqual(history.operations.count, 5)
        XCTAssertTrue(history.hasDevelopedVersion)
    }

    func testUndoRemovesOnlyTheMostRecentOperation() {
        var history = EditHistory()
        history.record(.develop(.unmodified))
        history.record(.crop)

        let undone = history.undo()

        XCTAssertEqual(undone, .crop)
        XCTAssertEqual(history.operations, [.develop(.unmodified)])
        XCTAssertTrue(history.hasDevelopedVersion)
    }

    func testUndoAtTheOriginalIsANoOp() {
        var history = EditHistory()

        XCTAssertNil(history.undo())
        XCTAssertTrue(history.operations.isEmpty)
    }

    /// Intensity is stored separately from the Look recipe (spec §7), so
    /// reversing an intensity change must leave the Look itself applied.
    func testUndoingIntensityLeavesTheLookApplied() {
        var history = EditHistory()
        history.record(.look(id: "film.golden-memory", recipe: .unmodified))
        history.record(.intensity(0.4))

        history.undo()

        XCTAssertEqual(history.operations, [.look(id: "film.golden-memory", recipe: .unmodified)])
    }

    func testCurrentDevelopRecipeReturnsTheMostRecentDevelopment() {
        let first = DevelopRecipe.unmodified
        var second = DevelopRecipe.unmodified
        second.exposure = 0.5

        var history = EditHistory()
        history.record(.develop(first))
        history.record(.crop)
        history.record(.develop(second))

        XCTAssertEqual(history.currentDevelopRecipe, second)
    }

    func testResetReturnsToTheOriginal() {
        var history = EditHistory()
        history.record(.develop(.unmodified))
        history.record(.crop)

        history.reset()

        XCTAssertTrue(history.operations.isEmpty)
        XCTAssertFalse(history.hasDevelopedVersion)
    }
}

/// Covers the contextual toolbar rules in spec §4.5.
final class ContextualToolbarTests: XCTestCase {

    func testToolbarsMatchTheSpecification() {
        XCTAssertEqual(
            SceneKind.landscape.toolbar,
            [.looks, .magic, .repairTools, .blackAndWhite, .more]
        )
        XCTAssertEqual(
            SceneKind.portrait.toolbar,
            [.portrait, .looks, .magic, .repairTools, .more]
        )
        XCTAssertEqual(
            SceneKind.architecture.toolbar,
            [.perspective, .looks, .repairTools, .magic, .more]
        )
        XCTAssertEqual(
            SceneKind.night.toolbar,
            [.lowLight, .repairTools, .looks, .magic, .more]
        )
        XCTAssertEqual(
            SceneKind.monochrome.toolbar,
            [.tone, .grain, .repairTools, .more]
        )
    }

    /// Acceptance criterion: portrait tools stay hidden when no portrait is
    /// detected. Scene classification does not exist yet, so every photograph
    /// is unclassified — and must therefore not surface Portrait.
    func testPortraitToolsAreHiddenWithoutPortraitDetection() {
        for scene in SceneKind.allCases where scene != .portrait {
            XCTAssertFalse(
                scene.toolbar.contains(.portrait),
                "\(scene) must not offer Portrait tools."
            )
        }
    }
}
