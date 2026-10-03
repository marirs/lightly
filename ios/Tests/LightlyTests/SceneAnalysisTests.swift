import CoreGraphics
import ImageIO
import XCTest
@testable import Lightly

/// Vision and the depth model on real photographs, in the simulator (CPU).
final class SceneAnalysisTests: XCTestCase {

    static func photo(_ path: String, maxLongEdge: Int = 1_024) throws -> CGImage {
        let url = DevelopParityTests.fixture(path)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxLongEdge]
        return try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
    }

    private let analyser = OnDeviceSceneAnalyser(depthEstimators: DepthEstimatorProvider())

    /// The licensed multi-person test photo (experiments/test-photos): three faces, each usable,
    /// ordered left to right.
    func testThreeFacesInTheGroupPhoto() async throws {
        let image = try Self.photo("experiments/test-photos/group_three_01.jpg")
        let people = await analyser.people(in: image)
        XCTAssertEqual(people.faces.count, 3, "\(people.faces.map(\.box))")
        XCTAssertEqual(people.usableFaces.count, 3)
        XCTAssertEqual(people.faces.map(\.box.x), people.faces.map(\.box.x).sorted())
        for face in people.faces {
            XCTAssertFalse(face.leftEye.isEmpty)
            XCTAssertFalse(face.outerLips.isEmpty)
        }
    }

    func testOneFaceInAPortraitAndNoneInALandscape() async throws {
        let portrait = await analyser.people(in: try Self.photo("docs/ui/assets/photos/portrait_deep_03.jpg"))
        XCTAssertEqual(portrait.usableFaces.count, 1)
        let landscape = await analyser.people(in: try Self.photo("docs/ui/assets/photos/landscape_02.jpg"))
        XCTAssertFalse(landscape.hasPerson)
    }

    func testSubjectMatteCoversThePerson() async throws {
        let image = try Self.photo("docs/ui/assets/photos/portrait_deep_03.jpg", maxLongEdge: 512)
        let matte: SubjectMatte?
        do {
            matte = try await analyser.subjectMatte(for: image)
        } catch {
            #if targetEnvironment(simulator)
            // Vision's foreground mask cannot run in the Simulator ("Could not create inference
            // context"); this test needs a device. Reported as pending, not passed.
            throw XCTSkip("VNGenerateForegroundInstanceMaskRequest is unavailable in the Simulator: \(error.localizedDescription)")
            #else
            throw error
            #endif
        }
        let m = try XCTUnwrap(matte).matte
        XCTAssertEqual(m.width, image.width)
        // The face (prototype face box x .37–.65, y .09–.39) is subject; the top corners are not.
        XCTAssertGreaterThan(m.data[Int(0.25 * Float(m.height)) * m.width + Int(0.51 * Float(m.width))], 0.5)
        XCTAssertLessThan(m.data[Int(0.03 * Float(m.height)) * m.width + Int(0.03 * Float(m.width))], 0.5)
    }

    /// The bundled Core ML depth model: the person (near) gets higher disparity than the backdrop.
    func testDepthModelPutsThePersonInFront() async throws {
        let image = try Self.photo("docs/ui/assets/photos/portrait_deep_03.jpg", maxLongEdge: 512)
        guard DepthEstimator.loadBundled() != nil else {
            throw XCTSkip("This build has no depth model (experiments/depth/models not present or the gate is closed)")
        }
        let map = try await analyser.disparity(for: image, originalData: Data())
        XCTAssertEqual(map.source, .estimated)
        let d = map.disparity
        func at(_ x: Float, _ y: Float) -> Float { d.data[Int(y * Float(d.height - 1)) * d.width + Int(x * Float(d.width - 1))] }
        XCTAssertGreaterThan(at(0.51, 0.6), at(0.04, 0.04) + 0.2)
    }

    func testAPhotoWithoutEmbeddedDepthHasNone() throws {
        let data = try Data(contentsOf: DevelopParityTests.fixture("docs/ui/assets/photos/landscape_02.jpg"))
        XCTAssertNil(OnDeviceSceneAnalyser.embeddedDisparity(from: data, size: (10, 10)))
    }
}
