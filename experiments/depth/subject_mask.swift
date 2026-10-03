// Subject matte with Apple Vision (the same request the iOS app uses for Background).
//
//   swiftc -O subject_mask.swift -o cache/subject_mask && cache/subject_mask cache/src cache/masks
//
// For every <stem>.png in the input folder writes <stem>.png (8-bit grey, soft matte, image size) to
// the output folder, all foreground instances merged. A photo with no instance gets no file — the
// renderer then treats it as "no clear subject" (depth-only refocus, no subject plane).
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let inputFolder = URL(fileURLWithPath: CommandLine.arguments[1])
let outputFolder = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
let ciContext = CIContext()

for name in try FileManager.default.contentsOfDirectory(atPath: inputFolder.path).sorted() where name.hasSuffix(".png") {
    let sourceURL = inputFolder.appendingPathComponent(name)
    guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { continue }
    let handler = VNImageRequestHandler(cgImage: image)
    let request = VNGenerateForegroundInstanceMaskRequest()
    let started = Date()
    try handler.perform([request])
    guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
        print("\(name): no subject"); continue
    }
    let maskBuffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
    let elapsedMs = Date().timeIntervalSince(started) * 1000
    let maskImage = CIImage(cvPixelBuffer: maskBuffer)
    let outputURL = outputFolder.appendingPathComponent(name)
    try ciContext.writePNGRepresentation(of: maskImage, to: outputURL, format: .L8,
                                         colorSpace: CGColorSpace(name: CGColorSpace.linearGray)!)
    print(String(format: "%@: %d instance(s), %.0f ms", name, observation.allInstances.count, elapsedMs))
}
