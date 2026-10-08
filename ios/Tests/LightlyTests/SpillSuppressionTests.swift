import XCTest
@testable import Lightly

/// Strong-background spill correction, protected subject interiors and observed hair-colour reconstruction.
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
    func testHairHueUsesObservedColourAndPreservesBrightness() {
        var edge = SIMD3<Float>(0.02,0.10,0.12)
        let mean = edge.sum()/3
        SpillSuppression.restoreHairHue(&edge, reference: SIMD4(1.5,1.0,0.5,1))
        XCTAssertEqual(edge.sum()/3,mean,accuracy:1e-6)
        XCTAssertEqual(edge.x/edge.y,1.5,accuracy:1e-6)
        XCTAssertEqual(edge.z/edge.y,0.5,accuracy:1e-6)
        let protected = edge
        SpillSuppression.restoreHairHue(&edge, reference:.zero)
        XCTAssertEqual(edge,protected)
    }

    func testOpaqueHairContaminationIsCorrectedWithoutChangingMatchingNaturalColour() {
        var contaminated = SIMD3<Float>(0.12, 0.02, 0.02)
        let brightness = contaminated.sum()/3
        SpillSuppression.restoreHairHue(&contaminated, reference: SIMD4(1,1,1,1), opaque: true)
        XCTAssertEqual(contaminated.x, contaminated.y, accuracy: 1e-6)
        XCTAssertEqual(contaminated.sum()/3, brightness, accuracy: 1e-6)
        var natural = SIMD3<Float>(0.3,0.2,0.1)
        SpillSuppression.restoreHairHue(&natural, reference: SIMD4(1.5,1,0.5,1), opaque: true)
        XCTAssertEqual(natural, SIMD3(0.3,0.2,0.1))
        var protectedSkin = SIMD3<Float>(0.5,0.25,0.15)
        SpillSuppression.restoreHairHue(&protectedSkin, reference: .zero, opaque: true)
        XCTAssertEqual(protectedSkin, SIMD3(0.5,0.25,0.15))
    }

}
