import SceneKit
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

    /// A wrong platform eye line (group selfie 2026-10-14: −38° face, eye points giving +47°) must not hide the upright
    /// tries; an upright eye line adds none.
    func testRollTriesAlsoCoverUpright() {
        let degrees = { (r: Float) in r * 180 / .pi }
        XCTAssertEqual(SunglassesAnalyzer.rollCandidates(platformRoll: 0).count, 7)
        let skewed = SunglassesAnalyzer.rollCandidates(platformRoll: 47 * .pi / 180).map(degrees)
        for wanted: Float in [-45, -30, -15, 0] {
            XCTAssertTrue(skewed.contains { abs($0 - wanted) < 7.5 }, "\(wanted)° tried: \(skewed)")
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
            let rendered = linear.rgba8FromLinear()
            let png = UIImage(cgImage: Self.cgImage(rendered, width: W, height: H)).pngData()!
            try png.write(to: out.appendingPathComponent("\(name).ios.png"))
            try Self.writeParityFixture(name: name, analyses: analyses, edits: edits.map(\.edit), rendered: rendered, width: W, height: H, to: out)
        }
        print("Sunglasses renders: \(out.path)")
    }

    /// Diagnostic for a group selfie (owner report 2026-10-14: pairs off on the left and middle faces): writes the photo
    /// with each face's Vision box, the landmarker's starting crop, and the landmarks it returned, plus a render with
    /// Oval, Club and Wayfarer as on the owner's screen. Review only: no assertions.
    func testGroupSelfieDiagnosticIsWritten() throws {
        let analyzer = try XCTUnwrap(SunglassesAnalyzer.loadBundled())
        let pack = try XCTUnwrap(SunglassesPack.bundled)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lightly-sunglasses")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let full = try XCTUnwrap(UIImage(contentsOfFile: DevelopParityTests.fixture("experiments/test-photos/group_three_01.jpg").path)?.cgImage)
        // As the editor: the 1600 px preview, and eye centres from Vision's eye outlines (EditorSession.ensureSunglassesAnalysis).
        let image = try XCTUnwrap(AnalysisProxy.downscaled(full, maximumLongEdge: 1_600))
        let (rgba, W, H) = Self.rgba8(image)
        let faces = try Self.editorFaces(image)
        let analyses = try faces.map { try analyzer.analyse(.init(rgba: rgba, width: W, height: H), faceBox: $0.box, eyes: $0.eyes) }
        var marked = rgba
        func dot(_ x: Float, _ y: Float, _ r: Int, _ colour: (UInt8, UInt8, UInt8)) {
            for dy in -r...r { for dx in -r...r where dx * dx + dy * dy <= r * r {
                let px = Int(x) + dx, py = Int(y) + dy
                guard px >= 0, py >= 0, px < W, py < H else { continue }
                let i = (py * W + px) * 4
                marked[i] = colour.0; marked[i + 1] = colour.1; marked[i + 2] = colour.2
            } }
        }
        func rect(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ colour: (UInt8, UInt8, UInt8)) {
            var t: Float = 0
            while t <= 1 { dot(x0 + (x1 - x0) * t, y0, 1, colour); dot(x0 + (x1 - x0) * t, y1, 1, colour)
                           dot(x0, y0 + (y1 - y0) * t, 1, colour); dot(x1, y0 + (y1 - y0) * t, 1, colour); t += 0.002 }
        }
        var report: [[String: Any]] = []
        let maps = SunglassesRenderer.Maps(analyses: analyses, scale: 1)
        for (face, a) in zip(faces, analyses) {
            let bx = Float(face.box.x) * Float(W), by = Float(face.box.y) * Float(H)
            let bw = Float(face.box.width) * Float(W), bh = Float(face.box.height) * Float(H)
            rect(bx, by, bx + bw, by + bh, (0, 255, 0))
            let side = max(bw, bh) * SunglassesConstants.initialCropScale
            rect(bx + bw / 2 - side / 2, by + bh / 2 - side / 2, bx + bw / 2 + side / 2, by + bh / 2 + side / 2, (255, 255, 0))
            for p in a.landmarks.prefix(468) { dot(p.x, p.y, 1, (255, 255, 255)) }
            for i in [33, 263] { dot(a.landmarks[i].x, a.landmarks[i].y, 4, (0, 120, 255)) }
            for i in [468, 473] { dot(a.landmarks[i].x, a.landmarks[i].y, 4, (255, 0, 0)) }
            for i in [10, 152] { dot(a.landmarks[i].x, a.landmarks[i].y, 4, (255, 0, 255)) }
            dot(face.eyes.0.x, face.eyes.0.y, 3, (0, 255, 0)); dot(face.eyes.1.x, face.eyes.1.y, 3, (0, 255, 0))
            let pose = SunglassesRenderer.pose(landmarks: a.landmarks, width: W, height: H, background: maps.background)
            report.append(["box": [face.box.x, face.box.y, face.box.width, face.box.height], "logit": a.faceLogit,
                           "visionEyes": [[face.eyes.0.x, face.eyes.0.y], [face.eyes.1.x, face.eyes.1.y]],
                           "iris": [[a.landmarks[468].x, a.landmarks[468].y], [a.landmarks[473].x, a.landmarks[473].y]],
                           "corners": [[a.landmarks[33].x, a.landmarks[33].y], [a.landmarks[263].x, a.landmarks[263].y]],
                           "ex": [pose.ex.x, pose.ex.y, pose.ex.z], "ez": [pose.ez.x, pose.ez.y, pose.ez.z],
                           "rollDegrees": atan2(pose.ex.y, pose.ex.x) * 180 / .pi, "yawDegrees": atan2(pose.ez.x, pose.ez.z) * 180 / .pi,
                           "pixelsPerMetre": pose.pixelsPerMetre, "isProfile": pose.isProfile])
        }
        try UIImage(cgImage: Self.cgImage(marked, width: W, height: H)).pngData()!.write(to: out.appendingPathComponent("group.landmarks.png"))
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]).write(to: out.appendingPathComponent("group.report.json"))
        var linear = FloatImage.linear(fromRGBA8: rgba, width: W, height: H)
        let names = ["Oval", "Club", "Wayfarer"]
        let edits = try analyses.enumerated().map { index, analysis -> (edit: EditRecipe.FaceEdit, analysis: FaceSunglassesAnalysis) in
            var edit = PortraitPanelModel.neutral(for: nil)
            let pair = try XCTUnwrap(pack.pairs.first { $0.name == names[index % names.count] })
            edit.sunglasses = .init(pair: pair.id, lens: .dark, darkness: 75, size: 0, removed: nil)
            return (edit, analysis)
        }
        SunglassesRenderer.render(&linear, faces: edits, allAnalyses: analyses, pack: pack, removedPatch: { _ in nil })
        try UIImage(cgImage: Self.cgImage(linear.rgba8FromLinear(), width: W, height: H)).pngData()!.write(to: out.appendingPathComponent("group.render.png"))
        print("Sunglasses group diagnostic: \(out.path)")
    }

    /// Measurement for the width fit: each face's width at the cheek points 234/454 (metres, by the eye-corner scale)
    /// and each pair's front width (vertices within 2 cm of the lens plane), printed for review.
    func testFaceAndPairWidthsArePrinted() throws {
        let analyzer = try XCTUnwrap(SunglassesAnalyzer.loadBundled())
        let pack = try XCTUnwrap(SunglassesPack.bundled)
        for pair in pack.pairs {
            let geometry = try pack.load(pair).mesh.geometry
            let source = try XCTUnwrap(geometry.sources(for: .vertex).first)
            var xs: [Float] = []
            source.data.withUnsafeBytes { raw in
                for i in 0..<source.vectorCount {
                    let o = source.dataOffset + i * source.dataStride
                    let x = raw.loadUnaligned(fromByteOffset: o, as: Float.self), z = raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self)
                    if abs(z) < 0.02 { xs.append(x) }
                }
            }
            print("sunglasses-width pair \(pair.name) front \(String(format: "%.1f", (xs.max()! - xs.min()!) * 1000)) mm")
        }
        var photos = Self.photos.map { "\($0.dir)/\($0.name).jpg" }
        photos.append("experiments/test-photos/group_three_01.jpg")
        for path in photos {
            let full = try XCTUnwrap(UIImage(contentsOfFile: DevelopParityTests.fixture(path).path)?.cgImage)
            let image = try XCTUnwrap(AnalysisProxy.downscaled(full, maximumLongEdge: 1_600))
            let (rgba, W, H) = Self.rgba8(image)
            for (index, face) in try Self.editorFaces(image).enumerated() {
                let a = try analyzer.analyse(.init(rgba: rgba, width: W, height: H), faceBox: face.box, eyes: face.eyes)
                func w(_ i: Int) -> SIMD3<Float> { SIMD3(a.landmarks[i].x, -a.landmarks[i].y, -a.landmarks[i].z) }
                let s = simd_distance(w(263), w(33)) / SunglassesConstants.interIrisReferenceMetres
                print("sunglasses-width face \(path.split(separator: "/").last!) #\(index) logit \(String(format: "%.1f", a.faceLogit)) cheeks \(String(format: "%.1f", simd_distance(w(454), w(234)) / s * 1000)) mm temples \(String(format: "%.1f", simd_distance(w(356), w(127)) / s * 1000)) mm")
            }
        }
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

    /// The Android parity fixture (shared/fixtures/sunglasses/<name>.*): the analysis (landmarks, crops; maps as 8-bit
    /// PNGs) and this render's face region, so Android renders from the same analysis and compares pixels.
    static func writeParityFixture(name: String, analyses: [FaceSunglassesAnalysis], edits: [EditRecipe.FaceEdit], rendered: [UInt8],
                                   width W: Int, height H: Int, to out: URL) throws {
        var faces: [[String: Any]] = []
        for (index, (a, edit)) in zip(analyses, edits).enumerated() {
            func crop(_ m: ProbabilityMap) -> [Double] { [Double(m.originX), Double(m.originY), Double(m.cropSide)] }
            for (kind, map) in [("hair", a.hair), ("background", a.background), ("accessory", a.accessory)] {
                let bytes = map.values.flatMap { v -> [UInt8] in let b = UInt8(min(max(v * 255 + 0.5, 0), 255)); return [b, b, b, 255] }
                try UIImage(cgImage: cgImage(bytes, width: ProbabilityMap.side, height: ProbabilityMap.side)).pngData()!
                    .write(to: out.appendingPathComponent("\(name).f\(index).\(kind).png"))
            }
            faces.append(["box": [a.faceBox.x, a.faceBox.y, a.faceBox.width, a.faceBox.height],
                          "landmarks": a.landmarks.flatMap { [Double($0.x), Double($0.y), Double($0.z)] }, "logit": Double(a.faceLogit),
                          "hairCrop": crop(a.hair), "backgroundCrop": crop(a.background), "accessoryCrop": crop(a.accessory),
                          "pair": edit.sunglasses?.pair ?? "", "hasRemoved": edit.sunglasses?.removed != nil])
        }
        // The region of the first face that holds the pair: its box widened, clamped to the photo.
        let box = analyses[0].faceBox
        let x0 = max(0, Int((box.x - box.width * 0.6) * Double(W))), y0 = max(0, Int((box.y - box.height * 0.2) * Double(H)))
        let x1 = min(W, Int((box.x + box.width * 1.6) * Double(W))), y1 = min(H, Int((box.y + box.height * 0.9) * Double(H)))
        var region = [UInt8](repeating: 255, count: (x1 - x0) * (y1 - y0) * 4)
        for y in y0..<y1 { for x in x0..<x1 { for c in 0..<4 { region[((y - y0) * (x1 - x0) + x - x0) * 4 + c] = rendered[(y * W + x) * 4 + c] } } }
        try UIImage(cgImage: cgImage(region, width: x1 - x0, height: y1 - y0)).pngData()!.write(to: out.appendingPathComponent("\(name).ios-region.png"))
        let json: [String: Any] = ["width": W, "height": H, "faces": faces, "region": [x0, y0, x1 - x0, y1 - y0]]
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: out.appendingPathComponent("\(name).analysis.json"))
    }

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

    /// Face boxes and eye centres exactly as the editor derives them (OnDeviceSceneAnalyser.people + EditorSession):
    /// Vision's eye outlines, normalised to the face box, averaged; ordered left to right.
    static func editorFaces(_ image: CGImage) throws -> [(box: EditRecipe.Rect, eyes: (SIMD2<Float>, SIMD2<Float>))] {
        let W = Float(image.width), H = Float(image.height)
        let request = VNDetectFaceLandmarksRequest()
        OnDeviceSceneAnalyser.preferCPUInSimulator(request)
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).filter { $0.confidence >= 0.5 }.compactMap { face in
            let box = OnDeviceSceneAnalyser.topLeftRect(face.boundingBox)
            func centre(_ region: VNFaceLandmarkRegion2D?) -> SIMD2<Float>? {
                guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
                let xs = points.map { Float(box.x) + Float($0.x) * Float(box.width) }
                let ys = points.map { Float(box.y) + (1 - Float($0.y)) * Float(box.height) }
                return SIMD2(xs.reduce(0, +) / Float(xs.count) * W, ys.reduce(0, +) / Float(ys.count) * H)
            }
            guard let left = centre(face.landmarks?.leftEye), let right = centre(face.landmarks?.rightEye) else { return nil }
            return (box, (left, right))
        }.sorted { $0.box.x < $1.box.x }
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
