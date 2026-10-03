// Regenerates ios/Tests/Fixtures/SubjectMattes: the subject matte Vision computes on macOS for the
// photos the design captures and tests use.
//
// Why: in the iOS Simulator `VNGenerateForegroundInstanceMaskRequest` fails ("Could not create
// inference context"), so simulator runs cannot compute a matte. DEBUG simulator builds may load
// these instead (`--subject-matte-fixtures <dir>`); devices always run the request itself. The
// request and its output are the same API on macOS 14+.
//
// Usage: swift ios/Tools/make_subject_matte_fixtures.swift <repo root>
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let photos = ["docs/ui/assets/photos/portrait_medium_02", "docs/ui/assets/photos/portrait_deep_03",
              "docs/ui/assets/photos/portrait_deep_02", "docs/ui/assets/photos/landscape_02",
              "docs/ui/assets/photos/landscape_03", "docs/ui/assets/photos/night_03",
              "docs/ui/assets/photos/sunset_02", "experiments/test-photos/group_three_01"]
let out = root.appendingPathComponent("ios/Tests/Fixtures/SubjectMattes")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for photo in photos {
    let url = root.appendingPathComponent(photo + ".jpg")
    let name = url.deletingPathExtension().lastPathComponent
    let handler = VNImageRequestHandler(url: url)
    let request = VNGenerateForegroundInstanceMaskRequest()
    try handler.perform([request])
    guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
        // No clear subject: an empty marker file says so.
        FileManager.default.createFile(atPath: out.appendingPathComponent(name + ".none").path, contents: Data())
        print("\(name): no subject")
        continue
    }
    let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
    let image = CIImage(cvPixelBuffer: buffer)
    let context = CIContext()
    let grey = CGColorSpace(name: CGColorSpace.linearGray)!
    guard let cg = context.createCGImage(image, from: image.extent, format: .L8, colorSpace: grey) else { continue }
    let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
    print("\(name): \(cg.width)x\(cg.height)")
}
