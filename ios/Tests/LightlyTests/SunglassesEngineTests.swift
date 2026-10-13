import UIKit
import Vision
import XCTest
@testable import Lightly

/// Portrait › Sunglasses engine (rendering-v2 §7.5) against the trial reference (experiments/sunglasses): the bundled pack,
/// the Core ML landmarker on the trial photos (shared/fixtures/sunglasses/*.reference.json, from landmarks3.py on the same
/// Vision face boxes), and whole renders written to $TMPDIR/lightly-sunglasses for review against the trial sheets.
final class SunglassesEngineTests: XCTestCase {

    static let photos: [(dir: String, name: String)] = [
        ("experiments/lut3d/photos", "portrait_deep_02"), ("experiments/lut3d/photos", "portrait_medium_02"),
        ("experiments/test-photos", "glasses_side_angle_01"), ("experiments/test-photos", "profile_bw_woman_01"),
    ]

    private struct Reference: Decodable {
        let box: [Double]
        let landmarks: [[Float]]
        let faceLogit: Float
    }

    func testThePackHoldsTheTenApprovedPairsAndEveryOneLoads() throws {
        let pack = try XCTUnwrap(SunglassesPack.bundled, "SunglassesPack/ is bundled (scripts/bundle_sunglasses_pack.sh)")
        XCTAssertEqual(pack.pairs.map(\.name), ["Oval", "Club", "Pilot", "Aviator", "Bridge", "Wayfarer", "Sport", "Round", "Square", "Panto"])
        for pair in pack.pairs {
            let loaded = try pack.load(pair)
            XCTAssertEqual(loaded.mesh.materialIndices.count, loaded.mesh.geometry.elements.count, pair.name)
            XCTAssertTrue(pair.materials.contains { $0.role == .lens }, "\(pair.name) has lenses")
            XCTAssertNotNil(pack.thumbnail(pair), pair.name)
        }
    }

    func testTheLSGReaderRejectsAnOutOfRangeIndex() {
        var data = Data("LSG1".utf8)
        for value: UInt32 in [1, 1, 1] { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(Data(count: 32))                                   // one vertex
        for value: UInt32 in [0, 3, 0, 0, 7] { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        XCTAssertThrowsError(try SunglassesPack.decodeLSG(data, materialCount: 1))
    }

    func testLandmarksMatchTheTrialReferenceAndRendersAreWritten() async throws {
        let analyzer = try XCTUnwrap(SunglassesAnalyzer.loadBundled(), "the two Core ML models are bundled")
        let pack = try XCTUnwrap(SunglassesPack.bundled)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lightly-sunglasses")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (dir, name) in Self.photos {
            let image = try XCTUnwrap(UIImage(contentsOfFile: DevelopParityTests.fixture("\(dir)/\(name).jpg").path)?.cgImage)
            let (rgba, W, H) = Self.rgba8(image)
            let references = try JSONDecoder().decode([Reference].self, from: Data(contentsOf: DevelopParityTests.fixture(
                "shared/fixtures/sunglasses/\(name).reference.json")))
            let faces = try Self.visionFaces(image)
            XCTAssertEqual(faces.count, references.count, name)
            var analyses: [FaceSunglassesAnalysis] = []
            for (face, reference) in zip(faces, references) {
                let started = Date()
                let analysis = try analyzer.analyse(.init(rgba: rgba, width: W, height: H), faceBox: face.box, eyes: face.eyes)
                print("sunglasses-timing \(name) analyse \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                analyses.append(analysis)
                // Within 1 % of the iris span at the median and 6 % at worst: fp16 Core ML against fp32 LiteRT, and
                // Vision on iOS against Vision on macOS for the starting crop.
                let d = analysis.irisSpan
                let errors = zip(analysis.landmarks, reference.landmarks).map { simd_distance(SIMD2($0.x, $0.y), SIMD2($1[0], $1[1])) / d }
                    .sorted()
                // Frontal photos only: on turned faces the starting crop differs between Vision on iOS and on macOS and
                // another roll can win, so those are judged by their renders.
                if name.hasPrefix("portrait_deep_02") {
                    XCTAssertLessThan(errors[errors.count / 2], 0.01, "\(name) median landmark error")
                    XCTAssertLessThan(errors.last!, 0.06, "\(name) worst landmark error")
                }
                XCTAssertEqual(analysis.isReadable, reference.faceLogit >= 0, name)
            }
            // The poses and landmarks, for review against the reference (experiments/sunglasses/wear.py).
            let maps = SunglassesRenderer.Maps(analyses: analyses, scale: 1)
            let report = analyses.map { a -> [String: Any] in
                let pose = SunglassesRenderer.pose(landmarks: a.landmarks, width: W, height: H, background: maps.background)
                return ["yaw": atan2(pose.ez.x, pose.ez.z) * 180 / .pi, "isProfile": pose.isProfile, "logit": a.faceLogit,
                        "landmarks": a.landmarks.map { [$0.x, $0.y, $0.z] }]
            }
            try JSONSerialization.data(withJSONObject: report).write(to: out.appendingPathComponent("\(name).ios.json"))
            // Render the Wayfarer on every face and write it next to the photo for review.
            var linear = FloatImage.linear(fromRGBA8: rgba, width: W, height: H)
            let wayfarer = try XCTUnwrap(pack.pairs.first { $0.name == "Wayfarer" })
            // A face wearing glasses gets them painted out first (LaMa, as Remove), stored by digest.
            let store = RemovePatchStore()
            var edits: [(edit: EditRecipe.FaceEdit, analysis: FaceSunglassesAnalysis)] = []
            for analysis in analyses {
                var edit = PortraitPanelModel.neutral(for: nil)
                var removed: EditRecipe.FaceEdit.Sunglasses.Removed?
                if analysis.glassesMask() != nil, let lama = LamaInpainter.loadBundled(),
                   let result = try await SunglassesRemoval.patch(for: analysis, source: image, inpainter: lama) {
                    let digest = store.add(result.patch)
                    removed = .init(rect: result.rect, patch: .init(sha256: digest, model: lama.model, width: result.patch.width,
                                                                     height: result.patch.height))
                }
                XCTAssertEqual(removed != nil, name.hasPrefix("glasses_"), "\(name): glasses found exactly on the photo with glasses")
                edit.sunglasses = .init(pair: wayfarer.id, lens: .dark, darkness: 75, size: 0, removed: removed)
                edits.append((edit, analysis))
            }
            let renderStarted = Date()
            SunglassesRenderer.render(&linear, faces: edits, allAnalyses: analyses, pack: pack, removedPatch: store.patch)
            print("sunglasses-timing \(name) render \(W)x\(H) \(Int(Date().timeIntervalSince(renderStarted) * 1000)) ms")
            let png = UIImage(cgImage: Self.cgImage(linear.rgba8FromLinear(), width: W, height: H)).pngData()!
            try png.write(to: out.appendingPathComponent("\(name).ios.png"))
        }
        print("Sunglasses renders: \(out.path)")
    }

    /// The frame pass at a fixed pose, written for comparison with render_lsg.swift on macOS (same SceneKit scene).
    func testFixedPoseFramePassIsWrittenForComparison() throws {
        let pack = try XCTUnwrap(SunglassesPack.bundled)
        let pair = try XCTUnwrap(pack.pairs.first { $0.name == "Wayfarer" })
        // 800 × 600 canvas, pair at the centre, 3000 px per metre, facing the camera.
        let pose = SunglassesRenderer.Pose(ex: SIMD3(1, 0, 0), ey: SIMD3(0, 1, 0), ez: SIMD3(0, 0, 1), pixelsPerMetre: 1500,
                                           origin: SIMD3(0, 0, 0), isProfile: false)
        var landmarks = [SIMD3<Float>](repeating: SIMD3(400, 300, 5000), count: 478)   // face mesh far behind: no occlusion
        landmarks[0] = SIMD3(400, 300, 5000)
        let passes = try SunglassesRenderer.renderPasses(pair: pair, pack: pack, pose: pose, size: 0, landmarks: landmarks, width: 800, height: 600)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lightly-sunglasses")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let png = UIImage(cgImage: Self.cgImage(passes.frame, width: passes.width, height: passes.height)).pngData()!
        try png.write(to: out.appendingPathComponent("fixed-frame-\(passes.x0)-\(passes.y0)-\(passes.width)x\(passes.height).png"))
    }

    // MARK: - Helpers

    static func rgba8(_ image: CGImage) -> ([UInt8], Int, Int) {
        let W = image.width, H = image.height
        var pixels = [UInt8](repeating: 0, count: W * H * 4)
        pixels.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                .draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        }
        return (pixels, W, H)
    }

    static func cgImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage {
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Vision face boxes (normalised, origin top-left) and pupil (else eye) centres in pixels, as the trial's pose.swift.
    static func visionFaces(_ image: CGImage) throws -> [(box: EditRecipe.Rect, eyes: (SIMD2<Float>, SIMD2<Float>))] {
        let W = Double(image.width), H = Double(image.height)
        let request = VNDetectFaceLandmarksRequest()
        OnDeviceSceneAnalyser.preferCPUInSimulator(request)
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { face in
            func centre(_ region: VNFaceLandmarkRegion2D?) -> SIMD2<Float>? {
                guard let points = region?.pointsInImage(imageSize: CGSize(width: W, height: H)), !points.isEmpty else { return nil }
                let x = points.map(\.x).reduce(0, +) / CGFloat(points.count), y = points.map(\.y).reduce(0, +) / CGFloat(points.count)
                return SIMD2(Float(x), Float(H - y))
            }
            guard let left = centre(face.landmarks?.leftPupil ?? face.landmarks?.leftEye),
                  let right = centre(face.landmarks?.rightPupil ?? face.landmarks?.rightEye) else { return nil }
            let b = face.boundingBox
            return (EditRecipe.Rect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height), (left, right))
        }
    }
}
