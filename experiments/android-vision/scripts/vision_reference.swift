// Apple Vision reference run on macOS for the iOS parity note and as a pseudo ground truth.
// Runs the same requests the iOS app uses on the exact 2048-px inputs fed to the Android harness:
//   VNDetectFaceLandmarksRequest, VNGeneratePersonSegmentationRequest (.accurate),
//   VNGenerateForegroundInstanceMaskRequest, VNGeneratePersonInstanceMaskRequest.
// Output: <out>/vision.json + <out>/masks/<photo>__{person,foreground,person_instance_N}.png
//
//   swiftc -O vision_reference.swift -o /tmp/vision_reference && /tmp/vision_reference work/photos work/vision_ref
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let photosURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outURL = URL(fileURLWithPath: CommandLine.arguments[2])
let masksURL = outURL.appendingPathComponent("masks")
try FileManager.default.createDirectory(at: masksURL, withIntermediateDirectories: true)
let ciContext = CIContext(options: [.workingColorSpace: NSNull()])
let savedMaskMaxEdge: CGFloat = 1024

func round4(_ value: CGFloat) -> Double { (Double(value) * 10000).rounded() / 10000 }

/// Writes a single-channel mask as an 8-bit greyscale PNG, downscaled like the Android harness.
func saveMask(_ buffer: CVPixelBuffer, to url: URL) {
    var image = CIImage(cvPixelBuffer: buffer)
    let scale = min(1, savedMaskMaxEdge / max(image.extent.width, image.extent.height))
    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    guard let cgImage = ciContext.createCGImage(image, from: image.extent, format: .L8,
                                                colorSpace: CGColorSpaceCreateDeviceGray()),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, cgImage, nil)
    CGImageDestinationFinalize(destination)
}

func normalisedPoints(_ region: VNFaceLandmarkRegion2D?, _ box: CGRect) -> [[Double]] {
    guard let region else { return [] }
    // Region points are normalised to the face box with origin bottom-left.
    return region.normalizedPoints.map { point in
        [round4(box.minX + point.x * box.width), round4(1 - (box.minY + point.y * box.height))]
    }
}

func milliseconds(_ block: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try block()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}

var results: [String: Any] = [:]
let photoNames = try FileManager.default.contentsOfDirectory(atPath: photosURL.path).filter { $0.hasSuffix(".jpg") }.sorted()
for name in photoNames {
    let stem = (name as NSString).deletingPathExtension
    guard let source = CGImageSourceCreateWithURL(photosURL.appendingPathComponent(name) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    var entry: [String: Any] = ["width": image.width, "height": image.height]

    let landmarksRequest = VNDetectFaceLandmarksRequest()
    entry["faces_ms"] = try milliseconds { try handler.perform([landmarksRequest]) }
    entry["faces"] = (landmarksRequest.results ?? []).map { face -> [String: Any] in
        let box = face.boundingBox
        let landmarks = face.landmarks
        var contours: [String: [[Double]]] = [
            "face": normalisedPoints(landmarks?.faceContour, box),
            "left_eye": normalisedPoints(landmarks?.leftEye, box),
            "right_eye": normalisedPoints(landmarks?.rightEye, box),
            "left_eyebrow": normalisedPoints(landmarks?.leftEyebrow, box),
            "right_eyebrow": normalisedPoints(landmarks?.rightEyebrow, box),
            "outer_lips": normalisedPoints(landmarks?.outerLips, box),
            "inner_lips": normalisedPoints(landmarks?.innerLips, box),
            "nose": normalisedPoints(landmarks?.nose, box),
        ]
        contours = contours.filter { !$0.value.isEmpty }
        var points: [String: [Double]] = [:]
        if let pupil = normalisedPoints(landmarks?.leftPupil, box).first { points["left_eye"] = pupil }
        if let pupil = normalisedPoints(landmarks?.rightPupil, box).first { points["right_eye"] = pupil }
        return [
            "box": [round4(box.minX), round4(1 - box.maxY), round4(box.width), round4(box.height)],
            "confidence": Double(face.confidence),
            "landmark_points": landmarks?.allPoints?.pointCount ?? 0,
            "landmarks": points,
            "contours": contours,
            "yaw": face.yaw?.doubleValue ?? NSNull(),
            "roll": face.roll?.doubleValue ?? NSNull(),
        ]
    }

    let personRequest = VNGeneratePersonSegmentationRequest()
    personRequest.qualityLevel = .accurate
    personRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
    entry["person_ms"] = try milliseconds { try handler.perform([personRequest]) }
    if let mask = personRequest.results?.first?.pixelBuffer {
        saveMask(mask, to: masksURL.appendingPathComponent("\(stem)__person.png"))
        entry["person_mask_size"] = [CVPixelBufferGetWidth(mask), CVPixelBufferGetHeight(mask)]
    }

    let foregroundRequest = VNGenerateForegroundInstanceMaskRequest()
    entry["foreground_ms"] = try milliseconds { try handler.perform([foregroundRequest]) }
    if let observation = foregroundRequest.results?.first {
        entry["foreground_instances"] = observation.allInstances.count
        if let mask = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler) {
            saveMask(mask, to: masksURL.appendingPathComponent("\(stem)__foreground.png"))
        }
    } else {
        entry["foreground_instances"] = 0
    }

    let personInstanceRequest = VNGeneratePersonInstanceMaskRequest()
    entry["person_instances_ms"] = try milliseconds { try handler.perform([personInstanceRequest]) }
    if let observation = personInstanceRequest.results?.first {
        entry["person_instances"] = observation.allInstances.count
        for (index, instance) in observation.allInstances.sorted().enumerated() {
            if let mask = try? observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler) {
                saveMask(mask, to: masksURL.appendingPathComponent("\(stem)__person_instance_\(index).png"))
            }
        }
    } else {
        entry["person_instances"] = 0
    }
    results[stem] = entry
    print(stem, (entry["faces"] as? [Any])?.count ?? 0, "faces,", entry["foreground_instances"] ?? 0, "fg,", entry["person_instances"] ?? 0, "people")
}
let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
try data.write(to: outURL.appendingPathComponent("vision.json"))
