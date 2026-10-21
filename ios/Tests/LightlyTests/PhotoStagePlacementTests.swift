import CoreGraphics
import SwiftUI
import XCTest
@testable import Lightly

/// Owner amendment (2026-10-20, layout approved 2026-10-21): a Polaroid print keeps clear of Auto and Reset all. Same cases
/// as Android's PhotoActionsClearanceTest, so both platforms place the print identically.
final class PhotoStagePlacementTests: XCTestCase {
    private typealias Stage = PhotoStage<EmptyView, EmptyView>
    /// A 3:2 landscape photo in a Polaroid (sides and top 0.055, bottom 0.24 of the width): 1.11 × 0.962.
    private let landscapePolaroid = CGSize(width: 1.11, height: 2.0 / 3.0 + 0.055 + 0.24)
    /// Auto (38) + 6 + Reset all: 150 pt in all.
    private let autoAndResetAll: CGFloat = 150

    func testAPrintThatOverlapsTheButtonsIsRaisedWhenThatIsEnough() {
        let inner = CGSize(width: 390, height: 400)
        let placed = Stage.placement(image: landscapePolaroid, in: inner, photoActionsWidth: autoAndResetAll)
        XCTAssertEqual(placed.size, Stage.fittedSize(image: landscapePolaroid, in: inner), "raising keeps the size")
        XCTAssertEqual((inner.height + placed.size.height) / 2 + placed.liftY, inner.height - 60, accuracy: 0.01)
    }

    func testAPrintShrinksOnlyAsMuchAsNeededToClearTheRow() {
        let inner = CGSize(width: 390, height: 300)
        let placed = Stage.placement(image: landscapePolaroid, in: inner, photoActionsWidth: autoAndResetAll)
        XCTAssertEqual(placed.size.height, 240, accuracy: 0.01)
        XCTAssertEqual((inner.height - placed.size.height) / 2 + placed.liftY, 0, accuracy: 0.01, "top-aligned at the inset")
    }

    func testResetAllCountsTowardsTheOverlap() {
        let inner = CGSize(width: 390, height: 400)
        let tall = CGSize(width: 0.7, height: 1)
        XCTAssertEqual(Stage.placement(image: tall, in: inner, photoActionsWidth: 38).liftY, 0, "beside Auto alone")
        let placed = Stage.placement(image: tall, in: inner, photoActionsWidth: autoAndResetAll)
        XCTAssertEqual(placed.size.height, 340, accuracy: 0.01)
    }

    func testANarrowPrintShrinksToSitBesideTheButtonsWhenThatKeepsItLarger() {
        let inner = CGSize(width: 390, height: 400)
        let placed = Stage.placement(image: CGSize(width: 0.75, height: 1), in: inner, photoActionsWidth: 38)
        XCTAssertEqual(placed.size.width, 390 - 2 * 54, accuracy: 0.01)
        XCTAssertEqual(placed.liftY, 0)
    }

    func testWithoutAPolaroidThePhotoKeepsThePlainFit() {
        let inner = CGSize(width: 390, height: 400)
        let placed = Stage.placement(image: landscapePolaroid, in: inner, photoActionsWidth: nil)
        XCTAssertEqual(placed.size, Stage.fittedSize(image: landscapePolaroid, in: inner))
        XCTAssertEqual(placed.liftY, 0)
    }
}
