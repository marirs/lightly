import XCTest
@testable import Lightly

/// Portrait's dim rings when no face can be edited (prototype `marksFor`): the faces are marked; person rectangles
/// only when no face was found. The bar photo's lamp, detected as a person on Android, must get no ring.
final class PeopleMarksTests: XCTestCase {
    private func face(quality: Float) -> DetectedFace {
        DetectedFace(box: .init(x: 0.45, y: 0.56, width: 0.09, height: 0.06), faceContour: [],
                     leftEye: [CGPoint(x: 0.47, y: 0.58)], rightEye: [CGPoint(x: 0.51, y: 0.58)], leftEyebrow: [], rightEyebrow: [],
                     outerLips: [CGPoint(x: 0.49, y: 0.6)], innerLips: [], quality: quality)
    }
    private let lamp = EditRecipe.Rect(x: 0.29, y: 0, width: 0.3, height: 0.18)

    func testUnusableFacesAreMarkedAndAPersonRectangleElsewhereIsNot() {
        let bar = PeopleAnalysis(faces: [face(quality: 0.05)], people: [lamp])
        XCTAssertTrue(bar.hasPerson)
        XCTAssertTrue(bar.usableFaces.isEmpty)
        XCTAssertEqual(bar.unusableMarks, [face(quality: 0.05).box])
    }

    func testAPersonWithoutAFaceIsMarkedByTheirRectangle() {
        XCTAssertEqual(PeopleAnalysis(faces: [], people: [lamp]).unusableMarks, [lamp])
    }

    func testNoDimRingsWhenAFaceCanBeEdited() {
        XCTAssertEqual(PeopleAnalysis(faces: [face(quality: 0.8)], people: [lamp]).unusableMarks, [])
    }
}
