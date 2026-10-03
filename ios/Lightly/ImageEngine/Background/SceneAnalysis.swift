import AVFoundation
import CoreGraphics
import CoreImage
import CoreML
import Foundation
import ImageIO
import Vision

/// What the on-device models found in a photo, at the analysis resolution. Model results are
/// identified by digest and model version, as edit recipe `derivedRef`s.
struct SubjectMatte: Sendable {
    /// Soft matte in [0,1], `width × height`, origin top-left.
    let matte: FloatImage
    let model: EditRecipe.ModelRef

    static let visionModel = EditRecipe.ModelRef(id: "vision-foreground-instance-mask", version: "ios-17")
}

struct DisparityMap: Sendable {
    /// Normalised disparity (§R2.1), [0,1], larger = nearer.
    let disparity: FloatImage
    let source: EditRecipe.Depth.Source
    let model: EditRecipe.ModelRef
}

/// One detected face, in normalised source coordinates (origin top-left).
struct DetectedFace: Sendable, Equatable {
    let box: EditRecipe.Rect
    /// Landmark regions as normalised polygons (origin top-left): face contour, eyes, brows, lips.
    let faceContour: [CGPoint]
    let leftEye: [CGPoint]
    let rightEye: [CGPoint]
    let leftEyebrow: [CGPoint]
    let rightEyebrow: [CGPoint]
    let outerLips: [CGPoint]
    let innerLips: [CGPoint]
    /// Vision's capture quality, 0…1, when available.
    let quality: Float?

    static let detector = EditRecipe.ModelRef(id: "vision-face-landmarks", version: "ios-17-rev3")

    /// The ellipse the face ring follows (prototype `.faceRing`, an upright ellipse on the face).
    /// Vision's face box spans roughly brows to chin and is square; the ring adds the forehead
    /// (a fifth of the box above it) and a little below the chin, so it is about 1.25 times as
    /// tall as wide. Landmarks are not used: in the Simulator their CPU path returned contours
    /// that moved between runs of the same photo.
    var ring: EditRecipe.Rect {
        EditRecipe.Rect(x: box.x, y: box.y - box.height * 0.2, width: box.width, height: box.height * 1.25)
    }

    /// Usable for Portrait: big enough, with landmarks, facing the camera well enough. The
    /// approved "No face can be edited" covers faces too small, turned away or too dark.
    var isUsable: Bool {
        box.width >= 0.05 && box.height >= 0.05 && !leftEye.isEmpty && !rightEye.isEmpty && !outerLips.isEmpty
            && (quality ?? 1) >= 0.2
    }
}

struct PeopleAnalysis: Sendable, Equatable {
    var faces: [DetectedFace]
    /// Person rectangles without a usable face (dim rings in the prototype), normalised.
    var people: [EditRecipe.Rect]

    var hasPerson: Bool { !faces.isEmpty || !people.isEmpty }
    var usableFaces: [DetectedFace] { faces.filter(\.isUsable) }
}

enum SceneAnalysisError: Error, Equatable {
    case cancelled
    case failed(String)
    /// The depth model cannot run (missing, gated off, or failed); never faked with a matte.
    case depthUnavailable(String)
}

extension SceneAnalysisError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .cancelled: "cancelled"
        case .failed(let reason): "failed: \(reason)"
        case .depthUnavailable(let reason): "depth unavailable: \(reason)"
        }
    }
}

protocol SceneAnalysing: Sendable {
    func subjectMatte(for image: CGImage) async throws -> SubjectMatte?
    func people(in image: CGImage) async -> PeopleAnalysis
    func disparity(for image: CGImage, originalData: Data) async throws -> DisparityMap
    /// Person segmentation (hair region for Portrait); nil when there is no person.
    func personMatte(for image: CGImage) async -> FloatImage?
}

/// Vision and Core ML on the device: nothing leaves the phone.
struct OnDeviceSceneAnalyser: SceneAnalysing {

    /// Loads the depth model on first use (compiling it for the Neural Engine takes seconds).
    let depthEstimators: DepthEstimatorProvider

    // MARK: Subject

    /// Vision foreground instance mask (all instances), soft, at the image's size. nil = no
    /// clear subject.
    func subjectMatte(for image: CGImage) async throws -> SubjectMatte? {
        do {
            return try await Self.visionSubjectMatte(for: image)
        } catch {
            #if DEBUG && targetEnvironment(simulator)
            // The Simulator cannot run this request ("Could not create inference context").
            // DEBUG simulator runs may stand in the matte the same request computed on macOS
            // (ios/Tools/make_subject_matte_fixtures.swift); devices never take this path.
            if let fixture = DebugSubjectMatteFixture.load(size: (image.width, image.height)) { return fixture.matte }
            #endif
            throw error
        }
    }

    private static func visionSubjectMatte(for image: CGImage) async throws -> SubjectMatte? {
        try await Task.detached(priority: .userInitiated) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try Task.checkCancellation()
            do {
                try handler.perform([request])
            } catch {
                #if targetEnvironment(simulator)
                // Try again on the CPU: some Vision requests need that in the Simulator.
                Self.preferCPUInSimulator(request)
                do { try handler.perform([request]) } catch { throw SceneAnalysisError.failed("\(error)") }
                #else
                throw SceneAnalysisError.failed("\(error)")
                #endif
            }
            try Task.checkCancellation()
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
            let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
            return SubjectMatte(matte: Self.floatImage(from: buffer), model: SubjectMatte.visionModel)
        }.value
    }

    // MARK: Person matte

    func personMatte(for image: CGImage) async -> FloatImage? {
        await Task.detached(priority: .utility) {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .balanced
            Self.preferCPUInSimulator(request)
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            guard (try? handler.perform([request])) != nil, let buffer = request.results?.first?.pixelBuffer else { return nil }
            return Self.floatImage(from: buffer).resized(width: image.width, height: image.height)
        }.value
    }

    // MARK: People and faces

    func people(in image: CGImage) async -> PeopleAnalysis {
        await Task.detached(priority: .userInitiated) {
            // A failed perform leaves partial results (a face without landmarks reads as "no usable
            // face"), so one failure is retried with fresh requests before the result is used.
            func run() -> (VNDetectFaceLandmarksRequest, VNDetectFaceCaptureQualityRequest, VNDetectHumanRectanglesRequest, Bool) {
                let faces = VNDetectFaceLandmarksRequest()
                let quality = VNDetectFaceCaptureQualityRequest()
                let humans = VNDetectHumanRectanglesRequest()
                humans.upperBodyOnly = false
                for request in [faces, quality, humans] as [VNRequest] { Self.preferCPUInSimulator(request) }
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                let succeeded = (try? handler.perform([faces, humans, quality])) != nil
                return (faces, quality, humans, succeeded)
            }
            var (faces, quality, humans, succeeded) = run()
            if !succeeded { (faces, quality, humans, succeeded) = run() }
            let qualities = quality.results ?? []
            let detected: [DetectedFace] = (faces.results ?? []).filter { $0.confidence >= 0.5 }.map { face in
                let match = qualities.first { $0.boundingBox.intersects(face.boundingBox) }
                #if targetEnvironment(simulator)
                // The capture-quality request runs on the CPU here and is not reliable: the same
                // clear face scored 0.52, 1.00 and 0.00 across one capture session (macOS: 0.71).
                // Quality is left unknown in the Simulator; devices use it.
                _ = match
                return Self.detectedFace(face, quality: nil)
                #else
                return Self.detectedFace(face, quality: match?.faceCaptureQuality)
                #endif
            }
            // Order left to right, so "Face 1, 2, 3" read as the photo does.
            let ordered = detected.sorted { $0.box.x < $1.box.x }
            let people = (humans.results ?? []).filter { $0.confidence >= 0.5 }.map { Self.topLeftRect($0.boundingBox) }
                .filter { person in !ordered.contains { Self.overlaps(person, $0.box) } }
            return PeopleAnalysis(faces: ordered, people: people)
        }.value
    }

    private static func detectedFace(_ face: VNFaceObservation, quality: Float?) -> DetectedFace {
        let box = topLeftRect(face.boundingBox)
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region else { return [] }
            // Landmark points are normalised to the face box, origin bottom-left.
            return region.normalizedPoints.map { p in
                CGPoint(x: Double(box.x) + Double(p.x) * Double(box.width),
                        y: Double(box.y) + (1 - Double(p.y)) * Double(box.height))
            }
        }
        let l = face.landmarks
        return DetectedFace(box: box, faceContour: points(l?.faceContour), leftEye: points(l?.leftEye), rightEye: points(l?.rightEye),
                            leftEyebrow: points(l?.leftEyebrow), rightEyebrow: points(l?.rightEyebrow),
                            outerLips: points(l?.outerLips), innerLips: points(l?.innerLips), quality: quality)
    }

    static func topLeftRect(_ r: CGRect) -> EditRecipe.Rect {
        let x = min(max(r.minX, 0), 1), y = min(max(1 - r.maxY, 0), 1)
        return EditRecipe.Rect(x: x, y: y, width: min(r.width, 1 - x), height: min(r.height, 1 - y))
    }

    private static func overlaps(_ a: EditRecipe.Rect, _ b: EditRecipe.Rect) -> Bool {
        CGRect(x: a.x, y: a.y, width: a.width, height: a.height).intersects(CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
    }

    // MARK: Depth

    /// Embedded disparity when the file carries it, else the depth model (when available).
    func disparity(for image: CGImage, originalData: Data) async throws -> DisparityMap {
        if let embedded = Self.embeddedDisparity(from: originalData, size: (image.width, image.height)) {
            return DisparityMap(disparity: embedded, source: .embedded,
                                model: EditRecipe.ModelRef(id: "embedded-disparity", version: "avdepthdata"))
        }
        guard let depthEstimator = depthEstimators.estimator() else {
            throw SceneAnalysisError.depthUnavailable("no depth model in this build")
        }
        return try await depthEstimator.estimate(image)
    }

    /// The photo's own disparity/depth auxiliary image (iOS Portrait photos and newer iPhones),
    /// oriented like the primary image, normalised (§R2.1) and resized to `size`.
    static func embeddedDisparity(from data: Data, size: (Int, Int)) -> FloatImage? {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDisparity)
            ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeDepth)
        guard let info = info as? [AnyHashable: Any], var depth = try? AVDepthData(fromDictionaryRepresentation: info) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if let raw = properties?[kCGImagePropertyOrientation] as? UInt32, let orientation = CGImagePropertyOrientation(rawValue: raw) {
            depth = depth.applyingExifOrientation(orientation)
        }
        depth = depth.converting(toDepthDataType: kCVPixelFormatType_DisparityFloat32)
        let map = floatImage(from: depth.depthDataMap)
        return DepthEstimator.normalised(map).resized(width: size.0, height: size.1)
    }

    // MARK: Helpers

    static func floatImage(from buffer: CVPixelBuffer) -> FloatImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var out = FloatImage(width: w, height: h, channels: 1)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return out }
        for y in 0..<h {
            let row = base + y * rowBytes
            for x in 0..<w {
                switch format {
                case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DisparityFloat16, kCVPixelFormatType_DepthFloat16:
                    out.data[y * w + x] = Float(row.assumingMemoryBound(to: Float16.self)[x])
                case kCVPixelFormatType_OneComponent8:
                    out.data[y * w + x] = Float(row.assumingMemoryBound(to: UInt8.self)[x]) / 255
                default:
                    out.data[y * w + x] = row.assumingMemoryBound(to: Float.self)[x]
                }
            }
        }
        return out
    }

    /// The simulator has no Neural Engine and Vision's default devices fail there.
    static func preferCPUInSimulator(_ request: VNRequest) {
        #if targetEnvironment(simulator)
        guard let stages = try? request.supportedComputeStageDevices else { return }
        for (stage, devices) in stages {
            if let cpu = devices.first(where: { if case .cpu = $0 { return true } else { return false } }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        #endif
    }
}

/// Depth Anything V2 Small (Apple's Core ML package `DepthAnythingV2SmallF16P8`, Apache-2.0),
/// bundled by `ios/Tools/bundle_depth_model.sh`.
///
/// RELEASE GATE — pending legal sign-off (training data): the weights are Apache-2.0, but the
/// model was trained on pseudo-labels of datasets with research-only terms
/// (docs/v1/depth-evaluation.md T1). Release builds bundle and use it only when the build setting
/// `LIGHTLY_DEPTH_MODEL_TRAINING_DATA_SIGNED_OFF` is YES; until then a release build has no
/// estimated depth and Focus & Blur on a photo without embedded depth shows the approved
/// "Couldn't separate the subject" state.
final class DepthEstimator: @unchecked Sendable {
    // @unchecked: `model` is immutable after init; MLModel prediction is thread-safe.

    static let modelName = "DepthAnythingV2SmallF16P8"
    static let modelRef = EditRecipe.ModelRef(id: "depth-anything-v2-small-coreml-f16p8", version: "cfef6f6")
    /// [contract] model input: 518 × 392 (w × h), stretched, no crop, no rotation.
    static let inputWidth = 518, inputHeight = 392

    private let model: MLModel

    /// The bundled, compiled model, or nil (not bundled, or gated off in this build).
    static func loadBundled(bundle: Bundle = .main) -> DepthEstimator? {
        guard isReleaseGateOpen, let url = bundle.url(forResource: modelName, withExtension: "mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = .all
        #endif
        guard let model = try? MLModel(contentsOf: url, configuration: configuration) else { return nil }
        return DepthEstimator(model: model)
    }

    /// DEBUG builds always may use the model for development; release builds only after sign-off.
    static var isReleaseGateOpen: Bool {
        #if DEBUG
        return true
        #else
        return Bundle.main.object(forInfoDictionaryKey: "LightlyDepthModelTrainingDataSignedOff") as? String == "YES"
        #endif
    }

    init(model: MLModel) { self.model = model }

    func estimate(_ image: CGImage) async throws -> DisparityMap {
        try await Task.detached(priority: .userInitiated) { [model] in
            try Task.checkCancellation()
            guard let input = Self.pixelBuffer(image, width: Self.inputWidth, height: Self.inputHeight) else {
                throw SceneAnalysisError.depthUnavailable("cannot prepare model input")
            }
            let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "image"
            let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: input)])
            let output: MLFeatureProvider
            do { output = try await model.prediction(from: provider) } catch {
                throw SceneAnalysisError.depthUnavailable("\(error)")
            }
            try Task.checkCancellation()
            guard let name = model.modelDescription.outputDescriptionsByName.keys.first,
                  let value = output.featureValue(for: name) else { throw SceneAnalysisError.depthUnavailable("no output") }
            var raw: FloatImage
            if let buffer = value.imageBufferValue {
                raw = OnDeviceSceneAnalyser.floatImage(from: buffer)
            } else if let array = value.multiArrayValue {
                let h = array.shape[array.shape.count - 2].intValue, w = array.shape[array.shape.count - 1].intValue
                raw = FloatImage(width: w, height: h, channels: 1)
                for i in 0..<(w * h) { raw.data[i] = array[i].floatValue }
            } else {
                throw SceneAnalysisError.depthUnavailable("unexpected output")
            }
            let normalisedMap = Self.normalised(raw).resized(width: image.width, height: image.height)
            return DisparityMap(disparity: normalisedMap, source: .estimated, model: Self.modelRef)
        }.value
    }

    /// [contract] `D = clamp((raw − p1)/(p99 − p1), 0, 1)`.
    static func normalised(_ map: FloatImage) -> FloatImage {
        let finite = map.data.filter(\.isFinite).sorted()
        guard !finite.isEmpty else { return map }
        let p1 = finite[Int(Float(finite.count - 1) * 0.01)], p99 = finite[Int(Float(finite.count - 1) * 0.99)]
        var out = map
        for i in 0..<out.pixelCount {
            let v = out.data[i].isFinite ? out.data[i] : p1
            out.data[i] = min(max((v - p1) / max(p99 - p1, 1e-6), 0), 1)
        }
        return out
    }

    /// The photo stretched to the model's input, 32BGRA.
    static func pixelBuffer(_ image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: ColorPipeline.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

/// Loads the bundled depth model once, on first use, off the main actor.
final class DepthEstimatorProvider: @unchecked Sendable {
    // @unchecked: guarded by `lock`.
    private let lock = NSLock()
    private var loaded = false
    private var cached: DepthEstimator?
    private let load: @Sendable () -> DepthEstimator?

    init(load: @escaping @Sendable () -> DepthEstimator? = { DepthEstimator.loadBundled() }) { self.load = load }

    func estimator() -> DepthEstimator? {
        lock.withLock {
            if !loaded { cached = load(); loaded = true }
            return cached
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// `--subject-matte-fixture <file>` (DEBUG, Simulator only): a matte computed by
/// `VNGenerateForegroundInstanceMaskRequest` on macOS for the photo being opened (`.png`, 8-bit
/// grey), or `<name>.none` when that request found no subject. Used only when the request
/// itself fails in the Simulator.
enum DebugSubjectMatteFixture {
    struct Loaded { let matte: SubjectMatte? }

    static let modelRef = EditRecipe.ModelRef(id: "vision-foreground-instance-mask", version: "macos-fixture")

    static func load(size: (Int, Int)) -> Loaded? {
        let arguments = DebugArguments.current
        guard let flag = arguments.firstIndex(of: "--subject-matte-fixture"), arguments.indices.contains(flag + 1) else { return nil }
        let url = URL(fileURLWithPath: arguments[flag + 1])
        if url.pathExtension == "none" { return Loaded(matte: nil) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpace(name: CGColorSpace.linearGray)!, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let matte = FloatImage(width: width, height: height, channels: 1, data: bytes.map { Float($0) / 255 })
        return Loaded(matte: SubjectMatte(matte: matte.resized(width: size.0, height: size.1), model: modelRef))
    }
}
#endif
