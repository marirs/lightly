import CoreML
import Foundation
import os
import simd

/// A 256 × 256 class probability from one square crop of the photo (rendering-v2 §7.5 segmentation).
struct ProbabilityMap: Sendable, Equatable {
    static let side = 256
    /// side × side probabilities, row-major, origin top-left.
    var values: [Float]
    /// The crop's top-left corner and side in analysis pixels (it may extend past the photo).
    var originX: Float, originY: Float, cropSide: Float

    /// Bilinear sample at an analysis pixel position; nil outside the crop.
    func sample(x: Float, y: Float) -> Float? {
        let u = (x - originX) / cropSide * Float(Self.side) - 0.5, v = (y - originY) / cropSide * Float(Self.side) - 0.5
        guard u >= -0.5, v >= -0.5, u <= Float(Self.side) - 0.5, v <= Float(Self.side) - 0.5 else { return nil }
        let x0 = min(max(Int(floor(u)), 0), Self.side - 1), y0 = min(max(Int(floor(v)), 0), Self.side - 1)
        let x1 = min(x0 + 1, Self.side - 1), y1 = min(y0 + 1, Self.side - 1)
        let fx = min(max(u - Float(x0), 0), 1), fy = min(max(v - Float(y0), 0), 1)
        let a = values[y0 * Self.side + x0], b = values[y0 * Self.side + x1]
        let c = values[y1 * Self.side + x0], d = values[y1 * Self.side + x1]
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }
}

/// Everything Portrait › Sunglasses needs about one face (rendering-v2 §7.5 "Analysis"), in the pixel space of the image it
/// was computed on (`analysisWidth` × `analysisHeight`). Cached with the photo; never part of the recipe.
struct FaceSunglassesAnalysis: Sendable, Equatable {
    /// The face it belongs to (the recipe's face identity box, normalised).
    let faceBox: EditRecipe.Rect
    let analysisWidth: Int, analysisHeight: Int
    /// 478 MediaPipe landmarks: x, y in analysis pixels (origin top-left), z in the same pixel units (negative = nearer).
    let landmarks: [SIMD3<Float>]
    /// The landmarker's face-presence logit for the kept crop.
    let faceLogit: Float
    let hair: ProbabilityMap
    let background: ProbabilityMap
    let accessory: ProbabilityMap

    /// §7.5: a face whose final logit is below 0 is not readable (the panel's "eyes not visible" state).
    var isReadable: Bool { faceLogit >= SunglassesConstants.minFaceLogit }

    /// Iris span d = |P263 − P33| in analysis pixels.
    var irisSpan: Float { simd_distance(SIMD2(landmarks[263].x, landmarks[263].y), SIMD2(landmarks[33].x, landmarks[33].y)) }

    /// The §7.5 eye band (analysis pixels): accessories inside it count as the face's own glasses.
    var eyeBand: (x0: Float, y0: Float, x1: Float, y1: Float) {
        let d = irisSpan
        let mesh = landmarks.prefix(468)
        let xs = mesh.map(\.x)
        let eyeTop = [33, 263, 468, 473].map { landmarks[$0].y }.min()!
        let pad = SunglassesConstants.eyeBandPadX
        return (xs.min()! - pad * d, eyeTop - 0.55 * d, xs.max()! + pad * d, landmarks[1].y + SunglassesConstants.eyeBandBelowNoseTip * d)
    }

    /// The face's own glasses: accessory probability above the threshold inside the eye band, as a mask over the band's
    /// bounding box (analysis pixels). nil when it covers no more than 0.5 % of the face box (no glasses).
    func glassesMask() -> (x0: Int, y0: Int, width: Int, height: Int, mask: [Bool])? {
        let band = eyeBand
        let x0 = max(0, Int(band.x0)), y0 = max(0, Int(band.y0))
        let x1 = min(analysisWidth, Int(band.x1.rounded(.up))), y1 = min(analysisHeight, Int(band.y1.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        var mask = [Bool](repeating: false, count: (x1 - x0) * (y1 - y0))
        var count = 0
        for y in y0..<y1 { for x in x0..<x1 {
            if (accessory.sample(x: Float(x) + 0.5, y: Float(y) + 0.5) ?? 0) > SunglassesConstants.accessoryThreshold {
                mask[(y - y0) * (x1 - x0) + (x - x0)] = true; count += 1
            }
        } }
        let boxArea = faceBox.width * Double(analysisWidth) * faceBox.height * Double(analysisHeight)
        guard Double(count) > SunglassesConstants.glassesMinBoxFraction * boxArea else { return nil }
        return (x0, y0, x1 - x0, y1 - y0, mask)
    }
}

/// rendering-v2.json `portrait.sunglasses` constants (revision 9).
enum SunglassesConstants {
    static let initialCropScale: Float = 1.6
    static let rollTriesDegrees: [Float] = [0, -45, -30, -15, 15, 30, 45]
    /// The same tries are also made around upright (0°) unless within this of one already made: the platform's eye
    /// points can be wrong on a tilted face (a group selfie, 2026-10-14: both "eyes" a few px apart), and the
    /// landmarker then only saw rotations around a wrong angle and returned a mirrored face.
    static let rollTryMinSeparationDegrees: Float = 7.5
    /// The pair's front is never wider than this × the face's width at the cheek points 234/454 (owner report
    /// 2026-10-14: on a narrow face the pair stuck out past the head). The approved trial faces are within 1.5 %.
    static let widthFitCheekFactor: Float = 1.07
    /// A pair's front: its vertices within this of the lens plane (the arms reach far behind it).
    static let frontPlaneMetres: Float = 0.02
    /// The bridge is lowered onto the nose by at most this × half the lens height (SunglassesRenderer.seatedOrigin).
    static let seatMaxDropOfLensHalfHeight: Float = 0.6
    static let noseOcclusionMinYawDegrees: Float = 25
    static let seatFadeStartYawDegrees: Float = 25, seatFadeEndYawDegrees: Float = 50
    /// The frame passes are rendered at this multiple of the photo's resolution and box-averaged down, on top of 4×
    /// multisampling: fine rim detail otherwise sparkles in sub-pixel highlights.
    static let passSupersample = 2
    static let passSupersampleMaxSide = 4096
    /// Ear occluders (owner report 2026-10-14: on a turned face the arm lay over the ear). The arms are straight and run
    /// ~15 cm back; past the front of the ear a real arm goes behind the ear. Depth-only boxes in the head's frame hide
    /// the arms from this far behind the lens plane on: |x| in [earBoxInnerX, earBoxOuterX], all y, z to the back.
    static let earClipStartMetres: Float = 0.12
    static let earBoxInnerX: Float = 0.04
    static let earBoxOuterX: Float = 0.20
    static let refineCropScale: Float = 1.5
    static let refinePasses = 2
    static let keepIfLogitDropAtMost: Float = 1.0
    static let minFaceLogit: Float = 0
    static let hairOutlineCropScale: Float = 3.6
    static let accessoryCropScale: Float = 1.4
    static let accessoryCropRaise: Float = 0.1
    static let accessoryThreshold: Float = 0.35
    static let glassesMinBoxFraction = 0.005
    static let interIrisReferenceMetres: Float = 0.093
    static let sizePerUnit: Float = 0.004
    static let profileMarginMetres: Float = 0.007
    /// The turn is raised towards `profileTargetYawDegrees` in proportion as the far iris comes within this of the
    /// person's outline (owner report 2026-10-14: a 75° face was drawn at 51°, its far iris 12 mm from the outline, past
    /// the 7 mm that marked a profile). Only within `profileMarginMetres` is the face a profile (the outline clip).
    static let yawRampMetres: Float = 0.025
    /// The eye band reaches this × d beyond the landmarks on each side (was 0.15; owner report 2026-10-14: on a turned
    /// face the far rim of the person's own glasses sticks out past the nose and was left behind).
    static let eyeBandPadX: Float = 0.45
    /// The eye band reaches this × d below the nose tip (was 0.1; matrix review 2026-10-15: on a tilted face the
    /// upright band missed the far rim's lower corner, left as a dark tick).
    static let eyeBandBelowNoseTip: Float = 0.35
    /// On a turned face (|ex.z| above `farArmMinTurn`) the arm on the far side is hidden from this far behind the lens
    /// plane: the head hides it in life, but the arms are splayed just outside the head ellipsoid (owner report
    /// 2026-10-14: the far arm showed through the far lens).
    static let farArmClipStartMetres: Float = 0.02
    static let farArmMinTurn: Float = 0.1
    static let profileTargetYawDegrees: Float = 85
    static let eyeDepthMetres: Float = 0.015
    static let pantoscopicTiltRadians: Float = -0.14
    static let headCentreMetres = SIMD3<Float>(0, -0.026, -0.098)
    static let headRadiiMetres = SIMD3<Float>(0.076, 0.115, 0.098)
    static let faceMeshPushBackMetres: Float = 0.006
    /// Only the nose of the face mesh occludes (SunglassesRenderer.noseTriangles), in the head frame from the irises.
    static let noseHalfWidthMetres: Float = 0.02
    static let noseTopMetres: Float = 0.0
    static let noseBottomMetres: Float = -0.06
    /// The head's continuation behind its centre (see SunglassesRenderer.renderPasses).
    static let headBackLengthMetres: Float = 0.2
    static let frontDepthMetres: Float = 0.012
    static let shadowSigmaOfIrisSpan: Float = 0.035
    static let shadowOffsetOfIrisSpan = SIMD2<Float>(0.01, 0.05)
    static let shadowStrength: Float = 0.28
    static let profileOverhangMetres: Float = 0.004
}

/// Runs the two Sunglasses models (rendering-v2 §7.5 "Analysis") on an RGBA8 sRGB image.
final class SunglassesAnalyzer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.lightlylabs.lightly", category: "sunglasses")
    private let landmarker: MLModel
    private let segmenter: MLModel

    init(landmarker: MLModel, segmenter: MLModel) {
        self.landmarker = landmarker
        self.segmenter = segmenter
    }

    /// The bundled models, or nil when either is missing (the tab then shows "eyes not visible" for every face).
    static func loadBundled(bundle: Bundle = .main) -> SunglassesAnalyzer? {
        guard let lm = bundle.url(forResource: "face_landmarks_256_fp16", withExtension: "mlmodelc"),
              let seg = bundle.url(forResource: "selfie_multiclass_256_fp16", withExtension: "mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = .all
        #endif
        do {
            return SunglassesAnalyzer(landmarker: try MLModel(contentsOf: lm, configuration: configuration),
                                      segmenter: try MLModel(contentsOf: seg, configuration: configuration))
        } catch {
            logger.error("Sunglasses models failed to load: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The source pixels the crops sample from.
    struct Image {
        let rgba: [UInt8]
        let width: Int, height: Int

        /// Bilinear sRGB sample (0…1) at a pixel position; outside the image is black (as PIL's transform fills).
        func sample(_ x: Float, _ y: Float) -> SIMD3<Float> {
            let u = x - 0.5, v = y - 0.5
            let x0 = Int(floor(u)), y0 = Int(floor(v))
            let fx = u - Float(x0), fy = v - Float(y0)
            func at(_ px: Int, _ py: Int) -> SIMD3<Float> {
                guard px >= 0, py >= 0, px < width, py < height else { return .zero }
                let i = (py * width + px) * 4
                return SIMD3(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2])) / 255
            }
            let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
            let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
            return top * (1 - fy) + bottom * fy
        }
    }

    /// Analysis for one face. `box` is the platform face box and `eyes` its two eye centres (analysis pixels, left
    /// first), the starting crop.
    func analyse(_ image: Image, faceBox: EditRecipe.Rect, eyes: (SIMD2<Float>, SIMD2<Float>)) throws -> FaceSunglassesAnalysis {
        let W = Float(image.width), H = Float(image.height)
        let bx = Float(faceBox.x) * W, by = Float(faceBox.y) * H, bw = Float(faceBox.width) * W, bh = Float(faceBox.height) * H
        let centre = SIMD2(bx + bw / 2, by + bh / 2)
        let roll = atan2(eyes.1.y - eyes.0.y, eyes.1.x - eyes.0.x)
        // Pass 1: Apple's crop at its roll and ±15/30/45 degrees; the highest face-presence logit wins.
        var best: (points: [SIMD3<Float>], logit: Float)?
        for candidate in Self.rollCandidates(platformRoll: roll) {
            let attempt = try landmarks(image, centre: centre, side: max(bw, bh) * SunglassesConstants.initialCropScale, roll: candidate)
            if best == nil || attempt.logit > best!.logit { best = attempt }
        }
        var (points, logit) = best!
        // Passes 2–3: re-crop on the landmarks, upright along forehead (10) → chin (152).
        for _ in 0..<SunglassesConstants.refinePasses {
            let v = SIMD2(points[152].x - points[10].x, points[152].y - points[10].y)
            let uprightRoll = atan2(-v.x, v.y)
            let mesh = points.prefix(468)
            let lo = SIMD2(mesh.map(\.x).min()!, mesh.map(\.y).min()!), hi = SIMD2(mesh.map(\.x).max()!, mesh.map(\.y).max()!)
            let next = try landmarks(image, centre: (lo + hi) / 2, side: max(hi.x - lo.x, hi.y - lo.y) * SunglassesConstants.refineCropScale,
                                     roll: uprightRoll)
            if next.logit < logit - SunglassesConstants.keepIfLogitDropAtMost { break }
            (points, logit) = next
        }
        // Segmentation: a wide crop for hair and the outline, a tight one (raised) for accessories.
        let wide = try segment(image, centre: centre, side: max(bw, bh) * SunglassesConstants.hairOutlineCropScale)
        let tight = try segment(image, centre: SIMD2(centre.x, centre.y - bh * SunglassesConstants.accessoryCropRaise),
                                side: max(bw, bh) * SunglassesConstants.accessoryCropScale)
        return FaceSunglassesAnalysis(faceBox: faceBox, analysisWidth: image.width, analysisHeight: image.height,
                                      landmarks: points, faceLogit: logit,
                                      hair: wide.map(class: 1), background: wide.map(class: 0), accessory: tight.map(class: 5))
    }

    /// The first crop's rolls (radians): the tries around the platform's eye line, then the same tries around upright
    /// that are not within `rollTryMinSeparationDegrees` of one already listed.
    static func rollCandidates(platformRoll: Float) -> [Float] {
        let tries = SunglassesConstants.rollTriesDegrees.map { $0 * .pi / 180 }
        var rolls = tries.map { platformRoll + $0 }
        let separation = SunglassesConstants.rollTryMinSeparationDegrees * .pi / 180
        for roll in tries where !rolls.contains(where: { abs(remainder($0 - roll, 2 * .pi)) < separation }) {
            rolls.append(roll)
        }
        return rolls
    }

    // MARK: - Landmarker

    /// One landmarker run on a square crop of `side` pixels around `centre`, rotated by `roll` (radians, image y down).
    private func landmarks(_ image: Image, centre: SIMD2<Float>, side: Float, roll: Float) throws -> (points: [SIMD3<Float>], logit: Float) {
        let n = ProbabilityMap.side, k = side / Float(n)
        let ca = cos(roll), sa = sin(roll)
        // Output (u, v) of the 256 crop -> photo (x, y): x = a u + b v + c, as the reference's PIL affine transform.
        let a = k * ca, b = -k * sa, c = centre.x - k * (ca * 128 - sa * 128)
        let d = k * sa, e = k * ca, f = centre.y - k * (sa * 128 + ca * 128)
        let input = try MLMultiArray(shape: [1, NSNumber(value: n), NSNumber(value: n), 3], dataType: .float32)
        let p = input.dataPointer.assumingMemoryBound(to: Float.self)
        for v in 0..<n { for u in 0..<n {
            // PIL samples output pixel (u, v) at its centre (u + 0.5, v + 0.5).
            let uu = Float(u) + 0.5, vv = Float(v) + 0.5
            let rgb = image.sample(a * uu + b * vv + c, d * uu + e * vv + f)
            let i = (v * n + u) * 3
            p[i] = rgb.x; p[i + 1] = rgb.y; p[i + 2] = rgb.z
        } }
        let output = try landmarker.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)]))
        guard let raw = output.featureValue(for: "landmarks")?.multiArrayValue, raw.count == 1434,
              let flag = output.featureValue(for: "face_flag")?.multiArrayValue else { throw SunglassesError.modelFailed("landmarker output") }
        let values = Self.floats(raw)
        var points = [SIMD3<Float>](repeating: .zero, count: 478)
        for i in 0..<478 {
            let u = values[i * 3], v = values[i * 3 + 1], z = values[i * 3 + 2]
            points[i] = SIMD3(a * u + b * v + c, d * u + e * v + f, z * k)
        }
        return (points, flag[0].floatValue)
    }

    /// A Core ML output's values in logical (row-major) order, read through its data pointer when it is contiguous.
    static func floats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        var expected = 1
        let contiguous = zip(array.shape.reversed(), array.strides.reversed()).allSatisfy { dim, stride in
            defer { expected *= dim.intValue }
            return stride.intValue == expected
        }
        guard contiguous else { return (0..<count).map { array[$0].floatValue } }
        switch array.dataType {
        case .float32:
            return Array(UnsafeBufferPointer(start: array.dataPointer.assumingMemoryBound(to: Float.self), count: count))
        case .float16:
            return UnsafeBufferPointer(start: array.dataPointer.assumingMemoryBound(to: Float16.self), count: count).map(Float.init)
        default:
            return (0..<count).map { array[$0].floatValue }
        }
    }

    // MARK: - Segmenter

    struct Classes {
        let probabilities: [Float]   // 256 × 256 × 6
        let originX: Float, originY: Float, side: Float
        func map(class index: Int) -> ProbabilityMap {
            var values = [Float](repeating: 0, count: ProbabilityMap.side * ProbabilityMap.side)
            for i in 0..<values.count { values[i] = probabilities[i * 6 + index] }
            return ProbabilityMap(values: values, originX: originX, originY: originY, cropSide: side)
        }
    }

    /// Selfie multiclass on an axis-aligned square crop resized to 256 with area averaging (the reference's PIL bilinear
    /// resize filters over the source footprint when it shrinks).
    private func segment(_ image: Image, centre: SIMD2<Float>, side: Float) throws -> Classes {
        let n = ProbabilityMap.side
        // The reference crops at integer pixels.
        let x0 = Float(Int(centre.x - side / 2)), y0 = Float(Int(centre.y - side / 2))
        let cropSide = Float(Int(centre.x + side / 2)) - x0
        let step = cropSide / Float(n)
        let taps = max(1, Int(ceil(step)))
        let input = try MLMultiArray(shape: [1, NSNumber(value: n), NSNumber(value: n), 3], dataType: .float32)
        let p = input.dataPointer.assumingMemoryBound(to: Float.self)
        for v in 0..<n { for u in 0..<n {
            var sum = SIMD3<Float>.zero
            for ty in 0..<taps { for tx in 0..<taps {
                sum += image.sample(x0 + (Float(u) + (Float(tx) + 0.5) / Float(taps)) * step,
                                    y0 + (Float(v) + (Float(ty) + 0.5) / Float(taps)) * step)
            } }
            let rgb = sum / Float(taps * taps)
            let i = (v * n + u) * 3
            p[i] = rgb.x; p[i + 1] = rgb.y; p[i + 2] = rgb.z
        } }
        let output = try segmenter.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)]))
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue, logits.count == n * n * 6 else {
            throw SunglassesError.modelFailed("segmenter output")
        }
        let values = Self.floats(logits)
        var probabilities = [Float](repeating: 0, count: n * n * 6)
        for i in 0..<(n * n) {
            var row = (0..<6).map { values[i * 6 + $0] }
            let m = row.max()!
            row = row.map { exp($0 - m) }
            let s = row.reduce(0, +)
            for c in 0..<6 { probabilities[i * 6 + c] = row[c] / s }
        }
        return Classes(probabilities: probabilities, originX: x0, originY: y0, side: cropSide)
    }
}

enum SunglassesError: Error, Equatable {
    case modelFailed(String)
    case packUnavailable
}
