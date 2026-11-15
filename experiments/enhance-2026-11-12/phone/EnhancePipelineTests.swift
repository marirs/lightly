import CoreML
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Enhance step 2c (2026-11-15): the whole Enhance pipeline on a review iPhone, the same steps and maths as
/// experiments/enhance-2026-11-12/phone_pipeline.py (its docstring lists the steps). Not part of the app: copied into
/// the scratch build's LightlyTests only; skips when its inputs are absent.
///
/// Inputs in the host app's Documents/enhance-bench (copied with devicectl): art-classifier.mlmodelc,
/// face-detector-640/960.mlmodelc, general-x4v3-256.mlmodelc, codeformer-w0.8-512.mlmodelc and photos/<id>.png. Face
/// Mesh and selfie multiclass are the app's own models (face_landmarks_256_fp16, selfie_multiclass_256_fp16), from the
/// app bundle or, when copied there, enhance-bench.
/// Outputs in Documents/pipeline-out: <id>.png and <id>.json.
///
/// Compute units as measured in step 1c: everything on all units, except CodeFormer on the iPhone 11 Pro Max (A13),
/// where the Neural Engine path crashes the app, so it runs on CPU + GPU there.
final class EnhancePipelineTests: XCTestCase {
    private static let scale = 2
    private static let artThreshold: Float = 0.8
    private static let detectionSizes = [640: 1024, 960: 1536]
    private static let detectorMeanRGB: [Float] = [123, 117, 104]
    private static let meshFive = [468, 473, 1, 61, 291]
    private static let faceSkin = 3
    private static let faceTemplate: [SIMD2<Double>] = [
        [192.98138, 239.94708], [318.90277, 240.1936], [256.63416, 314.01935], [201.26117, 371.41043], [313.08905, 371.15118],
    ]
    private static let cropBorderRGB: [Float] = [132, 133, 135]   // CodeFormer's (135, 133, 132) in BGR
    private static let tile = 256, tilePad = 10

    private struct Models {
        let art: MLModel, detectors: [Int: MLModel], mesh: MLModel, multiclass: MLModel, upscaler: MLModel, codeformer: MLModel
    }

    private var peakMB: Double = 0

    func testEnhancePipeline() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("enhance-bench")
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("photos").path) else {
            throw XCTSkip("no photos in Documents/enhance-bench")
        }
        // A file enhance-bench/codeformer-cpu-gpu forces CodeFormer onto CPU + GPU on any iPhone (outputs then go to
        // pipeline-out-cpu-gpu): the SE 3's Neural Engine run left a bright blotch on Q-lUWYs7Ms0's lips (2026-11-15).
        let forceCpuGpu = FileManager.default.fileExists(atPath: folder.appendingPathComponent("codeformer-cpu-gpu").path)
        let isA13 = Self.machine().hasPrefix("iPhone12,") || forceCpuGpu
        func load(_ url: URL, _ units: MLComputeUnits) throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        func bench(_ name: String) -> URL { folder.appendingPathComponent(name) }
        // The app's own Face Mesh and multiclass models; a scratch clone lacks the git-ignored originals the app
        // bundles, so the same compiled models may be copied into enhance-bench instead.
        func bundled(_ name: String) -> URL {
            let copy = bench("\(name).mlmodelc")
            return FileManager.default.fileExists(atPath: copy.path) ? copy : Bundle.main.url(forResource: name, withExtension: "mlmodelc")!
        }
        var log: [String] = []
        let loadStart = CFAbsoluteTimeGetCurrent()
        let models = Models(
            art: try load(bench("art-classifier.mlmodelc"), .all),
            detectors: try [640: load(bench("face-detector-640.mlmodelc"), .all), 960: load(bench("face-detector-960.mlmodelc"), .all)],
            mesh: try load(bundled("face_landmarks_256_fp16"), .all),
            multiclass: try load(bundled("selfie_multiclass_256_fp16"), .all),
            upscaler: try load(bench("general-x4v3-256.mlmodelc"), .all),
            codeformer: try load(bench("codeformer-w0.8-512.mlmodelc"), isA13 ? .cpuAndGPU : .all))
        log.append(String(format: "%@ models loaded in %.1f s (CodeFormer on %@), footprint %.0f MB", Self.machine(),
                          CFAbsoluteTimeGetCurrent() - loadStart, isA13 ? "CPU + GPU" : "all units", Self.footprintMB()))
        let output = documents.appendingPathComponent(forceCpuGpu ? "pipeline-out-cpu-gpu" : "pipeline-out")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let photos = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("photos"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for photo in photos { try autoreleasepool {
            peakMB = 0
            let start = CFAbsoluteTimeGetCurrent()
            let rgb = try Self.decodePNG(photo)
            let (image, initialRecord) = try enhance(models, rgb)
            var record = initialRecord
            let total = CFAbsoluteTimeGetCurrent() - start
            record["total_ms"] = Int(total * 1000)
            record["peak_footprint_mb"] = Int(peakMB)
            let name = photo.deletingPathExtension().lastPathComponent
            try Self.encodePNG(image, to: output.appendingPathComponent("\(name).png"))
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("\(name).json"))
            log.append("\(name): \((record["faces"] as! [Any]).count) faces, \(Int(total * 1000)) ms, peak \(Int(peakMB)) MB, \(record["times"]!)")
            // Written after every photo so a crash still leaves the results measured before it.
            try log.joined(separator: "\n").write(to: output.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
            print("ENHANCE-PIPELINE " + log.last!)
        } }
    }

    private func notePeak() { peakMB = max(peakMB, Self.footprintMB()) }

    private func enhance(_ models: Models, _ rgb: Image) throws -> (Image, [String: Any]) {
        var times: [String: Double] = [:]
        var record: [String: Any] = [:]
        var t = CFAbsoluteTimeGetCurrent()
        let art = try artProbability(models.art, rgb)
        record["art"] = art
        times["art"] = CFAbsoluteTimeGetCurrent() - t
        let grey = isGrey(rgb)
        record["grey"] = grey
        var faces: [[String: Any]] = []
        var used: [[SIMD2<Double>]] = []
        if art < Self.artThreshold {
            t = CFAbsoluteTimeGetCurrent()
            var found = try detect(models.detectors[640]!, rgb, short: 640)
            let extra = try detect(models.detectors[960]!, rgb, short: 960).filter { d in found.allSatisfy { iou(d.box, $0.box) < 0.3 } }
            record["detections_640"] = found.count
            record["detections_960_added"] = extra.count
            found += extra
            times["detect"] = CFAbsoluteTimeGetCurrent() - t
            notePeak()
            t = CFAbsoluteTimeGetCurrent()
            for detection in found {
                let (five, presence) = try meshFive(models.mesh, rgb, detection)
                used.append(five)
                faces.append(["box": detection.box, "score": detection.score, "five": detection.five.map { [$0.x, $0.y] },
                              "mesh_presence": presence, "five_used": five.map { [$0.x, $0.y] }])
            }
            times["mesh"] = CFAbsoluteTimeGetCurrent() - t
        }
        t = CFAbsoluteTimeGetCurrent()
        var image = try upscaleBackground(models.upscaler, rgb)
        times["background"] = CFAbsoluteTimeGetCurrent() - t
        notePeak()
        times["codeformer"] = 0; times["colour_and_mask"] = 0; times["paste"] = 0
        for five in used {
            let toFace = similarity(five, Self.faceTemplate)
            let crop = warpBilinear(rgb, invertAffine(toFace), 512, 512, border: Self.cropBorderRGB)
            t = CFAbsoluteTimeGetCurrent()
            var restored = try restore(models.codeformer, crop)
            times["codeformer"]! += CFAbsoluteTimeGetCurrent() - t
            notePeak()
            t = CFAbsoluteTimeGetCurrent()
            restored = originalColour(restored, crop)
            if grey { restored = greyLike(restored, crop) }
            let mask = try faceMask(models.multiclass, restored)
            times["colour_and_mask"]! += CFAbsoluteTimeGetCurrent() - t
            t = CFAbsoluteTimeGetCurrent()
            pasteFace(&image, restored, mask, toFace)
            times["paste"]! += CFAbsoluteTimeGetCurrent() - t
        }
        record["faces"] = faces
        record["times"] = times.mapValues { ($0 * 1000).rounded() / 1000 }
        return (image, record)
    }

    // MARK: - Models

    private func array(_ shape: [Int], _ fill: (UnsafeMutablePointer<Float>) -> Void) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        fill(array.dataPointer.bindMemory(to: Float.self, capacity: array.count))
        return array
    }

    /// One prediction, its named outputs copied into Swift arrays. Core ML's input and output buffers are
    /// autoreleased: without the pool a photo's 48 background tiles (12 MB each) pile up until the test host is
    /// killed (first SE 3 run, 2026-11-15: 0.8 -> 1.7 GB over four photos, then a crash).
    private func predict(_ model: MLModel, _ inputs: [String: MLMultiArray], _ names: [String]) throws -> [String: [Float]] {
        try autoreleasepool {
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) }))
            var values: [String: [Float]] = [:]
            for name in names { values[name] = Self.floats(output.featureValue(for: name)!.multiArrayValue!) }
            return values
        }
    }

    /// A Core ML output's values in logical (row-major) order (the app's SunglassesAnalyzer.floats).
    static func floats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        var expected = 1
        let contiguous = zip(array.shape.reversed(), array.strides.reversed()).allSatisfy { dim, stride in
            defer { expected *= dim.intValue }
            return stride.intValue == expected
        }
        guard contiguous else { return (0..<count).map { array[$0].floatValue } }
        switch array.dataType {
        case .float32: return Array(UnsafeBufferPointer(start: array.dataPointer.assumingMemoryBound(to: Float.self), count: count))
        case .float16: return UnsafeBufferPointer(start: array.dataPointer.assumingMemoryBound(to: Float16.self), count: count).map(Float.init)
        default: return (0..<count).map { array[$0].floatValue }
        }
    }

    private func artProbability(_ model: MLModel, _ rgb: Image) throws -> Float {
        let views = fiveViews(rgb)
        let input = try array([5, 3, 224, 224]) { p in
            for (v, view) in views.enumerated() { for c in 0..<3 { for i in 0..<(224 * 224) {
                p[(v * 3 + c) * 224 * 224 + i] = view.d[i * 3 + c] / 255
            } } }
        }
        return try predict(model, ["views": input], ["art_probability"])["art_probability"]![0]
    }

    private func detect(_ model: MLModel, _ rgb: Image, short: Int) throws -> [Detection] {
        let canvas = Self.detectionSizes[short]!
        let scale = Double(short) / Double(min(rgb.w, rgb.h))
        let nw = Int(Double(rgb.w) * scale), nh = Int(Double(rgb.h) * scale)
        guard max(nw, nh) <= canvas else { throw NSError(domain: "photo too long for the \(canvas) canvas", code: 1) }
        let small = resize(rgb, nw, nh)
        let input = try array([1, 3, canvas, canvas]) { p in
            for c in 0..<3 { for y in 0..<canvas { for x in 0..<canvas {
                let value = x < nw && y < nh ? small.d[(y * nw + x) * 3 + c] : Self.detectorMeanRGB[c]
                p[(c * canvas + y) * canvas + x] = value / 255
            } } }
        }
        let output = try predict(model, ["image": input], ["loc", "score", "landmarks"])
        return decodeDetections(loc: output["loc"]!, score: output["score"]!, landmarks: output["landmarks"]!,
                                priors: priors(canvas), scale: scale)
    }

    private func meshRun(_ model: MLModel, _ rgb: Image, centre: SIMD2<Double>, side: Double, roll: Double) throws -> ([SIMD2<Double>], Double) {
        let k = side / 256, c = cos(roll), s = sin(roll)
        let toPhoto = [k * c, -k * s, centre.x - k * (c * 128 - s * 128), k * s, k * c, centre.y - k * (s * 128 + c * 128)]
        let crop = warpBilinear(rgb, toPhoto, 256, 256, border: [0, 0, 0])
        let input = try array([1, 256, 256, 3]) { p in for i in 0..<crop.d.count { p[i] = crop.d[i] / 255 } }
        let output = try predict(model, ["image": input], ["landmarks", "face_flag"])
        let raw = output["landmarks"]!
        let flag = Double(output["face_flag"]![0])
        let points = (0..<478).map { i -> SIMD2<Double> in
            let u = Double(raw[i * 3]), v = Double(raw[i * 3 + 1])
            return [toPhoto[0] * u + toPhoto[1] * v + toPhoto[2], toPhoto[3] * u + toPhoto[4] * v + toPhoto[5]]
        }
        return (points, 1 / (1 + exp(-flag)))
    }

    private func meshFive(_ model: MLModel, _ rgb: Image, _ detection: Detection) throws -> ([SIMD2<Double>], Double) {
        let b = detection.box, five = detection.five
        let eye = five[1] - five[0]
        var (points, presence) = try meshRun(model, rgb, centre: [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2],
                                             side: max(b[2] - b[0], b[3] - b[1]) * 1.5, roll: atan2(eye.y, eye.x))
        let line = points[263] - points[33]
        var lo = SIMD2<Double>(repeating: .greatestFiniteMagnitude), hi = SIMD2<Double>(repeating: -.greatestFiniteMagnitude)
        for p in points[0..<468] { lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p) }
        let (refined, refinedPresence) = try meshRun(model, rgb, centre: (lo + hi) / 2, side: max(hi.x - lo.x, hi.y - lo.y) * 1.5,
                                                     roll: atan2(line.y, line.x))
        if refinedPresence >= presence - 0.1 { points = refined; presence = refinedPresence }
        return (presence >= 0.5 ? Self.meshFive.map { points[$0] } : five, presence)
    }

    private func restore(_ model: MLModel, _ face: Image) throws -> Image {
        let input = try array([1, 3, 512, 512]) { p in
            for c in 0..<3 { for i in 0..<(512 * 512) { p[c * 512 * 512 + i] = face.d[i * 3 + c] / 127.5 - 1 } }
        }
        let values = try predict(model, ["face": input], ["output"])["output"]!
        var out = Image(w: 512, h: 512, c: 3)
        for c in 0..<3 { for i in 0..<(512 * 512) { out.d[i * 3 + c] = (min(max(values[c * 512 * 512 + i], -1), 1) + 1) * 127.5 } }
        return out
    }

    private func upscaleBackground(_ model: MLModel, _ rgb: Image) throws -> Image {
        let tile = Self.tile, keep = tile - 2 * Self.tilePad, up = 4 * tile
        var out = Image(w: rgb.w * 2, h: rgb.h * 2, c: 3)
        for y in stride(from: 0, to: rgb.h, by: keep) { for x in stride(from: 0, to: rgb.w, by: keep) {
            let wx = min(max(x - Self.tilePad, 0), rgb.w - tile), wy = min(max(y - Self.tilePad, 0), rgb.h - tile)
            let input = try array([1, 3, tile, tile]) { p in
                for c in 0..<3 { for ty in 0..<tile { for tx in 0..<tile {
                    p[(c * tile + ty) * tile + tx] = rgb.d[((wy + ty) * rgb.w + wx + tx) * 3 + c] / 255
                } } }
            }
            let values = try predict(model, ["input": input], ["output"])["output"]!
            let cw = min(keep, rgb.w - x), ch = min(keep, rgb.h - y), ox = (x - wx) * 4, oy = (y - wy) * 4
            for c in 0..<3 { for yy in 0..<(ch * 2) { for xx in 0..<(cw * 2) {
                var sum: Float = 0
                for dy in 0..<2 { for dx in 0..<2 {
                    sum += min(max(values[(c * up + oy + yy * 2 + dy) * up + ox + xx * 2 + dx], 0), 1)
                } }
                out.d[((y * 2 + yy) * out.w + x * 2 + xx) * 3 + c] = sum / 4 * 255
            } } }
        } }
        return out
    }

    private func faceMask(_ model: MLModel, _ restored: Image) throws -> [Float] {
        var clipped = restored
        for i in 0..<clipped.d.count { clipped.d[i] = min(max(clipped.d[i], 0), 255) }
        let small = resize(clipped, 256, 256)
        let input = try array([1, 256, 256, 3]) { p in for i in 0..<small.d.count { p[i] = small.d[i] / 255 } }
        let logits = try predict(model, ["image": input], ["logits"])["logits"]!
        var face = [Bool](repeating: false, count: 256 * 256)
        for i in 0..<(256 * 256) {
            var best = 0
            for c in 1..<6 where logits[i * 6 + c] > logits[i * 6 + best] { best = c }
            face[i] = best == Self.faceSkin
        }
        let filled = fillHoles(face, 256, 256)
        var plane = Image(w: 256, h: 256, c: 1)
        for i in 0..<filled.count { plane.d[i] = filled[i] ? 255 : 0 }
        var mask = resize(plane, 512, 512).d
        mask = gaussianBlur(gaussianBlur(mask, 512, 512, size: 101, sigma: 11), 512, 512, size: 101, sigma: 11)
        for y in 0..<512 { for x in 0..<512 {
            mask[y * 512 + x] = (y < 10 || y >= 502 || x < 10 || x >= 502) ? 0 : mask[y * 512 + x] / 255
        } }
        return mask
    }

    // MARK: - Files and memory

    static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// 8-bit RGB pixels exactly as stored (drawn into an sRGB context, the PNGs carry no colour profile).
    private static func decodePNG(_ url: URL) throws -> Image {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw NSError(domain: "cannot read \(url.path)", code: 1) }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var image = Image(w: w, h: h, c: 3)
        for i in 0..<(w * h) { for c in 0..<3 { image.d[i * 3 + c] = Float(bytes[i * 4 + c]) } }
        return image
    }

    private static func encodePNG(_ image: Image, to url: URL) throws {
        var bytes = [UInt8](repeating: 255, count: image.w * image.h * 4)
        for i in 0..<(image.w * image.h) { for c in 0..<3 { bytes[i * 4 + c] = UInt8(min(max(image.d[i * 3 + c], 0), 255).rounded()) } }
        let context = CGContext(data: &bytes, width: image.w, height: image.h, bitsPerComponent: 8, bytesPerRow: image.w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "cannot write \(url.path)", code: 1) }
    }
}

// MARK: - Image maths, line for line with phone_pipeline.py (Float, interleaved HWC)

fileprivate struct Image {
    let w: Int, h: Int, c: Int
    var d: [Float]
    init(w: Int, h: Int, c: Int, d: [Float]? = nil) { self.w = w; self.h = h; self.c = c; self.d = d ?? [Float](repeating: 0, count: w * h * c) }
}

fileprivate struct Detection {
    let box: [Double]
    let score: Double
    let five: [SIMD2<Double>]
}

/// PIL bilinear weights (antialiased when shrinking): per output pixel, the first tap and its weights.
private func resampleTaps(_ inSize: Int, _ outSize: Int) -> [(first: Int, weights: [Float])] {
    let scale = Double(inSize) / Double(outSize), filterScale = max(scale, 1)
    return (0..<outSize).map { x in
        let centre = (Double(x) + 0.5) * scale
        let lo = max(Int(centre - filterScale + 0.5), 0), hi = min(Int(centre + filterScale + 0.5), inSize)
        let w = (lo..<hi).map { max(0, 1 - abs((Double($0) - centre + 0.5) / filterScale)) }
        let sum = w.reduce(0, +)
        return (lo, w.map { sum > 0 ? Float($0 / sum) : 0 })
    }
}

fileprivate func resize(_ image: Image, _ width: Int, _ height: Int) -> Image {
    let tx = resampleTaps(image.w, width), ty = resampleTaps(image.h, height), c = image.c
    var horizontal = [Float](repeating: 0, count: width * image.h * c)
    image.d.withUnsafeBufferPointer { src in
        for y in 0..<image.h { for x in 0..<width {
            let (first, weights) = tx[x]
            for ch in 0..<c {
                var sum: Float = 0
                for i in 0..<weights.count { sum += weights[i] * src[(y * image.w + first + i) * c + ch] }
                horizontal[(y * width + x) * c + ch] = sum
            }
        } }
    }
    var out = Image(w: width, h: height, c: c)
    for y in 0..<height {
        let (first, weights) = ty[y]
        for x in 0..<width { for ch in 0..<c {
            var sum: Float = 0
            for i in 0..<weights.count { sum += weights[i] * horizontal[((first + i) * width + x) * c + ch] }
            out.d[(y * width + x) * c + ch] = sum
        } }
    }
    return out
}

/// Output pixel (u, v) samples the source at m (2 x 3, row-major) applied to (u, v); outside taps take `border`.
fileprivate func warpBilinear(_ source: Image, _ m: [Double], _ width: Int, _ height: Int, border: [Float]) -> Image {
    let c = source.c
    var out = Image(w: width, h: height, c: c)
    source.d.withUnsafeBufferPointer { src in
        for v in 0..<height { for u in 0..<width {
            let x = m[0] * Double(u) + m[1] * Double(v) + m[2], y = m[3] * Double(u) + m[4] * Double(v) + m[5]
            let x0 = Int(floor(x)), y0 = Int(floor(y))
            let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
            for ch in 0..<c {
                func tap(_ yy: Int, _ xx: Int) -> Float {
                    xx >= 0 && xx < source.w && yy >= 0 && yy < source.h ? src[(yy * source.w + xx) * c + ch] : border[ch]
                }
                let top = tap(y0, x0) * (1 - fx) + tap(y0, x0 + 1) * fx
                let bottom = tap(y0 + 1, x0) * (1 - fx) + tap(y0 + 1, x0 + 1) * fx
                out.d[(v * width + u) * c + ch] = top * (1 - fy) + bottom * fy
            }
        } }
    }
    return out
}

private func gaussianKernel(_ size: Int, _ sigmaIn: Double) -> [Float] {
    let fixed: [Int: [Float]] = [1: [1], 3: [0.25, 0.5, 0.25], 5: [0.0625, 0.25, 0.375, 0.25, 0.0625],
                                 7: [0.03125, 0.109375, 0.21875, 0.28125, 0.21875, 0.109375, 0.03125]]
    if sigmaIn <= 0, let kernel = fixed[size] { return kernel }
    let sigma = sigmaIn <= 0 ? 0.3 * (Double(size - 1) * 0.5 - 1) + 0.8 : sigmaIn
    let k = (0..<size).map { i -> Double in let x = Double(i) - Double(size - 1) / 2; return exp(-(x * x) / (2 * sigma * sigma)) }
    let sum = k.reduce(0, +)
    return k.map { Float($0 / sum) }
}

private func reflect101(_ index: Int, _ size: Int) -> Int {
    if size == 1 { return 0 }
    let period = 2 * size - 2
    let i = ((index % period) + period) % period
    return i < size ? i : period - i
}

private func reflect(_ index: Int, _ size: Int) -> Int {
    let period = 2 * size
    let i = ((index % period) + period) % period
    return i < size ? i : period - 1 - i
}

/// Separable weighted sum along x then y; `border` maps an out-of-range index into the plane.
private func separableSum(_ plane: [Float], _ w: Int, _ h: Int, _ weights: [Float], offset: Int, border: (Int, Int) -> Int) -> [Float] {
    let rowIndex = (0..<w).map { x in weights.indices.map { border(x + $0 - offset, w) } }
    let columnIndex = (0..<h).map { y in weights.indices.map { border(y + $0 - offset, h) } }
    var horizontal = [Float](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w {
        var sum: Float = 0
        let index = rowIndex[x]
        for i in 0..<weights.count { sum += weights[i] * plane[y * w + index[i]] }
        horizontal[y * w + x] = sum
    } }
    var out = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        let index = columnIndex[y]
        for x in 0..<w {
            var sum: Float = 0
            for i in 0..<weights.count { sum += weights[i] * horizontal[index[i] * w + x] }
            out[y * w + x] = sum
        }
    }
    return out
}

fileprivate func gaussianBlur(_ plane: [Float], _ w: Int, _ h: Int, size: Int, sigma: Double) -> [Float] {
    separableSum(plane, w, h, gaussianKernel(size, sigma), offset: size / 2, border: reflect101)
}

/// OpenCV erode, size x size rectangle, anchor size / 2; outside the plane counts as the maximum.
fileprivate func erode(_ plane: [Float], _ w: Int, _ h: Int, size: Int) -> [Float] {
    if size <= 1 { return plane }
    let anchor = size / 2
    var horizontal = [Float](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w {
        var m = Float.infinity
        for i in 0..<size { let xx = x + i - anchor; if xx >= 0 && xx < w { m = min(m, plane[y * w + xx]) } }
        horizontal[y * w + x] = m
    } }
    var out = [Float](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w {
        var m = Float.infinity
        for i in 0..<size { let yy = y + i - anchor; if yy >= 0 && yy < h { m = min(m, horizontal[yy * w + x]) } }
        out[y * w + x] = m
    } }
    return out
}

private func boxMeanReflect(_ plane: [Float], _ w: Int, _ h: Int, radius: Int) -> [Float] {
    let n = 2 * radius + 1
    return separableSum(plane, w, h, [Float](repeating: 1 / Float(n), count: n), offset: radius, border: reflect)
}

private let srgbToXYZ: [Double] = [0.412453, 0.357580, 0.180423, 0.212671, 0.715160, 0.072169, 0.019334, 0.119193, 0.950227]
private let white: [Double] = [0.950456, 1.0, 1.088754]
private let xyzToSRGB: [Double] = {
    let m = srgbToXYZ
    let (a, b, c, d, e, f, g, h, i) = (m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
    let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    return [(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
            (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
            (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]
}()

private func rgbToLab(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
    func linear(_ v: Float) -> Double { v <= 0.04045 ? Double(v / 12.92) : pow((Double(v) + 0.055) / 1.055, 2.4) }
    let lr = linear(r), lg = linear(g), lb = linear(b)
    let x = (srgbToXYZ[0] * lr + srgbToXYZ[1] * lg + srgbToXYZ[2] * lb) / white[0]
    let y = (srgbToXYZ[3] * lr + srgbToXYZ[4] * lg + srgbToXYZ[5] * lb) / white[1]
    let z = (srgbToXYZ[6] * lr + srgbToXYZ[7] * lg + srgbToXYZ[8] * lb) / white[2]
    func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
    return (Float(y > 0.008856 ? 116 * f(y) - 16 : 903.3 * y), Float(500 * (f(x) - f(y))), Float(200 * (f(y) - f(z))))
}

private func labToRGB(_ l: Float, _ a: Float, _ b: Float) -> (Float, Float, Float) {
    let l = Double(l)
    let fy = l > 8 ? (l + 16) / 116 : l / 903.3 * 7.787 + 16.0 / 116
    let y = (l > 8 ? fy * fy * fy : l / 903.3) * white[1]
    func inverse(_ f: Double) -> Double { f > 0.206893 ? f * f * f : (f - 16.0 / 116) / 7.787 }
    let x = inverse(fy + Double(a) / 500) * white[0], z = inverse(fy - Double(b) / 200) * white[2]
    func channel(_ row: Int) -> Float {
        let linear = min(max(xyzToSRGB[row * 3] * x + xyzToSRGB[row * 3 + 1] * y + xyzToSRGB[row * 3 + 2] * z, 0), 1)
        return Float(linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055)
    }
    return (channel(0), channel(1), channel(2))
}

/// colour_from_original.py: the restored face's lightness, the original crop's colour through a guided filter.
fileprivate func originalColour(_ restored: Image, _ original: Image, radius: Int = 8, epsilon: Float = 1e-3) -> Image {
    let w = restored.w, h = restored.h, n = w * h
    var restoredLab = [Float](repeating: 0, count: n * 3), originalLab = [Float](repeating: 0, count: n * 3)
    func unit(_ v: Float) -> Float { min(max(v, 0), 255) / 255 }
    for i in 0..<n {
        let r = rgbToLab(unit(restored.d[i * 3]), unit(restored.d[i * 3 + 1]), unit(restored.d[i * 3 + 2]))
        restoredLab[i * 3] = r.0; restoredLab[i * 3 + 1] = r.1; restoredLab[i * 3 + 2] = r.2
        let o = rgbToLab(unit(original.d[i * 3]), unit(original.d[i * 3 + 1]), unit(original.d[i * 3 + 2]))
        originalLab[i * 3] = o.0; originalLab[i * 3 + 1] = o.1; originalLab[i * 3 + 2] = o.2
    }
    let guide = (0..<n).map { restoredLab[$0 * 3] / 100 }
    let meanGuide = boxMeanReflect(guide, w, h, radius: radius)
    let guideSquared = boxMeanReflect(guide.map { $0 * $0 }, w, h, radius: radius)
    let variance = (0..<n).map { guideSquared[$0] - meanGuide[$0] * meanGuide[$0] }
    let channels = (0..<2).map { index -> [Float] in
        let source = (0..<n).map { originalLab[$0 * 3 + 1 + index] }
        let meanSource = boxMeanReflect(source, w, h, radius: radius)
        let product = boxMeanReflect((0..<n).map { guide[$0] * source[$0] }, w, h, radius: radius)
        let slope = (0..<n).map { (product[$0] - meanGuide[$0] * meanSource[$0]) / (variance[$0] + epsilon) }
        let offset = (0..<n).map { meanSource[$0] - slope[$0] * meanGuide[$0] }
        let meanSlope = boxMeanReflect(slope, w, h, radius: radius), meanOffset = boxMeanReflect(offset, w, h, radius: radius)
        return (0..<n).map { meanSlope[$0] * guide[$0] + meanOffset[$0] }
    }
    var out = Image(w: w, h: h, c: 3)
    for i in 0..<n {
        let (r, g, b) = labToRGB(restoredLab[i * 3], channels[0][i], channels[1][i])
        out.d[i * 3] = min(max(r, 0), 1) * 255; out.d[i * 3 + 1] = min(max(g, 0), 1) * 255; out.d[i * 3 + 2] = min(max(b, 0), 1) * 255
    }
    return out
}

/// CodeFormer's is_gray(threshold 10) on the 8-bit photo.
fileprivate func isGrey(_ rgb: Image) -> Bool {
    let n = rgb.w * rgb.h
    func variance(_ a: Int, _ b: Int) -> Double {
        var sum = 0.0, squares = 0.0
        for i in 0..<n { let d = Double(rgb.d[i * 3 + a] - rgb.d[i * 3 + b]); sum += d; squares += d * d }
        let mean = sum / Double(n)
        return squares / Double(n) - mean * mean
    }
    return (variance(0, 1) + variance(1, 2) + variance(2, 0)) / 3 <= 10
}

/// CodeFormer's bgr2gray + adain_npy for grey photos.
fileprivate func greyLike(_ restored: Image, _ crop: Image) -> Image {
    let n = restored.w * restored.h
    let grey = (0..<n).map { 0.2989 * Double(restored.d[$0 * 3]) + 0.5870 * Double(restored.d[$0 * 3 + 1]) + 0.1140 * Double(restored.d[$0 * 3 + 2]) }
    let greyMean = grey.reduce(0, +) / Double(n)
    let greyStd = sqrt(grey.reduce(0) { $0 + ($1 - greyMean) * ($1 - greyMean) } / Double(n) + 1e-5)
    var out = Image(w: restored.w, h: restored.h, c: 3)
    for ch in 0..<3 {
        var sum = 0.0
        for i in 0..<n { sum += Double(crop.d[i * 3 + ch]) }
        let mean = sum / Double(n)
        var squares = 0.0
        for i in 0..<n { let d = Double(crop.d[i * 3 + ch]) - mean; squares += d * d }
        let std = sqrt(squares / Double(n) + 1e-5)
        for i in 0..<n { out.d[i * 3 + ch] = Float((grey[i] - greyMean) / greyStd * std + mean) }
    }
    return out
}

/// Pixels not reachable from outside through non-face pixels (4-connected) become face.
fileprivate func fillHoles(_ face: [Bool], _ w: Int, _ h: Int) -> [Bool] {
    var outside = [Bool](repeating: false, count: w * h)
    var stack: [Int] = []
    func visit(_ i: Int) { if !face[i] && !outside[i] { outside[i] = true; stack.append(i) } }
    for x in 0..<w { visit(x); visit((h - 1) * w + x) }
    for y in 0..<h { visit(y * w); visit(y * w + w - 1) }
    while let i = stack.popLast() {
        let x = i % w, y = i / w
        if y > 0 { visit(i - w) }
        if y < h - 1 { visit(i + w) }
        if x > 0 { visit(i - 1) }
        if x < w - 1 { visit(i + 1) }
    }
    return outside.map { !$0 }
}

/// Least-squares similarity x' = a x - b y + tx, y' = b x + a y + ty (photo -> face), row-major 2 x 3.
fileprivate func similarity(_ points: [SIMD2<Double>], _ template: [SIMD2<Double>]) -> [Double] {
    var ata = [[Double]](repeating: [0, 0, 0, 0], count: 4), atb = [Double](repeating: 0, count: 4)
    for (p, t) in zip(points, template) {
        let rows: [[Double]] = [[p.x, -p.y, 1, 0], [p.y, p.x, 0, 1]], values = [t.x, t.y]
        for r in 0..<2 { for i in 0..<4 {
            atb[i] += rows[r][i] * values[r]
            for j in 0..<4 { ata[i][j] += rows[r][i] * rows[r][j] }
        } }
    }
    var a = (0..<4).map { ata[$0] + [atb[$0]] }
    for col in 0..<4 {
        let pivot = (col..<4).max { abs(a[$0][col]) < abs(a[$1][col]) }!
        a.swapAt(col, pivot)
        for r in 0..<4 where r != col {
            let f = a[r][col] / a[col][col]
            for c in col..<5 { a[r][c] -= f * a[col][c] }
        }
    }
    let s = (0..<4).map { a[$0][4] / a[$0][$0] }
    return [s[0], -s[1], s[2], s[1], s[0], s[3]]
}

fileprivate func invertAffine(_ m: [Double]) -> [Double] {
    let det = m[0] * m[4] - m[1] * m[3]
    let a = m[4] / det, b = -m[1] / det, d = -m[3] / det, e = m[0] / det
    return [a, b, -(a * m[2] + b * m[5]), d, e, -(d * m[2] + e * m[5])]
}

fileprivate func iou(_ a: [Double], _ b: [Double]) -> Double {
    let ix = max(0, min(a[2], b[2]) - max(a[0], b[0])), iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    let inter = ix * iy
    let union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return union > 0 ? inter / union : 0
}

/// RetinaFace PriorBox for a square canvas, canvas pixels: centre x, centre y, w, h per prior.
private func priors(_ canvas: Int) -> [Float] {
    var out: [Float] = []
    for (step, sizes) in [(8, [16, 32]), (16, [64, 128]), (32, [256, 512])] {
        let cells = Int(ceil(Double(canvas) / Double(step)))
        for i in 0..<cells { for j in 0..<cells { for size in sizes {
            out += [(Float(j) + 0.5) * Float(step), (Float(i) + 0.5) * Float(step), Float(size), Float(size)]
        } } }
    }
    return out
}

private func decodeDetections(loc: [Float], score: [Float], landmarks: [Float], priors p: [Float], scale: Double) -> [Detection] {
    let candidates = score.indices.filter { score[$0] > 0.8 }
    let boxes = candidates.map { i -> [Double] in
        let px = Double(p[i * 4]), py = Double(p[i * 4 + 1]), pw = Double(p[i * 4 + 2]), ph = Double(p[i * 4 + 3])
        let cx = px + Double(loc[i * 4]) * 0.1 * pw, cy = py + Double(loc[i * 4 + 1]) * 0.1 * ph
        let w = pw * exp(Double(loc[i * 4 + 2]) * 0.2), h = ph * exp(Double(loc[i * 4 + 3]) * 0.2)
        return [(cx - w / 2) / scale, (cy - h / 2) / scale, (cx + w / 2) / scale, (cy + h / 2) / scale]
    }
    // Highest score first (stable), then greedy NMS as torchvision.ops.nms.
    var order = candidates.indices.sorted { score[candidates[$0]] > score[candidates[$1]] }
    var found: [Detection] = []
    while !order.isEmpty {
        let best = order.removeFirst()
        order.removeAll { iou(boxes[best], boxes[$0]) > 0.4 }
        let i = candidates[best]
        let five = (0..<5).map { k -> SIMD2<Double> in
            [(Double(p[i * 4]) + Double(landmarks[i * 10 + k * 2]) * 0.1 * Double(p[i * 4 + 2])) / scale,
             (Double(p[i * 4 + 1]) + Double(landmarks[i * 10 + k * 2 + 1]) * 0.1 * Double(p[i * 4 + 3])) / scale]
        }
        let gap = five[0] - five[1]
        if (gap.x * gap.x + gap.y * gap.y).squareRoot() >= 5 { found.append(Detection(box: boxes[best], score: Double(score[i]), five: five)) }
    }
    return found
}

/// export_art_classifier.five_views_uint8 geometry with this file's resize, rounded to uint8.
private func fiveViews(_ rgb: Image) -> [Image] {
    let whole = resize(rgb, 224, 224)
    let (lw, lh) = rgb.w <= rgb.h ? (448, Int(448 * Double(rgb.h) / Double(rgb.w))) : (Int(448 * Double(rgb.w) / Double(rgb.h)), 448)
    let large = resize(rgb, lw, lh)
    func pyRound(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }   // Python's round()
    let corners = [((lw - 224) / 2, (lh - 224) / 2), ((lw - 224) / 2, pyRound(Double(lh) * 0.15)),
                   (max(0, pyRound(Double(lw) * 0.2)), (lh - 224) / 2), (max(0, pyRound(Double(lw) * 0.8) - 224), (lh - 224) / 2)]
    var views = [whole] + corners.map { x0, y0 -> Image in
        var view = Image(w: 224, h: 224, c: 3)
        for y in 0..<224 { for x in 0..<224 { for c in 0..<3 { view.d[(y * 224 + x) * 3 + c] = large.d[((y0 + y) * lw + x0 + x) * 3 + c] } } }
        return view
    }
    for v in views.indices { for i in views[v].d.indices { views[v].d[i] = min(max(views[v].d[i].rounded(.toNearestOrEven), 0), 255) } }
    return views
}

/// Blend one restored face into the 2x image in place; toFace is the photo -> face similarity.
private func pasteFace(_ image: inout Image, _ restored: Image, _ faceMask: [Float], _ toFace: [Double]) {
    var inverse = invertAffine(toFace).map { $0 * 2 }
    inverse[2] += 1; inverse[5] += 1                                   // CodeFormer's back-alignment offset, 0.5 x scale
    let outputToFace = invertAffine(inverse)
    let corners: [(Double, Double)] = [(0, 0), (512, 0), (0, 512), (512, 512)]
    let xs = corners.map { inverse[0] * $0.0 + inverse[1] * $0.1 + inverse[2] }
    let ys = corners.map { inverse[3] * $0.0 + inverse[4] * $0.1 + inverse[5] }
    let x0 = max(Int(floor(xs.min()!)) - 2, 0), y0 = max(Int(floor(ys.min()!)) - 2, 0)
    let x1 = min(Int(ceil(xs.max()!)) + 3, image.w), y1 = min(Int(ceil(ys.max()!)) + 3, image.h)
    guard x1 > x0, y1 > y0 else { return }
    var shift = outputToFace
    shift[2] += shift[0] * Double(x0) + shift[1] * Double(y0)
    shift[5] += shift[3] * Double(x0) + shift[4] * Double(y0)
    let rw = x1 - x0, rh = y1 - y0
    var square = warpBilinear(Image(w: 512, h: 512, c: 1, d: [Float](repeating: 1, count: 512 * 512)), shift, rw, rh, border: [0]).d
    square = erode(square, rw, rh, size: 4)
    let edge = Int(square.reduce(0.0) { $0 + Double($1) }.squareRoot()) / 20
    let softSquare = gaussianBlur(erode(square, rw, rh, size: edge * 2), rw, rh, size: edge * 2 + 1, sigma: 0)
    let parse = warpBilinear(Image(w: 512, h: 512, c: 1, d: faceMask), shift, rw, rh, border: [0]).d
    let pasted = warpBilinear(restored, shift, rw, rh, border: [0, 0, 0])
    for v in 0..<rh { for u in 0..<rw {
        let i = v * rw + u, soft = min(parse[i], softSquare[i])
        for c in 0..<3 {
            let at = ((y0 + v) * image.w + x0 + u) * 3 + c
            image.d[at] = soft * (pasted.d[i * 3 + c] * square[i]) + (1 - soft) * image.d[at]
        }
    } }
}
