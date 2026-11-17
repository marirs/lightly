import CoreGraphics
import CoreML
import Foundation

/// Enhance (1.3, docs/roadmap.md): a photo at twice its size, with small and soft faces restored. The pipeline measured
/// in experiments/enhance-2026-11-12 (README steps 2a-2g; phone_pipeline.py's docstring lists the steps), moved from the
/// harness that ran it on the review phones:
///
///  1. painting check (art classifier): paintings keep their faces as painted, only the background upscale runs;
///  2. faces: RetinaFace MobileNet-0.25 at short side 640 and 960, eye gap >= 5 px;
///  3. faces with a detector eye gap under 8 px are left to the background upscale (step 2g, owner 2026-11-16);
///  4. face points from Face Mesh (the app's Sunglasses model), else the detector's five;
///  5. background: realesr-general-x4v3 on 384 px tiles with >= 16 px context, 4x averaged down to 2x (step 2e);
///  6. faces: CodeFormer w 0.8 on CPU + GPU on every iPhone (never the Neural Engine: the SE 3's painted a blotch on
///     lips, step 2c), the original colour put back, a face-skin paste mask (the app's selfie multiclass model).
///
/// DEFERRED(enhance-ui): nothing calls this yet. The Lightly 2 design has no Enhance screen; the screen, its states
/// wait for an approved design. Photos longer than 2000 px are shrunk to that long side first (owner, 2026-11-17), which
/// bounds memory: the 2x float image alone is 48 bytes per working pixel (2000 x 1500: 144 MB).
final class EnhanceEngine: @unchecked Sendable {
    // @unchecked: MLModel is not Sendable. One engine runs one photo at a time (`lock`); the models are only read.

    enum Failure: Error, Equatable {
        /// A model is not in this build (bundle_enhance_models.sh found no package).
        case modelUnavailable(String)
        case modelFailed(String)
        case cancelled
    }

    struct Face: Equatable {
        /// Detector box in input pixels: x0, y0, x1, y1.
        let box: [Double]
        let eyeGap: Double
        /// False for a face under `restoreEyeGapMin`, left to the background upscale.
        let restored: Bool
        /// Where the alignment points came from: Face Mesh, or the detector (mesh presence under 0.5, or no finite
        /// mesh output). Nil for a face that is not restored.
        let pointSource: PointSource?
        /// The five alignment points (eyes, nose tip, mouth corners) in input pixels; empty when not restored.
        let points: [SIMD2<Double>]
    }

    enum PointSource: Equatable { case faceMesh, detector }

    struct Result {
        /// 2x the input (2x the 2000 px cap for larger photos), 8-bit sRGB, opaque.
        let image: CGImage
        let isPainting: Bool
        let faces: [Face]
    }

    static let scale = 2
    static let artThreshold: Float = 0.8
    /// Step 2g: below an 8 px eye gap CodeFormer invents the face rather than restoring it (owner's choice, 2026-11-16).
    static let restoreEyeGapMin = 8.0
    /// Owner, 2026-11-17: photos longer than 2000 px are shrunk to that long side before enhancing (output 4000 px).
    static let inputLongSideMax = 2000
    static let tile = 384
    static let tilePad = 16
    static let detectionSizes = [640: 1024, 960: 1536]   // short side -> square canvas
    static let extraDetectionIoU = 0.3                  // 960 detections kept only where no 640 box overlaps
    static let modelNames = ["enhance-art-classifier", "enhance-face-detector-640", "enhance-face-detector-960",
                             "enhance-general-x4v3-384", "enhance-codeformer-w0.8-512",
                             "face_landmarks_256_fp16", "selfie_multiclass_256_fp16"]

    private static let detectorMeanRGB: [Float] = [123, 117, 104]
    private static let meshFive = [468, 473, 1, 61, 291]
    private static let meshPresenceMin = 0.5
    private static let faceSkin = 3
    private static let faceTemplate: [SIMD2<Double>] = [
        [192.98138, 239.94708], [318.90277, 240.1936], [256.63416, 314.01935], [201.26117, 371.41043], [313.08905, 371.15118],
    ]
    private static let cropBorderRGB: [Float] = [132, 133, 135]   // CodeFormer's (135, 133, 132) in BGR

    private let art: MLModel, detectors: [Int: MLModel], mesh: MLModel, multiclass: MLModel
    private let upscaler: MLModel, codeformer: MLModel
    private let lock = NSLock()

    /// Loads every model from `bundle`; throws `.modelUnavailable` naming the first one missing.
    init(bundle: Bundle = .main) throws {
        func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else { throw Failure.modelUnavailable(name) }
            let configuration = MLModelConfiguration()
            #if targetEnvironment(simulator)
            // The simulator's GPU path returned all-zero outputs for these models (iOS 27 simulator, 2026-11-17).
            configuration.computeUnits = .cpuOnly
            #else
            configuration.computeUnits = units
            #endif
            do { return try MLModel(contentsOf: url, configuration: configuration) } catch {
                throw Failure.modelFailed("\(name): \(error.localizedDescription)")
            }
        }
        art = try load("enhance-art-classifier", .all)
        detectors = [640: try load("enhance-face-detector-640", .all), 960: try load("enhance-face-detector-960", .all)]
        mesh = try load("face_landmarks_256_fp16", .all)
        multiclass = try load("selfie_multiclass_256_fp16", .all)
        upscaler = try load("enhance-general-x4v3-384", .all)
        codeformer = try load("enhance-codeformer-w0.8-512", .cpuAndGPU)
    }

    /// True when every model is in `bundle`, without loading them.
    static func isAvailable(in bundle: Bundle = .main) -> Bool {
        modelNames.allSatisfy { bundle.url(forResource: $0, withExtension: "mlmodelc") != nil }
    }

    /// Enhances `photo` (already upright). `isCancelled` is polled between model runs; a cancelled run throws
    /// `.cancelled` and leaves nothing behind.
    func enhance(_ photo: CGImage, isCancelled: () -> Bool = { false }) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        let rgb = Self.floatRGB(photo)
        let (image, isPainting, faces) = try enhance(rgb, isCancelled: isCancelled)
        return Result(image: Self.cgImage(image), isPainting: isPainting, faces: faces)
    }

    func enhance(_ photo: EnhanceMaths.Image, isCancelled: () -> Bool) throws -> (EnhanceMaths.Image, Bool, [Face]) {
        func checkpoint() throws { if isCancelled() { throw Failure.cancelled } }
        let size = Self.inputSize(width: photo.w, height: photo.h)
        // Same antialiased resize as every other step (phone_pipeline.resize), kept in floats.
        let rgb = size == (photo.w, photo.h) ? photo : EnhanceMaths.resize(photo, size.width, size.height)
        let isPainting = try artProbability(rgb) >= Self.artThreshold
        try checkpoint()
        var faces: [Face] = [], restoreFives: [[SIMD2<Double>]] = []
        if !isPainting {
            for detection in try detectFaces(rgb) {
                try checkpoint()
                let eyes = detection.five[0] - detection.five[1]
                let gap = (eyes.x * eyes.x + eyes.y * eyes.y).squareRoot()
                guard gap >= Self.restoreEyeGapMin else {
                    faces.append(Face(box: detection.box, eyeGap: gap, restored: false, pointSource: nil, points: []))
                    continue
                }
                let (five, source) = try meshFive(rgb, detection)
                guard Self.canAlign(five) else {
                    faces.append(Face(box: detection.box, eyeGap: gap, restored: false, pointSource: nil, points: []))
                    continue
                }
                faces.append(Face(box: detection.box, eyeGap: gap, restored: true, pointSource: source, points: five))
                restoreFives.append(five)
            }
        }
        try checkpoint()
        var image = try upscaleBackground(rgb, checkpoint: checkpoint)
        let grey = EnhanceMaths.isGrey(rgb)
        for five in restoreFives {
            try checkpoint()
            try restoreFace(five, from: rgb, grey: grey, into: &image)
        }
        return (image, isPainting, faces)
    }

    // MARK: - Steps

    private func detectFaces(_ rgb: EnhanceMaths.Image) throws -> [EnhanceMaths.Detection] {
        let found = try detect(rgb, short: 640)
        let extra = try detect(rgb, short: 960).filter { d in
            found.allSatisfy { EnhanceMaths.iou(d.box, $0.box) < Self.extraDetectionIoU }
        }
        // v3 differs: detections with a non-finite box or point are dropped (the harness had no such check).
        return (found + extra).filter { d in d.box.allSatisfy(\.isFinite) && d.five.allSatisfy { $0.x.isFinite && $0.y.isFinite } }
    }

    private func restoreFace(_ five: [SIMD2<Double>], from rgb: EnhanceMaths.Image, grey: Bool,
                             into image: inout EnhanceMaths.Image) throws {
        let toFace = EnhanceMaths.similarity(five, Self.faceTemplate)
        let crop = EnhanceMaths.warpBilinear(rgb, EnhanceMaths.invertAffine(toFace), 512, 512, border: Self.cropBorderRGB)
        var restored = EnhanceMaths.originalColour(try restore(crop), crop)
        if grey { restored = EnhanceMaths.greyLike(restored, crop) }
        let mask = try faceMask(restored)
        EnhanceMaths.pasteFace(&image, restored, mask, toFace)
    }

    // MARK: - Models

    private func array(_ shape: [Int], _ fill: (UnsafeMutablePointer<Float>) -> Void) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        fill(array.dataPointer.bindMemory(to: Float.self, capacity: array.count))
        return array
    }

    /// One prediction, its named outputs copied into Swift arrays. Core ML's buffers are autoreleased: without the pool
    /// a photo's background tiles (12 MB each) pile up until the process is killed (harness, SE 3, 2026-11-15).
    private func predict(_ model: MLModel, _ inputs: [String: MLMultiArray], _ names: [String]) throws -> [String: [Float]] {
        try autoreleasepool {
            let provider = try MLDictionaryFeatureProvider(dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) })
            let output: MLFeatureProvider
            do { output = try model.prediction(from: provider) } catch { throw Failure.modelFailed(error.localizedDescription) }
            var values: [String: [Float]] = [:]
            for name in names {
                guard let array = output.featureValue(for: name)?.multiArrayValue else { throw Failure.modelFailed("no output \(name)") }
                values[name] = Self.floats(array)
            }
            return values
        }
    }

    /// A Core ML output's values in logical (row-major) order, whatever its strides and storage.
    /// v3 differs from the harness (and SunglassesAnalyzer.floats), which read `dataPointer` directly: an output backed
    /// by a pixel buffer must be read under its lock, and on the iOS 27 simulator every Enhance output came back as
    /// zeros through `dataPointer` (2026-11-17). withUnsafeBufferPointer(ofType:) locks and gives the real storage.
    static func floats(_ array: MLMultiArray) -> [Float] {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        func gather<T>(_ buffer: UnsafeBufferPointer<T>, _ convert: (T) -> Float) -> [Float] {
            let count = shape.reduce(1, *)
            var expected = 1
            var contiguous = true
            for (dim, stride) in zip(shape, strides).reversed() {
                if dim > 1 && stride != expected { contiguous = false }
                expected *= dim
            }
            if contiguous { return (0..<count).map { convert(buffer[$0]) } }
            var out = [Float](repeating: 0, count: count)
            for index in 0..<count {
                var rest = index, offset = 0
                for axis in stride(from: shape.count - 1, through: 0, by: -1) {
                    offset += (rest % shape[axis]) * strides[axis]
                    rest /= shape[axis]
                }
                out[index] = convert(buffer[offset])
            }
            return out
        }
        switch array.dataType {
        case .float32: return array.withUnsafeBufferPointer(ofType: Float.self) { gather($0) { $0 } }
        case .float16: return array.withUnsafeBufferPointer(ofType: Float16.self) { gather($0) { Float($0) } }
        case .double: return array.withUnsafeBufferPointer(ofType: Double.self) { gather($0) { Float($0) } }
        default: return (0..<array.count).map { array[$0].floatValue }
        }
    }

    private func artProbability(_ rgb: EnhanceMaths.Image) throws -> Float {
        let views = EnhanceMaths.fiveViews(rgb)
        let input = try array([5, 3, 224, 224]) { p in
            for (v, view) in views.enumerated() { for c in 0..<3 { for i in 0..<(224 * 224) {
                p[(v * 3 + c) * 224 * 224 + i] = view.d[i * 3 + c] / 255
            } } }
        }
        return try predict(art, ["views": input], ["art_probability"])["art_probability"]![0]
    }

    private func detect(_ rgb: EnhanceMaths.Image, short: Int) throws -> [EnhanceMaths.Detection] {
        let canvas = Self.detectionSizes[short]!
        let scale = Self.detectionScale(width: rgb.w, height: rgb.h, short: short, canvas: canvas)
        let nw = Int(Double(rgb.w) * scale), nh = Int(Double(rgb.h) * scale)
        let small = EnhanceMaths.resize(rgb, nw, nh)
        let input = try array([1, 3, canvas, canvas]) { p in
            for c in 0..<3 { for y in 0..<canvas { for x in 0..<canvas {
                let value = x < nw && y < nh ? small.d[(y * nw + x) * 3 + c] : Self.detectorMeanRGB[c]
                p[(c * canvas + y) * canvas + x] = value / 255
            } } }
        }
        let output = try predict(detectors[short]!, ["image": input], ["loc", "score", "landmarks"])
        return EnhanceMaths.decodeDetections(loc: output["loc"]!, score: output["score"]!, landmarks: output["landmarks"]!,
                                             priors: EnhanceMaths.priors(canvas), scale: scale)
    }

    /// The photo's short side goes to `short`, unless its long side would then pass the canvas (photos longer than
    /// 1.6 : 1): then the long side fits the canvas. Photos that fit keep exactly that scale. phone_pipeline.detection_scale.
    /// phone_pipeline.input_size: unchanged up to `cap` on the long side, else shrunk to it (half-up rounding).
    static func inputSize(width: Int, height: Int, cap: Int = inputLongSideMax) -> (width: Int, height: Int) {
        let long = max(width, height)
        guard long > cap else { return (width, height) }
        func shrink(_ side: Int) -> Int { max(1, Int(Double(side) * Double(cap) / Double(long) + 0.5)) }
        return (shrink(width), shrink(height))
    }

    static func detectionScale(width: Int, height: Int, short: Int, canvas: Int) -> Double {
        let scale = Double(short) / Double(min(width, height))
        return Int(Double(max(width, height)) * scale) <= canvas ? scale : Double(canvas) / Double(max(width, height))
    }

    private func meshRun(_ rgb: EnhanceMaths.Image, centre: SIMD2<Double>, side: Double, roll: Double) throws -> ([SIMD2<Double>], Double) {
        let k = side / 256, c = cos(roll), s = sin(roll)
        let toPhoto = [k * c, -k * s, centre.x - k * (c * 128 - s * 128), k * s, k * c, centre.y - k * (s * 128 + c * 128)]
        let crop = EnhanceMaths.warpBilinear(rgb, toPhoto, 256, 256, border: [0, 0, 0])
        let input = try array([1, 256, 256, 3]) { p in for i in 0..<crop.d.count { p[i] = crop.d[i] / 255 } }
        let output = try predict(mesh, ["image": input], ["landmarks", "face_flag"])
        let raw = output["landmarks"]!
        let flag = Double(output["face_flag"]![0])
        let points = (0..<478).map { i -> SIMD2<Double> in
            let u = Double(raw[i * 3]), v = Double(raw[i * 3 + 1])
            return [toPhoto[0] * u + toPhoto[1] * v + toPhoto[2], toPhoto[3] * u + toPhoto[4] * v + toPhoto[5]]
        }
        return (points, 1 / (1 + exp(-flag)))
    }

    /// Face Mesh on a crop rolled to the detector's eye line, refined once on its own points; its iris centres, nose
    /// tip and mouth corners when its face presence is >= 0.5, else the detector's five points (step 2c, 2f).
    private func meshFive(_ rgb: EnhanceMaths.Image, _ detection: EnhanceMaths.Detection) throws -> ([SIMD2<Double>], PointSource) {
        let b = detection.box, five = detection.five
        let eye = five[1] - five[0]
        var (points, presence) = try meshRun(rgb, centre: [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2],
                                             side: max(b[2] - b[0], b[3] - b[1]) * 1.5, roll: atan2(eye.y, eye.x))
        // v3 differs: the harness had no finite checks. A non-finite mesh output (seen on the iOS simulator's CPU path,
        // 2026-11-17) would make the refining crop and the alignment NaN; the detector's points are the fallback.
        guard presence.isFinite, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return (five, .detector) }
        let line = points[263] - points[33]
        var lo = SIMD2<Double>(repeating: .greatestFiniteMagnitude), hi = SIMD2<Double>(repeating: -.greatestFiniteMagnitude)
        for p in points[0..<468] { lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p) }
        let (refined, refinedPresence) = try meshRun(rgb, centre: (lo + hi) / 2, side: max(hi.x - lo.x, hi.y - lo.y) * 1.5,
                                                     roll: atan2(line.y, line.x))
        if refinedPresence >= presence - 0.1 { points = refined; presence = refinedPresence }
        let meshPoints = Self.meshFive.map { points[$0] }
        let usable = presence.isFinite && presence >= Self.meshPresenceMin && Self.canAlign(meshPoints)
        return usable ? (meshPoints, .faceMesh) : (five, .detector)
    }

    /// True when the five points give a finite similarity onto the template (degenerate points, e.g. all equal,
    /// make the least-squares solve divide by zero).
    static func canAlign(_ five: [SIMD2<Double>]) -> Bool {
        guard five.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        // Collapsed points (all at one spot) still solve to finite garbage; the eyes must be apart.
        let eyes = five[1] - five[0]
        guard (eyes.x * eyes.x + eyes.y * eyes.y).squareRoot() >= 1 else { return false }
        let m = EnhanceMaths.similarity(five, faceTemplate)
        return m.allSatisfy(\.isFinite) && m[0] * m[4] - m[1] * m[3] > 0
    }

    private func restore(_ face: EnhanceMaths.Image) throws -> EnhanceMaths.Image {
        let input = try array([1, 3, 512, 512]) { p in
            for c in 0..<3 { for i in 0..<(512 * 512) { p[c * 512 * 512 + i] = face.d[i * 3 + c] / 127.5 - 1 } }
        }
        let values = try predict(codeformer, ["face": input], ["output"])["output"]!
        // A non-finite face would paste NaN into the photo; fail the run instead (the caller shows its failure state).
        guard values.allSatisfy(\.isFinite) else { throw Failure.modelFailed("CodeFormer gave non-finite values") }
        var out = EnhanceMaths.Image(w: 512, h: 512, c: 3)
        for c in 0..<3 { for i in 0..<(512 * 512) { out.d[i * 3 + c] = (min(max(values[c * 512 * 512 + i], -1), 1) + 1) * 127.5 } }
        return out
    }

    /// general-x4v3 on 384 px windows laid out by tileWindows; the 4x result is averaged 2 x 2 to 2x.
    private func upscaleBackground(_ rgb: EnhanceMaths.Image, checkpoint: () throws -> Void) throws -> EnhanceMaths.Image {
        let tile = Self.tile, up = 4 * tile
        var out = EnhanceMaths.Image(w: rgb.w * 2, h: rgb.h * 2, c: 3)
        for (y, ch, wy) in EnhanceMaths.tileWindows(rgb.h, tile, Self.tilePad) {
            for (x, cw, wx) in EnhanceMaths.tileWindows(rgb.w, tile, Self.tilePad) {
                try checkpoint()
                // Mirrored reads only matter for a photo side under a tile; otherwise mirrorIndex is the identity.
                let rows = (0..<tile).map { EnhanceMaths.mirrorIndex(wy + $0, rgb.h) }
                let columns = (0..<tile).map { EnhanceMaths.mirrorIndex(wx + $0, rgb.w) }
                let input = try array([1, 3, tile, tile]) { p in
                    for c in 0..<3 { for ty in 0..<tile { for tx in 0..<tile {
                        p[(c * tile + ty) * tile + tx] = rgb.d[(rows[ty] * rgb.w + columns[tx]) * 3 + c] / 255
                    } } }
                }
                let values = try predict(upscaler, ["input": input], ["output"])["output"]!
                let ox = (x - wx) * 4, oy = (y - wy) * 4
                for c in 0..<3 { for yy in 0..<(ch * 2) { for xx in 0..<(cw * 2) {
                    var sum: Float = 0
                    for dy in 0..<2 { for dx in 0..<2 {
                        sum += min(max(values[(c * up + oy + yy * 2 + dy) * up + ox + xx * 2 + dx], 0), 1)
                    } }
                    out.d[((y * 2 + yy) * out.w + x * 2 + xx) * 3 + c] = sum / 4 * 255
                } } }
            }
        }
        return out
    }

    private func faceMask(_ restored: EnhanceMaths.Image) throws -> [Float] {
        var clipped = restored
        for i in 0..<clipped.d.count { clipped.d[i] = min(max(clipped.d[i], 0), 255) }
        let small = EnhanceMaths.resize(clipped, 256, 256)
        let input = try array([1, 256, 256, 3]) { p in for i in 0..<small.d.count { p[i] = small.d[i] / 255 } }
        let logits = try predict(multiclass, ["image": input], ["logits"])["logits"]!
        var face = [Bool](repeating: false, count: 256 * 256)
        for i in 0..<(256 * 256) {
            var best = 0
            for c in 1..<6 where logits[i * 6 + c] > logits[i * 6 + best] { best = c }
            face[i] = best == Self.faceSkin
        }
        let filled = EnhanceMaths.fillHoles(face, 256, 256)
        var plane = EnhanceMaths.Image(w: 256, h: 256, c: 1)
        for i in 0..<filled.count { plane.d[i] = filled[i] ? 255 : 0 }
        var mask = EnhanceMaths.resize(plane, 512, 512).d
        mask = EnhanceMaths.gaussianBlur(EnhanceMaths.gaussianBlur(mask, 512, 512, size: 101, sigma: 11), 512, 512, size: 101, sigma: 11)
        for y in 0..<512 { for x in 0..<512 {
            mask[y * 512 + x] = (y < 10 || y >= 502 || x < 10 || x >= 502) ? 0 : mask[y * 512 + x] / 255
        } }
        return mask
    }

    // MARK: - Pixels in and out

    /// 8-bit sRGB pixels as floats 0-255 (drawn into an sRGB context, so other colour spaces are converted).
    static func floatRGB(_ photo: CGImage) -> EnhanceMaths.Image {
        let w = photo.width, h = photo.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(photo, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var image = EnhanceMaths.Image(w: w, h: h, c: 3)
        for i in 0..<(w * h) { for c in 0..<3 { image.d[i * 3 + c] = Float(bytes[i * 4 + c]) } }
        return image
    }

    /// Rounded and clipped to 8-bit sRGB, opaque.
    static func cgImage(_ image: EnhanceMaths.Image) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: image.w * image.h * 4)
        for i in 0..<(image.w * image.h) { for c in 0..<3 { bytes[i * 4 + c] = UInt8(min(max(image.d[i * 3 + c], 0), 255).rounded()) } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: image.w, height: image.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
