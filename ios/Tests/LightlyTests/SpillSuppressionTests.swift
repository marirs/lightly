import XCTest
@testable import Lightly

/// SpillSuppression (2026-10-08): the old background's cast leaves the soft edge only, and only when that background
/// is strongly coloured; opaque subject pixels and plain backgrounds are untouched.
final class SpillSuppressionTests: XCTestCase {

    /// 64 × 64: a saturated red wall on the left half, a black subject on the right, a 6 px soft edge between.
    private func scene(wall: SIMD3<Float>) -> (photo: FloatImage, matte: FloatImage) {
        let w = 64, h = 64
        var photo = FloatImage(width: w, height: h, channels: 3)
        var matte = FloatImage(width: w, height: h, channels: 1)
        for y in 0..<h {
            for x in 0..<w {
                let a = Float(min(max(x - 29, 0), 6)) / 6
                matte.data[y * w + x] = a
                let colour = wall * (1 - a)   // black subject over the wall
                for c in 0..<3 { photo.data[(y * w + x) * 3 + c] = colour[c] }
            }
        }
        return (photo, matte)
    }

    func testRedCastLeavesTheSoftEdge() throws {
        let (photo, matte) = scene(wall: SIMD3(0.6, 0.03, 0.03))
        let field = try XCTUnwrap(SpillSuppression.field(photo: photo, matte: matte))
        let i = 32 * 64 + 32   // a = 0.5: half wall, half black subject
        var subject = SIMD3(photo.data[i * 3], photo.data[i * 3 + 1], photo.data[i * 3 + 2])
        let sample = field.sample(x: 32, y: 32, frameWidth: 64, frameHeight: 64)
        SpillSuppression.apply(&subject, coverage: matte.data[i], direction: sample.direction, zone: sample.zone)
        XCTAssertEqual(subject.x, subject.y, accuracy: 0.01, "No red left: the subject colour is neutral")
        XCTAssertEqual(subject.y, subject.z, accuracy: 0.01)
    }

    func testOpaqueSubjectKeepsItsColour() throws {
        let (photo, matte) = scene(wall: SIMD3(0.6, 0.03, 0.03))
        let field = try XCTUnwrap(SpillSuppression.field(photo: photo, matte: matte))
        var skin = SIMD3<Float>(0.5, 0.25, 0.15)
        let sample = field.sample(x: 36, y: 32, frameWidth: 64, frameHeight: 64)
        SpillSuppression.apply(&skin, coverage: 1, direction: sample.direction, zone: sample.zone)
        XCTAssertEqual(skin, SIMD3(0.5, 0.25, 0.15))
    }

    func testPlainBackgroundsChangeNothing() {
        for wall in [SIMD3<Float>(0.9, 0.9, 0.88), SIMD3<Float>(0.2, 0.2, 0.21), SIMD3<Float>(0.01, 0.01, 0.01)] {
            let (photo, matte) = scene(wall: wall)
            XCTAssertNil(SpillSuppression.field(photo: photo, matte: matte), "\(wall)")
        }
    }

    func testFarFromTheEdgeNothingChanges() throws {
        let (photo, matte) = scene(wall: SIMD3(0.6, 0.03, 0.03))
        let field = try XCTUnwrap(SpillSuppression.field(photo: photo, matte: matte))
        XCTAssertEqual(field.sample(x: 2, y: 32, frameWidth: 64, frameHeight: 64).zone, 0, "Background far from the edge")
    }
}
