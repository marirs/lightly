import CoreGraphics
import CoreML
import CryptoKit
import Foundation
import OSLog
import simd

/// Edit › Remove (docs/v1/remove-evaluation.md §4, §7): one engine, LaMa big-lama at a fixed 512
/// input, for every stroke. A stroke is inpainted once, on the full-resolution source pixels, and
/// its result is kept as a patch (crop rect + RGB + feathered alpha) that preview and export both
/// composite: the pixels are identical, nothing is recomputed later, and changing tone or colour
/// afterwards never re-runs the model.
///
/// No classical fill exists and nothing is swapped in silently: when the model is missing (not
/// bundled, or the release gate is closed) or fails, the stroke fails and the panel shows the
/// approved "Couldn't remove that area." state.
enum RemoveEngine {

    /// The model input side (fixed, remove-evaluation §5.2).
    static let side = 512
    /// The context window around a stroke, as a multiple of its extent (§4).
    static let contextFactor = 2.2
    /// Paste-back feather outside the brush, in full-resolution pixels (§4).
    static let featherPixels = 3.0

    enum Failure: Error, Equatable {
        /// No model in this build (not bundled, or the release gate is closed).
        case modelUnavailable
        case modelFailed(String)
        case emptyStroke
    }

    /// Brush radius as a fraction of the long edge for the panel's "Brush size" (0…100); the same
    /// mapping Background's refine brush uses.
    static func radius(forBrushSize size: Double) -> Double { 0.005 + 0.055 * size / 100 }

    // MARK: Inpainting one stroke

    /// Inpaints `stroke` (source coordinates) on `source` (full-resolution RGBA8, the earlier
    /// patches already composited) and returns its patch.
    static func patch(for stroke: EditRecipe.RemoveStroke, source: [UInt8], width: Int, height: Int,
                      inpainter: any Inpainting) async throws -> RemovePatch {
        let longEdge = Double(max(width, height))
        let radius = stroke.radius * longEdge
        let points = stroke.points.map { SIMD2($0.x * Double(width), $0.y * Double(height)) }
        guard !points.isEmpty else { throw Failure.emptyStroke }
        // The area the model fills: the brush plus the feather band, so the feathered paste-back
        // blends model pixels, never the original object.
        let reach = radius + featherPixels
        let xs = points.map(\.x), ys = points.map(\.y)
        let box = (x0: max(Int((xs.min()! - reach).rounded(.down)), 0), y0: max(Int((ys.min()! - reach).rounded(.down)), 0),
                   x1: min(Int((xs.max()! + reach).rounded(.up)), width), y1: min(Int((ys.max()! + reach).rounded(.up)), height))
        guard box.x1 > box.x0, box.y1 > box.y0 else { throw Failure.emptyStroke }

        // Route (§4): a window of 2.2 × the extent; at most 512 → a native 512 crop without
        // resampling; larger → the window resized to 512 and back.
        // DEFERRED(remove follow-up): the tiled-native route for long thin strokes (wires); they
        // take the downscaled route here, which feeds the same engine.
        let extent = Double(max(box.x1 - box.x0, box.y1 - box.y0))
        let wanted = max(Double(side), (contextFactor * extent).rounded(.up))
        let windowSide = min(Int(wanted), min(width, height))
        let centreX = Double(box.x0 + box.x1) / 2, centreY = Double(box.y0 + box.y1) / 2
        let wx = min(max(Int((centreX - Double(windowSide) / 2).rounded()), 0), width - windowSide)
        let wy = min(max(Int((centreY - Double(windowSide) / 2).rounded()), 0), height - windowSide)
        let scale = Double(windowSide) / Double(side)

        // Model input, CHW, 0…1, and the mask (1 = remove) at model resolution.
        var image = [Float](repeating: 0, count: 3 * side * side)
        var mask = [Float](repeating: 0, count: side * side)
        for my in 0..<side {
            for mx in 0..<side {
                let sx = Double(wx) + (Double(mx) + 0.5) * scale, sy = Double(wy) + (Double(my) + 0.5) * scale
                let rgb = bilinear(source, width: width, height: height, x: sx - 0.5, y: sy - 0.5)
                for c in 0..<3 { image[c * side * side + my * side + mx] = rgb[c] }
                if distance(SIMD2(sx, sy), toPolyline: points) <= reach { mask[my * side + mx] = 1 }
            }
        }
        try Task.checkCancellation()
        let result = try await inpainter.inpaint(image: image, mask: mask, side: side)
        try Task.checkCancellation()

        // Paste back only the brush (alpha 1) and its 3 px feather, at full resolution.
        let pw = box.x1 - box.x0, ph = box.y1 - box.y0
        var rgba = [UInt8](repeating: 0, count: pw * ph * 4)
        for row in 0..<ph {
            for column in 0..<pw {
                let x = Double(box.x0 + column) + 0.5, y = Double(box.y0 + row) + 0.5
                let d = distance(SIMD2(x, y), toPolyline: points)
                let alpha = min(max(1 - (d - radius) / featherPixels, 0), 1)
                guard alpha > 0 else { continue }
                // Model pixel coordinates of this source pixel.
                let mx = (x - Double(wx)) / scale - 0.5, my = (y - Double(wy)) / scale - 0.5
                let o = (row * pw + column) * 4
                for c in 0..<3 {
                    let v = bilinearPlane(result, plane: c, side: side, x: mx, y: my)
                    rgba[o + c] = UInt8(min(max(v * 255 + 0.5, 0), 255))
                }
                rgba[o + 3] = UInt8(min(max(alpha * 255 + 0.5, 0), 255))
            }
        }
        return RemovePatch(x: box.x0, y: box.y0, width: pw, height: ph, sourceWidth: width, sourceHeight: height, rgba: rgba)
    }

    // MARK: Compositing

    /// Composites `patches` (made at the source's full resolution) into RGBA8 pixels of the same
    /// photo at any resolution: export at 1:1, the preview scaled.
    static func composite(_ patches: [RemovePatch], into pixels: inout [UInt8], width: Int, height: Int) {
        for patch in patches {
            let sx = Double(width) / Double(patch.sourceWidth), sy = Double(height) / Double(patch.sourceHeight)
            let x0 = max(Int((Double(patch.x) * sx).rounded(.down)), 0), y0 = max(Int((Double(patch.y) * sy).rounded(.down)), 0)
            let x1 = min(Int((Double(patch.x + patch.width) * sx).rounded(.up)), width)
            let y1 = min(Int((Double(patch.y + patch.height) * sy).rounded(.up)), height)
            guard x1 > x0, y1 > y0 else { continue }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    // This pixel's centre in patch pixel coordinates.
                    let px = (Double(x) + 0.5) / sx - Double(patch.x) - 0.5, py = (Double(y) + 0.5) / sy - Double(patch.y) - 0.5
                    guard px > -1, py > -1, px < Double(patch.width), py < Double(patch.height) else { continue }
                    let sample = patch.sample(x: px, y: py)
                    let a = sample.w
                    guard a > 0 else { continue }
                    let o = (y * width + x) * 4
                    for c in 0..<3 {
                        let blended = Double(pixels[o + c]) * (1 - a) + sample[c] * 255 * a
                        pixels[o + c] = UInt8(min(max(blended.rounded(), 0), 255))
                    }
                }
            }
        }
    }

    // MARK: Helpers

    static func distance(_ p: SIMD2<Double>, toPolyline points: [SIMD2<Double>]) -> Double {
        guard points.count > 1 else { return simd_distance(p, points[0]) }
        var best = Double.infinity
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1], ab = b - a
            let length2 = simd_length_squared(ab)
            let t = length2 > 0 ? min(max(simd_dot(p - a, ab) / length2, 0), 1) : 0
            best = min(best, simd_distance(p, a + ab * t))
        }
        return best
    }

    /// RGB (0…1) at continuous pixel coordinates (centres at integers), edge-clamped.
    static func bilinear(_ rgba: [UInt8], width: Int, height: Int, x: Double, y: Double) -> SIMD3<Float> {
        let cx = min(max(x, 0), Double(width - 1)), cy = min(max(y, 0), Double(height - 1))
        let x0 = Int(cx), y0 = Int(cy), x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = Float(cx - Double(x0)), ty = Float(cy - Double(y0))
        func at(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let o = (y * width + x) * 4
            return SIMD3(Float(rgba[o]), Float(rgba[o + 1]), Float(rgba[o + 2])) / 255
        }
        let top = at(x0, y0) + (at(x1, y0) - at(x0, y0)) * tx
        let bottom = at(x0, y1) + (at(x1, y1) - at(x0, y1)) * tx
        return top + (bottom - top) * ty
    }

    static func bilinearPlane(_ chw: [Float], plane: Int, side: Int, x: Double, y: Double) -> Double {
        let cx = min(max(x, 0), Double(side - 1)), cy = min(max(y, 0), Double(side - 1))
        let x0 = Int(cx), y0 = Int(cy), x1 = min(x0 + 1, side - 1), y1 = min(y0 + 1, side - 1)
        let tx = cx - Double(x0), ty = cy - Double(y0)
        let base = plane * side * side
        func at(_ x: Int, _ y: Int) -> Double { Double(chw[base + y * side + x]) }
        let top = at(x0, y0) + (at(x1, y0) - at(x0, y0)) * tx
        let bottom = at(x0, y1) + (at(x1, y1) - at(x0, y1)) * tx
        return top + (bottom - top) * ty
    }
}

/// One stroke's result: the inpainted pixels inside `x, y, width, height` of the full-resolution
/// source (`sourceWidth × sourceHeight`), with the feathered brush as alpha.
struct RemovePatch: Equatable, Sendable {
    let x: Int, y: Int, width: Int, height: Int
    let sourceWidth: Int, sourceHeight: Int
    let rgba: [UInt8]

    /// The digest the recipe stores (`derivedRef.sha256`): the rect, the source size and the bytes
    /// (exactly the stored file's bytes, RemovePatchStore.encode).
    var sha256: String { RemovePatchStore.digest(of: RemovePatchStore.encode(self)) }

    /// Premultiplied-free RGBA (0…1) at continuous patch coordinates; outside counts as alpha 0.
    func sample(x: Double, y: Double) -> SIMD4<Double> {
        func at(_ px: Int, _ py: Int) -> SIMD4<Double> {
            guard px >= 0, py >= 0, px < width, py < height else { return .zero }
            let o = (py * width + px) * 4
            return SIMD4(Double(rgba[o]), Double(rgba[o + 1]), Double(rgba[o + 2]), Double(rgba[o + 3])) / 255
        }
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let tx = x - Double(x0), ty = y - Double(y0)
        // Alpha-weighted bilinear so transparent neighbours do not darken the colour.
        var sum = SIMD4<Double>.zero
        for (dx, dy, w) in [(0, 0, (1 - tx) * (1 - ty)), (1, 0, tx * (1 - ty)), (0, 1, (1 - tx) * ty), (1, 1, tx * ty)] {
            let s = at(x0 + dx, y0 + dy)
            sum += SIMD4(s.x * s.w, s.y * s.w, s.z * s.w, s.w) * w
        }
        guard sum.w > 0 else { return .zero }
        return SIMD4(sum.x / sum.w, sum.y / sum.w, sum.z / sum.w, sum.w)
    }
}

/// Remove patches by digest (edit recipe `derivedRef`: "a cached result of an on-device model,
/// stored beside the edit by digest"). Undo/redo move between recipes that name patches by
/// digest; a redo replays the same pixels.
///
/// With a directory, every patch is also written atomically to `<sha256>.patch` (the digest's
/// own input bytes: six little-endian Int64 — x, y, width, height, source width and height —
/// then the RGBA), so an edit restored after the app was killed still has its fills. A patch
/// not in memory is read back and kept only if its bytes hash to its name; a missing or corrupt
/// patch is skipped, and never recomputed silently (the model is not run again for it).
final class RemovePatchStore: @unchecked Sendable {
    // @unchecked: every access to `patches` holds `lock`; file writes are atomic renames.
    private let lock = NSLock()
    private var patches: [String: RemovePatch] = [:]
    private let directory: URL?

    init(directory: URL? = nil) { self.directory = directory }

    /// The app's store: Application Support/RemovePatches.
    static func applicationSupport() -> RemovePatchStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return RemovePatchStore(directory: base?.appendingPathComponent("RemovePatches", isDirectory: true))
    }

    func add(_ patch: RemovePatch) -> String {
        let digest = patch.sha256
        lock.withLock { patches[digest] = patch }
        if let directory {
            // A failed write keeps the patch for this launch only; after a kill the stroke is
            // rendered without its fill (skipped), never recomputed.
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Derived results, re-made from the edit: kept out of iCloud and device backup, like the
            // stored session (release register).
            var folder = directory, file = fileURL(digest, in: directory)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            try? Self.encode(patch).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try? file.setResourceValues(values)
        }
        return digest
    }

    func patch(_ digest: String) -> RemovePatch? {
        if let cached = lock.withLock({ patches[digest] }) { return cached }
        guard let directory, let data = try? Data(contentsOf: fileURL(digest, in: directory)),
              Self.digest(of: data) == digest, let patch = Self.decode(data) else { return nil }
        lock.withLock { patches[digest] = patch }
        return patch
    }

    /// The applied strokes' patches in order; a stroke whose patch is unknown, missing or corrupt
    /// is skipped (never recomputed silently).
    func patches(for strokes: [EditRecipe.RemoveStroke]) -> [RemovePatch] {
        strokes.compactMap { stroke in
            guard stroke.status == .applied, let ref = stroke.patch else { return nil }
            return patch(ref.sha256)
        }
    }

    /// Choosing a new photo: the previous edit's patches are deleted, in memory and on disk.
    func removeAll() {
        lock.withLock { patches.removeAll() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func fileURL(_ digest: String, in directory: URL) -> URL {
        // Digests are hex; anything else never names a file.
        let safe = digest.allSatisfy { "0123456789abcdef".contains($0) } ? digest : "invalid"
        return directory.appendingPathComponent("\(safe).patch")
    }

    static func encode(_ patch: RemovePatch) -> Data {
        var data = Data()
        for value in [patch.x, patch.y, patch.width, patch.height, patch.sourceWidth, patch.sourceHeight] {
            withUnsafeBytes(of: Int64(value).littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: patch.rgba)
        return data
    }

    static func decode(_ data: Data) -> RemovePatch? {
        guard data.count >= 48 else { return nil }
        let fields = (0..<6).map { i in Int(Int64(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 8, as: Int64.self) })) }
        let rgba = [UInt8](data.dropFirst(48))
        guard fields[2] > 0, fields[3] > 0, rgba.count == fields[2] * fields[3] * 4 else { return nil }
        return RemovePatch(x: fields[0], y: fields[1], width: fields[2], height: fields[3],
                           sourceWidth: fields[4], sourceHeight: fields[5], rgba: rgba)
    }

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// A 512 × 512 inpainting model: `image` CHW in 0…1, `mask` 1 = remove; returns CHW in 0…1.
protocol Inpainting: Sendable {
    var model: EditRecipe.ModelRef { get }
    func inpaint(image: [Float], mask: [Float], side: Int) async throws -> [Float]
}

/// LaMa big-lama (advimman/lama, Apache-2.0 code and weights), converted to Core ML fp16 with
/// exact DFT matrices in place of the FFTs (experiments/inpaint/convert.py), bundled by
/// ios/Tools/bundle_remove_model.sh.
///
/// RELEASE GATE — "pending legal sign-off (training data: Places2)": the weights are Apache-2.0,
/// but they were trained on Places2, whose image terms are non-commercial research only for the
/// downloader (remove-evaluation §8). Release builds bundle and load the model only when the build
/// setting `LIGHTLY_REMOVE_MODEL_TRAINING_DATA_SIGNED_OFF` is YES. Without it, Remove stays listed
/// and every stroke shows the approved failure state; no classical fill replaces it.
final class LamaInpainter: Inpainting, @unchecked Sendable {
    // @unchecked: `mlModel` is immutable after init; MLModel prediction is thread-safe.

    static let resourceName = "lama_512_fp16"
    static let modelRef = EditRecipe.ModelRef(id: "lama-big-lama-coreml-fp16-512", version: "787574a")
    private static let logger = Logger(subsystem: "com.lightlylabs.lightly", category: "Remove")

    let model = LamaInpainter.modelRef
    private let mlModel: MLModel

    init(model: MLModel) { mlModel = model }

    static var isReleaseGateOpen: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.object(forInfoDictionaryKey: "LightlyRemoveModelTrainingDataSignedOff") as? String == "YES"
        #endif
    }

    /// The bundled model, or nil (not bundled, gated off, or it fails to load).
    static func loadBundled(bundle: Bundle = .main) -> LamaInpainter? {
        guard isReleaseGateOpen, let url = bundle.url(forResource: resourceName, withExtension: "mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
        #else
        // remove-evaluation §7: never the Neural Engine (its compile fails and costs minutes).
        configuration.computeUnits = .cpuAndGPU
        #endif
        do {
            return LamaInpainter(model: try MLModel(contentsOf: url, configuration: configuration))
        } catch {
            logger.error("LaMa failed to load: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func inpaint(image: [Float], mask: [Float], side: Int) async throws -> [Float] {
        let imageArray = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        let maskArray = try MLMultiArray(shape: [1, 1, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        image.withUnsafeBufferPointer { source in
            imageArray.dataPointer.assumingMemoryBound(to: Float.self).update(from: source.baseAddress!, count: source.count)
        }
        mask.withUnsafeBufferPointer { source in
            maskArray.dataPointer.assumingMemoryBound(to: Float.self).update(from: source.baseAddress!, count: source.count)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: imageArray),
                                                                    "mask": MLFeatureValue(multiArray: maskArray)])
        let started = ContinuousClock.now
        let output: MLFeatureProvider
        do { output = try await mlModel.prediction(from: provider) } catch {
            throw RemoveEngine.Failure.modelFailed("\(error)")
        }
        let elapsed = ContinuousClock.now - started
        Self.logger.info("LaMa 512 tile: \(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000, privacy: .public) ms")
        #if DEBUG
        DebugCaptureTiming.mark("remove-tile-ms=\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)")
        #endif
        guard let result = output.featureValue(for: "result")?.multiArrayValue, result.count == 3 * side * side else {
            throw RemoveEngine.Failure.modelFailed("no result")
        }
        var values = [Float](repeating: 0, count: result.count)
        let contiguous = result.strides.map(\.intValue) == [3 * side * side, side * side, side, 1]
        switch result.dataType {
        case .float32 where contiguous:
            let pointer = result.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<values.count { values[i] = min(max(pointer[i], 0), 1) }
        default:
            for i in 0..<values.count { values[i] = min(max(result[i].floatValue, 0), 1) }
        }
        return values
    }
}
