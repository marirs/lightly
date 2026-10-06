import XCTest
@testable import Lightly

/// SubjectMatte.refinedAtHair: the person matte trims the instance mask only in the hair zone around a face.
final class HairMatteTests: XCTestCase {
    func testWallBetweenCurlsIsRemovedNearTheFaceButAHeldObjectIsKept() {
        let w = 100, h = 100
        var instance = FloatImage(width: w, height: h, channels: 1, repeating: 0)
        var person = FloatImage(width: w, height: h, channels: 1, repeating: 0)
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            // The instance blob covers the head, the hair and an object far below-left (rows 85-95, columns 0-10).
            if (20..<70).contains(x) && (5..<60).contains(y) { instance.data[i] = 1; person.data[i] = 1 }
            if (0..<10).contains(x) && (85..<95).contains(y) { instance.data[i] = 1 }
        } }
        // A pocket of wall between the curls: the instance says subject, the person matte says background.
        for y in 8..<12 { for x in 30..<34 { person.data[y * w + x] = 0 } }
        let face = EditRecipe.Rect(x: 0.4, y: 0.25, width: 0.2, height: 0.25)
        let refined = SubjectMatte.refinedAtHair(instance: instance, person: person, faces: [face])
        XCTAssertEqual(refined.data[10 * w + 31], 0, accuracy: 1e-6, "the wall pocket in the hair zone becomes background")
        XCTAssertEqual(refined.data[30 * w + 50], 1, accuracy: 1e-6, "the face stays subject")
        XCTAssertEqual(refined.data[90 * w + 5], 1, accuracy: 1e-6, "an object outside the hair zone keeps the instance mask")
        XCTAssertEqual(SubjectMatte.refinedAtHair(instance: instance, person: person, faces: []).data, instance.data, "no face: unchanged")
    }
}
