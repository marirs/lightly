import XCTest
@testable import Lightly

final class LocalHairMattingTests: XCTestCase {
    func testRecoversKnownColourMixtureAndKeepsTrimapAnchors() throws {
        let w = 40, h = 12
        let expected = (0..<(w*h)).map { Double(min(20, max(0, $0 % w - 10))) / 20 }
        let foreground = [0.9, 0.2, 0.1], background = [0.1, 0.3, 0.8]
        var rgb = [Double]()
        for a in expected { for c in 0..<3 { rgb.append(a*foreground[c]+(1-a)*background[c]) } }
        let trimap = (0..<(w*h)).map { $0 % w < 6 ? 0.0 : $0 % w >= 34 ? 1.0 : Double.nan }
        let result = try LocalHairMatting.solve(rgb: rgb, trimap: trimap, width: w, height: h,
                                                initial: [Double](repeating: 0.5, count: w*h), tolerance: 1e-7)
        XCTAssertTrue(result.converged)
        for i in expected.indices { XCTAssertEqual(result.alpha[i], expected[i], accuracy: 0.001, "pixel \(i)") }
    }

    func testCancellationPropagatesInsteadOfAdoptingPartialMatte() {
        XCTAssertThrowsError(try LocalHairMatting.solve(rgb: [Double](repeating: 0.5, count: 300),
            trimap: [Double](repeating: .nan, count: 100), width: 10, height: 10,
            initial: [Double](repeating: 0.5, count: 100), checkpoint: { throw CancellationError() })) {
                XCTAssertTrue($0 is CancellationError)
            }
    }

    func testUnknownPixelBudgetKeepsExistingMatteWithoutAllocatingSparseSystem() throws {
        let initial = [Double](repeating: 0.4, count: 100)
        let result = try LocalHairMatting.solve(rgb: [Double](repeating: 0.5, count: 300),
            trimap: [Double](repeating: .nan, count: 100), width: 10, height: 10,
            initial: initial, maximumUnknownPixels: 50)
        XCTAssertFalse(result.converged)
        XCTAssertEqual(result.iterations, 0)
        XCTAssertEqual(result.alpha, initial)
    }

    func testHeadRefinementDoesNotTouchFaceEarsClothingOrCropSeam() {
        let face = CGRect(x: 100, y: 100, width: 50, height: 60)
        let crop = CGRect(x: 25, y: 0, width: 200, height: 250)
        for y in stride(from: 95.0, through: 160, by: 5) {
            for x in stride(from: 90.0, through: 160, by: 5) {
                XCTAssertEqual(HairDetailRefinement.weight(x: x, y: y, region: crop, face: face), 0)
            }
        }
        XCTAssertEqual(HairDetailRefinement.weight(x: 50, y: 190, region: crop, face: face), 0)
        XCTAssertEqual(HairDetailRefinement.weight(x: 25, y: 60, region: crop, face: face), 0)
        XCTAssertGreaterThan(HairDetailRefinement.weight(x: 80, y: 60, region: crop, face: face), 0.9)
    }
    func testFaceProtectionUsesTopLeftImageCoordinates() {
        let face = DetectedFace(box: .init(x: 0.3, y: 0.6, width: 0.4, height: 0.3),
            faceContour: [CGPoint(x: 0.3,y: 0.65), CGPoint(x: 0.32,y: 0.8), CGPoint(x: 0.4,y: 0.9),
                          CGPoint(x: 0.6,y: 0.9), CGPoint(x: 0.68,y: 0.8), CGPoint(x: 0.7,y: 0.65)],
            leftEye: [], rightEye: [], leftEyebrow: [], rightEyebrow: [], outerLips: [], innerLips: [], quality: nil)
        let mask = HairDetailRefinement.protectionMask(faces: [face], region: CGRect(x: 0,y: 0,width: 100,height: 100),
            width: 100,height: 100,sourceWidth: 100,sourceHeight: 100)
        XCTAssertEqual(mask.data[75*100+50], 1, "cheek must be protected")
        XCTAssertEqual(mask.data[20*100+50], 0, "hair above the face must remain refinable")
        XCTAssertEqual(mask.data[75*100+10], 0, "side background must remain refinable")
    }

    func testNeutralBackdropDoesNotTriggerColourRefinement() {
        let alpha = FloatImage(width: 10,height: 10,channels: 1,data: [Float](repeating: 0,count: 100))
        XCTAssertFalse(HairDetailRefinement.hasChromaticBackground(rgb: [Double](repeating: 0.05,count: 300),alpha: alpha))
        let red = (0..<100).flatMap { _ in [0.8,0.1,0.1] }
        XCTAssertTrue(HairDetailRefinement.hasChromaticBackground(rgb: red,alpha: alpha))
        let opaque = FloatImage(width: 10,height: 10,channels: 1,data: [Float](repeating: 1,count: 100))
        XCTAssertFalse(HairDetailRefinement.hasChromaticBackground(rgb: red,alpha: opaque), "Subject colour must not be used as background evidence")
    }

}
