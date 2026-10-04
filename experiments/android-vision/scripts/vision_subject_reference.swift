// Scratch: Apple Vision reference on macOS for the Android evaluation set. Writes <name>.png (foreground
// instance matte, all instances) or <name>.none, and vision.json (faces with landmarks, humans, instances).
import CoreImage; import Foundation; import ImageIO; import UniformTypeIdentifiers; import Vision
let dir = URL(fileURLWithPath: CommandLine.arguments[1]); let out = URL(fileURLWithPath: CommandLine.arguments[2])
var report: [String: Any] = [:]
for file in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where file.hasSuffix(".jpg") {
  let url = dir.appendingPathComponent(file); let name = (file as NSString).deletingPathExtension
  let handler = VNImageRequestHandler(url: url)
  let fg = VNGenerateForegroundInstanceMaskRequest(); let faces = VNDetectFaceLandmarksRequest(); let humans = VNDetectHumanRectanglesRequest()
  humans.upperBodyOnly = false
  try handler.perform([fg, faces, humans])
  var entry: [String: Any] = [:]
  entry["faces"] = (faces.results ?? []).map { f -> [String: Any] in
    var d: [String: Any] = ["box": [f.boundingBox.minX, f.boundingBox.minY, f.boundingBox.width, f.boundingBox.height]]
    if let l = f.landmarks { for (k, r) in [("leftEye", l.leftEye), ("rightEye", l.rightEye), ("outerLips", l.outerLips), ("nose", l.nose)] { if let r = r { d[k] = r.normalizedPoints.map { [f.boundingBox.minX + $0.x * f.boundingBox.width, f.boundingBox.minY + $0.y * f.boundingBox.height] } } } }
    return d }
  entry["humans"] = (humans.results ?? []).map { [$0.boundingBox.minX, $0.boundingBox.minY, $0.boundingBox.width, $0.boundingBox.height, Double($0.confidence)] }
  if let o = fg.results?.first, !o.allInstances.isEmpty {
    entry["instances"] = o.allInstances.count
    let buffer = try o.generateScaledMaskForImage(forInstances: o.allInstances, from: handler)
    let image = CIImage(cvPixelBuffer: buffer)
    let cg = CIContext().createCGImage(image, from: image.extent, format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray)!)!
    let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil); CGImageDestinationFinalize(dest)
  } else { entry["instances"] = 0 }
  report[name] = entry; print(name, entry["instances"]!, (entry["faces"] as! [Any]).count, (entry["humans"] as! [Any]).count)
}
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]); try data.write(to: out.appendingPathComponent("vision.json"))
