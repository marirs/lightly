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
            XCTAssertNotNil(pair.thumbnailDark, "\(pair.name) has a dark-mode picture")
            XCTAssertNotNil(pack.thumbnail(pair, dark: true), pair.name)
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

    /// Side views (owner report 2026-10-14: the arm lay over the ear): Wayfarer on the turned and profile photos, no
    /// paint-out, written as sideview.<name>.png for review.
    func testSideViewsDiagnosticIsWritten() throws {
        let analyzer = try XCTUnwrap(SunglassesAnalyzer.loadBundled())
        let pack = try XCTUnwrap(SunglassesPack.bundled)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lightly-sunglasses")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for name in ["glasses_side_angle_01", "profile_colour_woman_01", "profile_bw_woman_01", "profile_beard_man_01", "profile_bw_boy_01", "profile_bw_woman_hair_01"] {
            let full = try XCTUnwrap(UIImage(contentsOfFile: DevelopParityTests.fixture("experiments/test-photos/\(name).jpg").path)?.cgImage)
            let image = try XCTUnwrap(AnalysisProxy.downscaled(full, maximumLongEdge: 1_600))
            let (rgba, W, H) = Self.rgba8(image)
            let analyses = try Self.editorFaces(image).map { try analyzer.analyse(.init(rgba: rgba, width: W, height: H), faceBox: $0.box, eyes: $0.eyes) }
            let maps = SunglassesRenderer.Maps(analyses: analyses, scale: 1)
            for a in analyses {
                let P = a.landmarks
                func w(_ i: Int) -> SIMD3<Float> { SIMD3(P[i].x, -P[i].y, -P[i].z) }
                let ex = simd_normalize(w(263) - w(33)), ez = simd_normalize(simd_cross(ex, w(10) - w(152)))
                let yaw = atan2(ez.x, ez.z)
                let s = simd_length(w(263) - w(33)) / SunglassesConstants.interIrisReferenceMetres
                let (near, far) = yaw < 0 ? (473, 468) : (468, 473)
                let m = SunglassesRenderer.farIrisMargin(P, near: near, far: far, width: W, height: H, pixelsPerMetre: s, upTo: 0.06,
                                                          background: maps.background)
                let pose = SunglassesRenderer.pose(landmarks: P, width: W, height: H, background: maps.background)
                // The 2D eye-corner span against the face width at the cheeks: a turned face's eyes foreshorten.
                let span2 = simd_distance(SIMD2(P[263].x, P[263].y), SIMD2(P[33].x, P[33].y))
                print("sunglasses-yaw \(name) logit \(String(format: "%.1f", a.faceLogit)) readable \(a.isReadable) raw \(String(format: "%.1f", yaw * 180 / .pi)) margin \(m.map { String(format: "%.1f mm", $0 * 1000) } ?? ">60 mm") final \(String(format: "%.1f", atan2(pose.ez.x, pose.ez.z) * 180 / .pi)) s \(String(format: "%.0f", s)) span2d \(String(format: "%.0f", span2))")
            }
            let pair = try XCTUnwrap(pack.pairs.first { $0.name == "Wayfarer" })
            let edits = analyses.map { a -> (edit: EditRecipe.FaceEdit, analysis: FaceSunglassesAnalysis) in
                var edit = PortraitPanelModel.neutral(for: nil)
                edit.sunglasses = .init(pair: pair.id, lens: .dark, darkness: 75, size: 0, removed: nil)
                return (edit, a)
            }
            var linear = FloatImage.linear(fromRGBA8: rgba, width: W, height: H)
            SunglassesRenderer.render(&linear, faces: edits, allAnalyses: analyses, pack: pack, removedPatch: { _ in nil })
            try UIImage(cgImage: Self.cgImage(linear.rgba8FromLinear(), width: W, height: H)).pngData()!
                .write(to: out.appendingPathComponent("sideview.\(name).png"))
        }
        print("Sunglasses side views: \(out.path)")
    }

    /// The review matrix (owner, 2026-10-15: "try different permutations and combinations"): every pair on every face
    /// photo, as the editor sees it (1600 px preview, editor face boxes, own glasses painted out with LaMa). One sheet per
    /// photo: the original, then the ten pairs, cropped around the faces; written as matrix.<photo>.png, with a log line
    /// per face. Review only: no assertions. Run with LIGHTLY_SUNGLASSES_MATRIX=1 (it takes minutes).
    func testPairMatrixSheetsAreWritten() async throws {
        guard ProcessInfo.processInfo.environment["LIGHTLY_SUNGLASSES_MATRIX"] == "1" else { throw XCTSkip("set LIGHTLY_SUNGLASSES_MATRIX=1") }
        let analyzer = try XCTUnwrap(SunglassesAnalyzer.loadBundled())
        let pack = try XCTUnwrap(SunglassesPack.bundled)
        let lama = LamaInpainter.loadBundled()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lightly-sunglasses")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let photos = ["experiments/lut3d/photos/portrait_deep_01", "experiments/lut3d/photos/portrait_deep_02",
                      "experiments/lut3d/photos/portrait_deep_03", "experiments/lut3d/photos/portrait_light_01",
                      "experiments/lut3d/photos/portrait_light_02", "experiments/lut3d/photos/portrait_medium_01",
                      "experiments/lut3d/photos/portrait_medium_02"]
            + ["glasses_black_front_01", "glasses_pair_mixed_01", "glasses_side_angle_01", "glasses_thick_deep_01",
               "glasses_thin_metal_01", "group_three_01", "profile_beard_man_01", "profile_bw_boy_01", "profile_bw_woman_01",
               "profile_bw_woman_hair_01", "profile_colour_woman_01", "sunglasses_round_01"].map { "experiments/test-photos/\($0)" }
        for path in photos {
            let name = String(path.split(separator: "/").last!)
            let full = try XCTUnwrap(UIImage(contentsOfFile: DevelopParityTests.fixture("\(path).jpg").path)?.cgImage)
            let image = try XCTUnwrap(AnalysisProxy.downscaled(full, maximumLongEdge: 1_600))
            let (rgba, W, H) = Self.rgba8(image)
            let analyses = try Self.editorFaces(image).map { try analyzer.analyse(.init(rgba: rgba, width: W, height: H), faceBox: $0.box, eyes: $0.eyes) }
            let maps = SunglassesRenderer.Maps(analyses: analyses, scale: 1)
            // Own glasses painted out once per face, as the editor does.
            let store = RemovePatchStore()
            var removed: [EditRecipe.FaceEdit.Sunglasses.Removed?] = []
            for (index, a) in analyses.enumerated() {
                var r: EditRecipe.FaceEdit.Sunglasses.Removed?
                if a.glassesMask() != nil, let lama, let result = try await SunglassesRemoval.patch(for: a, source: image, inpainter: lama) {
                    r = .init(rect: result.rect, patch: .init(sha256: store.add(result.patch), model: lama.model,
                                                              width: result.patch.width, height: result.patch.height))
                }
                removed.append(r)
                let pose = SunglassesRenderer.pose(landmarks: a.landmarks, width: W, height: H, background: maps.background)
                print("sunglasses-matrix \(name) face \(index) logit \(String(format: "%.1f", a.faceLogit)) readable \(a.isReadable) glasses \(r != nil) yaw \(String(format: "%.0f", atan2(pose.ez.x, pose.ez.z) * 180 / .pi)) profile \(pose.isProfile)")
            }
            // The crop: every face box, widened, clamped to the photo.
            var x0 = Double(W), y0 = Double(H), x1 = 0.0, y1 = 0.0
            for a in analyses {
                let b = a.faceBox
                x0 = min(x0, (b.x - b.width * 0.45) * Double(W)); x1 = max(x1, (b.x + b.width * 1.45) * Double(W))
                y0 = min(y0, (b.y - b.height * 0.25) * Double(H)); y1 = max(y1, (b.y + b.height * 1.0) * Double(H))
            }
            if analyses.isEmpty { x0 = 0; y0 = 0; x1 = Double(W); y1 = Double(H) }
            let crop = CGRect(x: max(0, x0), y: max(0, y0), width: min(Double(W), x1) - max(0, x0), height: min(Double(H), y1) - max(0, y0)).integral
            var tiles: [(String, CGImage)] = [("Original", image.cropping(to: crop)!)]
            for pair in pack.pairs {
                let edits = analyses.enumerated().map { index, a -> (edit: EditRecipe.FaceEdit, analysis: FaceSunglassesAnalysis) in
                    var edit = PortraitPanelModel.neutral(for: nil)
                    edit.sunglasses = .init(pair: pair.id, lens: .dark, darkness: 75, size: 0, removed: removed[index])
                    return (edit, a)
                }
                var linear = FloatImage.linear(fromRGBA8: rgba, width: W, height: H)
                SunglassesRenderer.render(&linear, faces: edits, allAnalyses: analyses, pack: pack, removedPatch: store.patch)
                tiles.append((pair.name, Self.cgImage(linear.rgba8FromLinear(), width: W, height: H).cropping(to: crop)!))
            }
            // 4 × 3 sheet, tiles 480 px wide, the name under each.
            let tileW: CGFloat = 480, tileH = (tileW * crop.height / crop.width).rounded(), label: CGFloat = 34
            let sheet = UIGraphicsImageRenderer(size: CGSize(width: tileW * 4, height: (tileH + label) * 3), format: {
                let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true; return f }()).image { ctx in
                UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: tileW * 4, height: (tileH + label) * 3))
                for (i, tile) in tiles.enumerated() {
                    let x = CGFloat(i % 4) * tileW, y = CGFloat(i / 4) * (tileH + label)
                    UIImage(cgImage: tile.1).draw(in: CGRect(x: x, y: y, width: tileW, height: tileH))
                    (tile.0 as NSString).draw(at: CGPoint(x: x + 8, y: y + tileH + 4),
                                              withAttributes: [.font: UIFont.boldSystemFont(ofSize: 22), .foregroundColor: UIColor.black])
                }
            }
            try sheet.pngData()!.write(to: out.appendingPathComponent("matrix.\(name).png"))
        }
        print("Sunglasses matrix: \(out.path)")
    }

    /// Diagnostic: each glasses photo with only the paint-out applied (no pair), cropped around the face, written as
    /// removal.<photo>.png next to the original crop, so leftovers of the old glasses can be reviewed.
    func testRemovalOnlyIsWritten() async throws {
        guard ProcessInfo.processInfo.environment["LIGHTLY_SUNGLASSES_MATRIX"] == "1" else { throw XCTSkip("set LIGHTLY_SUNGLASSES_MATRIX=1") }
        let analyzer = try XCTUnwrap(SunglassesAnalyzer.loadBundled())
        let lama = try XCTUnwrap(LamaInpainter.loadBundled())
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lightly-sunglasses")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for name in ["glasses_black_front_01", "glasses_side_angle_01", "glasses_thin_metal_01", "glasses_thick_deep_01", "glasses_pair_mixed_01", "sunglasses_round_01"] {
            let full = try XCTUnwrap(UIImage(contentsOfFile: DevelopParityTests.fixture("experiments/test-photos/\(name).jpg").path)?.cgImage)
            let image = ProcessInfo.processInfo.environment["LIGHTLY_SUNGLASSES_FULLRES"] == "1" ? Self.upscaled(full, by: 2) : try XCTUnwrap(AnalysisProxy.downscaled(full, maximumLongEdge: 1_600))
            let (rgba, W, H) = Self.rgba8(image)
            var linear = FloatImage.linear(fromRGBA8: rgba, width: W, height: H)
            var crop = CGRect.null
            for face in try Self.editorFaces(image) {
                let a = try analyzer.analyse(.init(rgba: rgba, width: W, height: H), faceBox: face.box, eyes: face.eyes)
                guard let r = try await SunglassesRemoval.patch(for: a, source: image, inpainter: lama) else { continue }
                SunglassesRemoval.composite(r.patch, onto: &linear)
                if let (m, w, h, ox, oy) = SunglassesRemoval.lastMaskForDiagnostics {
                    // The mask drawn in red over the original, for review.
                    var tinted = rgba
                    for y in 0..<h { for x in 0..<w where m.data[y * w + x] > 0.5 {
                        let px = x + ox, py = y + oy
                        guard px >= 0, py >= 0, px < W, py < H else { continue }
                        let o = (py * W + px) * 4
                        tinted[o] = UInt8((Int(tinted[o]) + 255) / 2); tinted[o + 1] /= 2; tinted[o + 2] /= 2
                    } }
                    try UIImage(cgImage: Self.cgImage(tinted, width: W, height: H)).pngData()!.write(to: out.appendingPathComponent("removalmask.\(name).png"))
                }
                crop = crop.union(CGRect(x: r.rect.x * Double(W), y: r.rect.y * Double(H), width: r.rect.width * Double(W), height: r.rect.height * Double(H)).insetBy(dx: -40, dy: -40))
            }
            guard !crop.isNull else { continue }
            crop = crop.intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
            let before = image.cropping(to: crop)!, after = Self.cgImage(linear.rgba8FromLinear(), width: W, height: H).cropping(to: crop)!
            let sheet = UIGraphicsImageRenderer(size: CGSize(width: crop.width * 2 + 10, height: crop.height), format: {
                let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = true; return f }()).image { _ in
                UIImage(cgImage: before).draw(at: .zero); UIImage(cgImage: after).draw(at: CGPoint(x: crop.width + 10, y: 0))
            }
            try sheet.pngData()!.write(to: out.appendingPathComponent("removal.\(name).png"))
        }
        print("Sunglasses removal: \(out.path)")
    }

    /// Diagnostic (owner report 2026-10-16: the pair sat above and beside her nose): the landmarks the placement uses —
    /// irises 468/473 (red), eye corners 33/133/362/263 (blue), nose ridge 168/6/197/195/5/4/1 (yellow), with the pair's
    /// origin (green) — over the original and over the Pilot render, written as nose.<photo>.png.
    func testNosePlacementDiagnosticIsWritten() async throws {
        guard ProcessInfo.processInfo.environment["LIGHTLY_SUNGLASSES_MATRIX"] == "1" else { throw XCTSkip("set LIGHTLY_SUNGLASSES_MATRIX=1") }
        let analyzer = try XCTUnwrap(SunglassesAnalyzer.loadBundled())
        let pack = try XCTUnwrap(SunglassesPack.bundled)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lightly-sunglasses")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for name in ["glasses_black_front_01", "portrait_deep_03", "glasses_thick_deep_01"] {
            let path = name.hasPrefix("portrait") ? "experiments/lut3d/photos/\(name).jpg" : "experiments/test-photos/\(name).jpg"
            let full = try XCTUnwrap(UIImage(contentsOfFile: DevelopParityTests.fixture(path).path)?.cgImage)
            let image = try XCTUnwrap(AnalysisProxy.downscaled(full, maximumLongEdge: 1_600))
            let (rgba, W, H) = Self.rgba8(image)
            let face = try XCTUnwrap(Self.editorFaces(image).first)
            let a = try analyzer.analyse(.init(rgba: rgba, width: W, height: H), faceBox: face.box, eyes: face.eyes)
            let maps = SunglassesRenderer.Maps(analyses: [a], scale: 1)
            let pose = SunglassesRenderer.pose(landmarks: a.landmarks, width: W, height: H, background: maps.background)
            var linear = FloatImage.linear(fromRGBA8: rgba, width: W, height: H)
            var edit = PortraitPanelModel.neutral(for: nil)
            edit.sunglasses = .init(pair: try XCTUnwrap(pack.pairs.first { $0.name == "Pilot" }).id, lens: .dark, darkness: 40, size: 0, removed: nil)
            SunglassesRenderer.render(&linear, faces: [(edit, a)], allAnalyses: [a], pack: pack)
            for (tag, base) in [("orig", rgba), ("pilot", linear.rgba8FromLinear())] {
                var px = base
                func dot(_ x: Float, _ y: Float, _ c: (UInt8, UInt8, UInt8)) {
                    for dy in -3...3 { for dx in -3...3 where dx * dx + dy * dy <= 9 {
                        let X = Int(x) + dx, Y = Int(y) + dy
                        guard X >= 0, Y >= 0, X < W, Y < H else { continue }
                        let o = (Y * W + X) * 4; px[o] = c.0; px[o + 1] = c.1; px[o + 2] = c.2
                    } }
                }
                for i in [468, 473] { dot(a.landmarks[i].x, a.landmarks[i].y, (255, 0, 0)) }
                for i in [33, 133, 362, 263] { dot(a.landmarks[i].x, a.landmarks[i].y, (0, 120, 255)) }
                for i in [168, 6, 197, 195, 5, 4, 1] { dot(a.landmarks[i].x, a.landmarks[i].y, (255, 230, 0)) }
                dot(pose.origin.x + Float(W) / 2, Float(H) / 2 - pose.origin.y, (0, 255, 0))
                try UIImage(cgImage: Self.cgImage(px, width: W, height: H)).pngData()!.write(to: out.appendingPathComponent("nose.\(name).\(tag).png"))
            }
            print("sunglasses-nose \(name) box \(face.box) visionEyes \(face.eyes) logit \(a.faceLogit)")
        }
        print("Sunglasses nose: \(out.path)")
    }

    /// Diagnostic for turned faces (owner, 2026-10-20: on glasses_side_angle_01 the near eye's outer corner showed
    /// beside the Round's near lens): the Round on each turned photo with the irises (red) and eye corners (blue)
    /// marked, written as turn.<photo>.png, and the pose numbers printed. Review only.
    func testTurnedFacePlacementDiagnosticIsWritten() async throws {
        guard ProcessInfo.processInfo.environment["LIGHTLY_SUNGLASSES_MATRIX"] == "1" else { throw XCTSkip("set LIGHTLY_SUNGLASSES_MATRIX=1") }
        let analyzer = try XCTUnwrap(SunglassesAnalyzer.loadBundled())
        let pack = try XCTUnwrap(SunglassesPack.bundled)
        let round = try XCTUnwrap(pack.pairs.first { $0.name == "Round" })
        let mesh = try pack.load(round).mesh
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lightly-sunglasses")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for name in ["glasses_side_angle_01", "profile_beard_man_01", "profile_bw_woman_01", "profile_bw_woman_hair_01",
                     "profile_colour_woman_01", "profile_bw_boy_01", "group_three_01", "glasses_thin_metal_01"] {
            let full = try XCTUnwrap(UIImage(contentsOfFile: DevelopParityTests.fixture("experiments/test-photos/\(name).jpg").path)?.cgImage)
            let image = try XCTUnwrap(AnalysisProxy.downscaled(full, maximumLongEdge: 1_600))
            let (rgba, W, H) = Self.rgba8(image)
            let analyses = try Self.editorFaces(image).map { try analyzer.analyse(.init(rgba: rgba, width: W, height: H), faceBox: $0.box, eyes: $0.eyes) }
            let maps = SunglassesRenderer.Maps(analyses: analyses, scale: 1)
            var linear = FloatImage.linear(fromRGBA8: rgba, width: W, height: H)
            let edits = analyses.map { a -> (edit: EditRecipe.FaceEdit, analysis: FaceSunglassesAnalysis) in
                var edit = PortraitPanelModel.neutral(for: nil)
                edit.sunglasses = .init(pair: round.id, lens: .dark, darkness: 40, size: 0, removed: nil)
                return (edit, a)
            }
            SunglassesRenderer.render(&linear, faces: edits, allAnalyses: analyses, pack: pack)
            var px = linear.rgba8FromLinear()
            func dot(_ x: Float, _ y: Float, _ c: (UInt8, UInt8, UInt8)) {
                for dy in -3...3 { for dx in -3...3 where dx * dx + dy * dy <= 9 {
                    let X = Int(x) + dx, Y = Int(y) + dy
                    guard X >= 0, Y >= 0, X < W, Y < H else { continue }
                    let o = (Y * W + X) * 4; px[o] = c.0; px[o + 1] = c.1; px[o + 2] = c.2
                } }
            }
            for (index, a) in analyses.enumerated() {
                let P = a.landmarks
                func w(_ i: Int) -> SIMD3<Float> { SIMD3(P[i].x, -P[i].y, -P[i].z) }
                let rawEz = simd_normalize(simd_cross(simd_normalize(w(263) - w(33)), w(10) - w(152)))
                let pose = SunglassesRenderer.pose(landmarks: P, width: W, height: H, background: maps.background)
                let s = pose.pixelsPerMetre
                // The far-iris walk (§7.5 turn correction) sampled every millimetre, for comparison with Android.
                let rawYaw = atan2(rawEz.x, rawEz.z), (nearI, farI) = rawYaw < 0 ? (473, 468) : (468, 473)
                let start = SIMD2(P[farI].x, P[farI].y), dir = simd_normalize(start - SIMD2(P[nearI].x, P[nearI].y))
                let walk = stride(from: 0, through: Int(0.03 * s), by: max(1, Int(0.001 * s))).map { t -> String in
                    let q = start + dir * Float(t)
                    let v: Float = q.x < 0 || q.y < 0 || Int(q.x) >= W || Int(q.y) >= H ? 1 : maps.background(Float(Int(q.x)) + 0.5, Float(Int(q.y)) + 0.5)
                    return String(format: "%.2f", v)
                }.joined(separator: " ")
                var across = SIMD2<Float>(-(P[152].y - P[10].y), P[152].x - P[10].x); across = simd_normalize(across)
                if simd_dot(across, dir) < 0 { across = -across }
                var alt: Float? = nil
                for t in 0...Int(SunglassesConstants.yawRampMetres * s) {
                    let q = start + across * Float(t)
                    if q.x < 0 || q.y < 0 || Int(q.x) >= W || Int(q.y) >= H || maps.background(Float(Int(q.x)) + 0.5, Float(Int(q.y)) + 0.5) > 0.5 { alt = Float(t) / s; break }
                }
                print("sunglasses-alt \(name) #\(index) rawYaw \(rawYaw * 180 / .pi) across \(across.x),\(across.y) altMargin \(alt.map { String($0) } ?? "nil")")
                print("sunglasses-walk \(name) #\(index) W \(W) H \(H) near \(P[nearI].x),\(P[nearI].y) far \(start.x),\(start.y) dir \(dir.x),\(dir.y) bgPerMm \(walk)")
                let k = SunglassesRenderer.fittedScale(pixelsPerMetre: s, frontWidthMetres: mesh.frontWidthMetres, landmarks: P)
                func px2(_ i: Int) -> SIMD2<Float> { SIMD2(P[i].x, P[i].y) }
                // How far behind the lens plane (metres, along -ez) a landmark lies.
                func earDepth(_ i: Int) -> Float {
                    let q = SIMD3<Float>(P[i].x - Float(W) / 2, Float(H) / 2 - P[i].y, -P[i].z)
                    return simd_dot(pose.origin - q, pose.ez) / s
                }
                print("sunglasses-turn \(name) #\(index) rawYaw \(String(format: "%.0f", atan2(rawEz.x, rawEz.z) * 180 / .pi)) yaw \(String(format: "%.0f", atan2(pose.ez.x, pose.ez.z) * 180 / .pi)) profile \(pose.isProfile) s \(String(format: "%.0f", s)) k/s \(String(format: "%.2f", k / s)) cheeks \(String(format: "%.0f", simd_distance(w(454), w(234)) / s * 1000)) mm irisGap2D \(String(format: "%.0f", simd_distance(px2(468), px2(473)))) px cornerGap2D \(String(format: "%.0f", simd_distance(px2(33), px2(263)))) px originShift2D \(String(format: "%.0f", pose.origin.x + Float(W) / 2 - (P[468].x + P[473].x) / 2)) px ear234 \(String(format: "%.3f", earDepth(234))) ear454 \(String(format: "%.3f", earDepth(454))) m ex.z \(String(format: "%.2f", pose.ex.z))")
                for i in [468, 473] { dot(P[i].x, P[i].y, (255, 0, 0)) }
                for i in [33, 133, 362, 263] { dot(P[i].x, P[i].y, (0, 120, 255)) }
                // Ear-side contour points (yellow 127/356 upper, magenta 234/454 lower), their height above the irises
                // along ey and depth behind the lens plane (metres), for the arm-to-ear-top check.
                for (i, c) in [(127, (255, 230, 0)), (356, (255, 230, 0)), (234, (255, 0, 255)), (454, (255, 0, 255))] as [(Int, (UInt8, UInt8, UInt8))] {
                    dot(P[i].x, P[i].y, c)
                    let q = SIMD3<Float>(P[i].x - Float(W) / 2, Float(H) / 2 - P[i].y, -P[i].z)
                    let irisMid = SIMD3<Float>((P[468].x + P[473].x) / 2 - Float(W) / 2, Float(H) / 2 - (P[468].y + P[473].y) / 2, -(P[468].z + P[473].z) / 2)
                    print("sunglasses-ear \(name) #\(index) lm \(i) up \(String(format: "%.3f", simd_dot(q - irisMid, pose.ey) / s)) back \(String(format: "%.3f", simd_dot(pose.origin - q, pose.ez) / s))")
                }
                dot(pose.origin.x + Float(W) / 2, Float(H) / 2 - pose.origin.y, (0, 255, 0))
            }
            try UIImage(cgImage: Self.cgImage(px, width: W, height: H)).pngData()!.write(to: out.appendingPathComponent("turn.\(name).png"))
        }
        print("Sunglasses turn: \(out.path)")
    }

    /// Diagnostic (owner, 2026-10-20: the low-key beard profile gets no pair): the landmarker's face-presence logit and
    /// mesh extent per face, on the photo as is and with the photo's tones lifted by a gamma that brings the face box's
    /// mean (sRGB) to 0.45. Review only.
    func testLandmarkerExposureDiagnosticIsPrinted() throws {
        guard ProcessInfo.processInfo.environment["LIGHTLY_SUNGLASSES_MATRIX"] == "1" else { throw XCTSkip("set LIGHTLY_SUNGLASSES_MATRIX=1") }
        let analyzer = try XCTUnwrap(SunglassesAnalyzer.loadBundled())
        for name in ["profile_beard_man_01", "profile_bw_woman_hair_01", "profile_bw_woman_01", "profile_colour_woman_01",
                     "profile_bw_boy_01", "glasses_side_angle_01", "group_three_01"] {
            let full = try XCTUnwrap(UIImage(contentsOfFile: DevelopParityTests.fixture("experiments/test-photos/\(name).jpg").path)?.cgImage)
            let image = try XCTUnwrap(AnalysisProxy.downscaled(full, maximumLongEdge: 1_600))
            let (rgba, W, H) = Self.rgba8(image)
            for (index, face) in try Self.editorFaces(image).enumerated() {
                let b = face.box
                var sum = 0.0, n = 0
                for y in Int(b.y * Double(H))..<min(H, Int((b.y + b.height) * Double(H))) {
                    for x in Int(b.x * Double(W))..<min(W, Int((b.x + b.width) * Double(W))) {
                        let o = (y * W + x) * 4; sum += (Double(rgba[o]) + Double(rgba[o + 1]) + Double(rgba[o + 2])) / 765; n += 1
                    }
                }
                let mean = sum / Double(max(n, 1))
                for gamma in [1.0, log(0.45) / log(max(mean, 0.01))] {
                    let lut = (0..<256).map { UInt8(min(255, (pow(Double($0) / 255, gamma) * 255).rounded())) }
                    let lifted = gamma == 1 ? rgba : rgba.enumerated().map { $0.offset % 4 == 3 ? $0.element : lut[Int($0.element)] }
                    let a = try analyzer.analyse(.init(rgba: lifted, width: W, height: H), faceBox: face.box, eyes: face.eyes)
                    let mesh = a.landmarks.prefix(468)
                    let spanX = (mesh.map(\.x).max()! - mesh.map(\.x).min()!) / Float(b.width * Double(W))
                    let spanY = (mesh.map(\.y).max()! - mesh.map(\.y).min()!) / Float(b.height * Double(H))
                    if gamma == 1 {
                        var px = rgba
                        for q in a.landmarks.prefix(468) {
                            let X = Int(q.x), Y = Int(q.y)
                            guard X >= 1, Y >= 1, X < W - 1, Y < H - 1 else { continue }
                            for dy in -1...1 { for dx in -1...1 { let o = ((Y + dy) * W + X + dx) * 4; px[o] = 0; px[o + 1] = 255; px[o + 2] = 0 } }
                        }
                        for e in [face.eyes.0, face.eyes.1] {
                            for dy in -4...4 { for dx in -4...4 { let X = Int(e.x) + dx, Y = Int(e.y) + dy
                                guard X >= 0, Y >= 0, X < W, Y < H else { continue }
                                let o = (Y * W + X) * 4; px[o] = 255; px[o + 1] = 0; px[o + 2] = 255 } }
                        }
                        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lightly-sunglasses")
                        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                        try UIImage(cgImage: Self.cgImage(px, width: W, height: H)).pngData()!.write(to: out.appendingPathComponent("mesh.\(name).\(index).png"))
                    }
                    if gamma != 1, name == "profile_beard_man_01", let pack = SunglassesPack.bundled {
                        // The lifted analysis rendered on the original photo, for review.
                        var edit = PortraitPanelModel.neutral(for: nil)
                        edit.sunglasses = .init(pair: pack.pairs.first { $0.name == "Wayfarer" }!.id, lens: .dark, darkness: 75, size: 0, removed: nil)
                        var linear = FloatImage.linear(fromRGBA8: rgba, width: W, height: H)
                        SunglassesRenderer.render(&linear, faces: [(edit, a)], allAnalyses: [a], pack: pack)
                        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lightly-sunglasses")
                        try UIImage(cgImage: Self.cgImage(linear.rgba8FromLinear(), width: W, height: H)).pngData()!.write(to: out.appendingPathComponent("lifted.\(name).png"))
                    }
                    print("sunglasses-exposure \(name) #\(index) boxMean \(String(format: "%.2f", mean)) gamma \(String(format: "%.2f", gamma)) logit \(String(format: "%.1f", a.faceLogit)) meshSpan \(String(format: "%.2f", spanX))x\(String(format: "%.2f", spanY)) of box")
                }
            }
        }
    }

    /// Diagnostic for a geometry check on low-logit faces (owner, 2026-10-20): per face, the logit and how much darker
    /// the photo is inside the clearer eye's landmark iris than in a ring around it (2–3 iris radii). Review only.
    func testIrisContrastDiagnosticIsPrinted() throws {
        guard ProcessInfo.processInfo.environment["LIGHTLY_SUNGLASSES_MATRIX"] == "1" else { throw XCTSkip("set LIGHTLY_SUNGLASSES_MATRIX=1") }
        let analyzer = try XCTUnwrap(SunglassesAnalyzer.loadBundled())
        var photos = Self.photos.map { "\($0.dir)/\($0.name).jpg" }
        photos += ["glasses_black_front_01", "glasses_pair_mixed_01", "glasses_side_angle_01", "glasses_thick_deep_01",
                   "glasses_thin_metal_01", "group_three_01", "profile_beard_man_01", "profile_bw_boy_01", "profile_bw_woman_01",
                   "profile_bw_woman_hair_01", "profile_colour_woman_01", "sunglasses_round_01"].map { "experiments/test-photos/\($0).jpg" }
        for path in Set(photos).sorted() {
            let full = try XCTUnwrap(UIImage(contentsOfFile: DevelopParityTests.fixture(path).path)?.cgImage)
            let image = try XCTUnwrap(AnalysisProxy.downscaled(full, maximumLongEdge: 1_600))
            let (rgba, W, H) = Self.rgba8(image)
            func luma(_ x: Int, _ y: Int) -> Float? {
                guard x >= 0, y >= 0, x < W, y < H else { return nil }
                let o = (y * W + x) * 4; return (Float(rgba[o]) * 0.299 + Float(rgba[o + 1]) * 0.587 + Float(rgba[o + 2]) * 0.114) / 255
            }
            for (index, face) in try Self.editorFaces(image).enumerated() {
                let a = try analyzer.analyse(.init(rgba: rgba, width: W, height: H), faceBox: face.box, eyes: face.eyes)
                let P = a.landmarks
                // The clearer eye: the larger iris in the image (the far one shrinks with the turn).
                func radius(_ c: Int) -> Float { (c + 1...c + 4).map { simd_distance(SIMD2(P[$0].x, P[$0].y), SIMD2(P[c].x, P[c].y)) }.reduce(0, +) / 4 }
                let centre = radius(468) >= radius(473) ? 468 : 473, r = max(radius(centre), 1)
                var inner: [Float] = [], ring: [Float] = []
                let cx = P[centre].x, cy = P[centre].y, reach = Int((3 * r).rounded(.up))
                for dy in -reach...reach { for dx in -reach...reach {
                    let d = (Float(dx * dx + dy * dy)).squareRoot() / r
                    guard let l = luma(Int(cx) + dx, Int(cy) + dy) else { continue }
                    if d <= 0.8 { inner.append(l) } else if d >= 2, d <= 3 { ring.append(l) }
                } }
                let li = inner.reduce(0, +) / Float(max(inner.count, 1)), lr = ring.reduce(0, +) / Float(max(ring.count, 1))
                print("sunglasses-iris \(path.split(separator: "/").last!) #\(index) logit \(String(format: "%.1f", a.faceLogit)) irisR \(String(format: "%.1f", r)) inner \(String(format: "%.2f", li)) ring \(String(format: "%.2f", lr)) contrast \(String(format: "%.2f", (lr - li) / max(lr, 0.01)))")
            }
        }
    }

    /// Validation set for the low-logit geometry check (owner, 2026-10-20: not from one photo): every readable face of the
    /// test photos, analysed again on degraded copies (darkened, blurred, noisy) and from shifted or shrunk face boxes.
    /// Each variant that scores below `minFaceLogit` is labelled right when its clearer iris lies within one iris radius of
    /// the original analysis's, and printed with its iris contrast. Review only.
    func testLowLogitVariantsArePrinted() throws {
        guard ProcessInfo.processInfo.environment["LIGHTLY_SUNGLASSES_MATRIX"] == "1" else { throw XCTSkip("set LIGHTLY_SUNGLASSES_MATRIX=1") }
        let analyzer = try XCTUnwrap(SunglassesAnalyzer.loadBundled())
        var photos = Self.photos.map { "\($0.dir)/\($0.name).jpg" }
        photos += ["glasses_black_front_01", "glasses_pair_mixed_01", "glasses_side_angle_01", "glasses_thick_deep_01",
                   "glasses_thin_metal_01", "group_three_01", "profile_bw_boy_01", "profile_bw_woman_01", "profile_beard_man_01",
                   "profile_bw_woman_hair_01", "profile_colour_woman_01", "sunglasses_round_01"].map { "experiments/test-photos/\($0).jpg" }
        photos += ["portrait_deep_01", "portrait_deep_03", "portrait_light_01", "portrait_light_02", "portrait_medium_01"].map { "experiments/lut3d/photos/\($0).jpg" }
        var rng = SystemRandomNumberGenerator()
        for path in Set(photos).sorted() {
            let full = try XCTUnwrap(UIImage(contentsOfFile: DevelopParityTests.fixture(path).path)?.cgImage)
            let image = try XCTUnwrap(AnalysisProxy.downscaled(full, maximumLongEdge: 1_600))
            let (rgba, W, H) = Self.rgba8(image)
            func degraded(_ kind: String) -> [UInt8] {
                switch kind {
                case "dark": return rgba.enumerated().map { $0.offset % 4 == 3 ? $0.element : UInt8(pow(Double($0.element) / 255, 2.4) * 255) }
                case "noise": return rgba.enumerated().map { $0.offset % 4 == 3 ? $0.element : UInt8(min(255, max(0, Int($0.element) + Int.random(in: -60...60, using: &rng)))) }
                case "blur":
                    var out = rgba
                    for y in 0..<H { for x in 0..<W { for c in 0..<3 {
                        let bx = (x / 6) * 6, by = (y / 6) * 6
                        out[(y * W + x) * 4 + c] = rgba[(by * W + bx) * 4 + c]
                    } } }
                    return out
                default: return rgba
                }
            }
            for (index, face) in try Self.editorFaces(image).enumerated() {
                let reference = try analyzer.analyse(.init(rgba: rgba, width: W, height: H), faceBox: face.box, eyes: face.eyes)
                let refIris = Self.clearerIris(reference.landmarks)
                var refDrift: Float = 0
                for (sx, sy) in [(0.08, 0.08), (-0.08, -0.08)] {
                    let moved = EditRecipe.Rect(x: face.box.x + sx * face.box.width, y: face.box.y + sy * face.box.height, width: face.box.width, height: face.box.height)
                    let again = try analyzer.analyse(.init(rgba: rgba, width: W, height: H), faceBox: moved, eyes: face.eyes)
                    refDrift = max(refDrift, simd_distance(Self.clearerIris(again.landmarks).centre, refIris.centre) / refIris.radius)
                }
                print("sunglasses-original \(path.split(separator: "/").last!) #\(index) logit \(String(format: "%.1f", reference.faceLogit)) contrast \(String(format: "%.2f", Self.irisContrast(rgba, width: W, height: H, iris: refIris))) drift \(String(format: "%.2f", refDrift))")
                guard reference.isReadable else { continue }
                var variants: [(String, [UInt8], EditRecipe.Rect)] = ["dark", "noise", "blur"].map { ($0, degraded($0), face.box) }
                let b = face.box
                for (dx, dy, sc) in [(0.4, 0.0, 1.0), (-0.4, 0.0, 1.0), (0.0, 0.35, 1.0), (0.0, -0.35, 1.0), (0.0, 0.0, 0.5), (0.3, 0.3, 0.6)] {
                    variants.append(("box\(dx),\(dy),\(sc)", rgba, .init(x: b.x + dx * b.width + b.width * (1 - sc) / 2, y: b.y + dy * b.height + b.height * (1 - sc) / 2,
                                                                         width: b.width * sc, height: b.height * sc)))
                }
                for (kind, pixels, box) in variants {
                    let a = try analyzer.analyse(.init(rgba: pixels, width: W, height: H), faceBox: box, eyes: face.eyes)
                    guard !a.isReadable else { continue }
                    let iris = Self.clearerIris(a.landmarks)
                    let right = simd_distance(iris.centre, refIris.centre) <= refIris.radius
                    let contrast = Self.irisContrast(rgba, width: W, height: H, iris: iris)
                    // Stability: the same variant from boxes moved 8 % of the box each way; the iris's largest move.
                    var drift: Float = 0
                    for (sx, sy) in [(0.08, 0.08), (-0.08, -0.08)] {
                        let moved = EditRecipe.Rect(x: box.x + sx * box.width, y: box.y + sy * box.height, width: box.width, height: box.height)
                        let again = try analyzer.analyse(.init(rgba: pixels, width: W, height: H), faceBox: moved, eyes: face.eyes)
                        drift = max(drift, simd_distance(Self.clearerIris(again.landmarks).centre, iris.centre) / iris.radius)
                    }
                    print("sunglasses-variant \(path.split(separator: "/").last!) #\(index) \(kind) logit \(String(format: "%.1f", a.faceLogit)) right \(right) contrast \(String(format: "%.2f", contrast)) drift \(String(format: "%.2f", drift))")
                }
            }
        }
    }

    /// The larger landmark iris in the image (the far one shrinks with the turn): centre and radius in pixels.
    static func clearerIris(_ P: [SIMD3<Float>]) -> (centre: SIMD2<Float>, radius: Float) {
        func radius(_ c: Int) -> Float { (c + 1...c + 4).map { simd_distance(SIMD2(P[$0].x, P[$0].y), SIMD2(P[c].x, P[c].y)) }.reduce(0, +) / 4 }
        let c = radius(468) >= radius(473) ? 468 : 473
        return (SIMD2(P[c].x, P[c].y), max(radius(c), 1))
    }

    /// (ring − inside) / ring luminance: inside 0.8 iris radii, the ring 2–3 radii (positive when the iris is darker).
    static func irisContrast(_ rgba: [UInt8], width W: Int, height H: Int, iris: (centre: SIMD2<Float>, radius: Float)) -> Float {
        var inner: [Float] = [], ring: [Float] = []
        let reach = Int((3 * iris.radius).rounded(.up))
        for dy in -reach...reach { for dx in -reach...reach {
            let x = Int(iris.centre.x) + dx, y = Int(iris.centre.y) + dy
            guard x >= 0, y >= 0, x < W, y < H else { continue }
            let o = (y * W + x) * 4, l = (Float(rgba[o]) * 0.299 + Float(rgba[o + 1]) * 0.587 + Float(rgba[o + 2]) * 0.114) / 255
            let d = Float(dx * dx + dy * dy).squareRoot() / iris.radius
            if d <= 0.8 { inner.append(l) } else if d >= 2, d <= 3 { ring.append(l) }
        } }
        let li = inner.reduce(0, +) / Float(max(inner.count, 1)), lr = ring.reduce(0, +) / Float(max(ring.count, 1))
        return (lr - li) / max(lr, 0.01)
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

    /// A phone-sized stand-in for a test photo: `factor` × its size, high-quality interpolation.
    static func upscaled(_ image: CGImage, by factor: Int) -> CGImage {
        let w = image.width * factor, h = image.height * factor
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
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
