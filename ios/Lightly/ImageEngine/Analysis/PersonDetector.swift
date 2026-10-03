import CoreGraphics
import CoreML
import Foundation
import Vision

/// Decides whether the editor offers Portrait: only when the photo has a person (approved
/// `toolsFor`: a face, or people without a usable face).
///
/// Uses Apple's built-in Vision (no download): face rectangles, then human (upper body) rectangles.
/// The Portrait tool itself — landmarks, face choice, adjustments — is slice 3; this decides only
/// its visibility.
protocol PersonDetecting: Sendable {
    func containsPerson(_ image: CGImage) async -> Bool
}

struct VisionPersonDetector: PersonDetecting {

    /// Below this confidence an observation is ignored (Vision's own scores, 0…1).
    static let minimumConfidence: Float = 0.5

    func containsPerson(_ image: CGImage) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let faces = VNDetectFaceRectanglesRequest()
            let humans = VNDetectHumanRectanglesRequest()
            humans.upperBodyOnly = false
            #if targetEnvironment(simulator)
            // The simulator has no Neural Engine and Vision's default devices fail there; run on the
            // CPU so simulator runs (tests, design captures) decide exactly as a device would.
            for request in [faces, humans] as [VNRequest] { Self.useCPU(for: request) }
            #endif
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([faces, humans])
            } catch {
                // A failed detection hides Portrait rather than offering a tool that would then find
                // nobody; the person can still edit everything else.
                return false
            }
            let faceFound = (faces.results ?? []).contains { $0.confidence >= Self.minimumConfidence }
            let humanFound = (humans.results ?? []).contains { $0.confidence >= Self.minimumConfidence }
            return faceFound || humanFound
        }.value
    }

    private static func useCPU(for request: VNRequest) {
        guard let stages = try? request.supportedComputeStageDevices else { return }
        for (stage, devices) in stages {
            if let cpu = devices.first(where: { if case .cpu = $0 { return true } else { return false } }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
    }
}

/// A fixed answer, for tests and previews.
struct FixedPersonDetector: PersonDetecting {
    let result: Bool
    func containsPerson(_ image: CGImage) async -> Bool { result }
}
