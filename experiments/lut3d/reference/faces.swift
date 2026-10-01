// Detect face rectangles with Apple Vision for every golden/<stem>/source.png.
// Output: golden/faces.json  {stem: [[x,y,w,h] normalised, origin top-left]}
import Foundation
import Vision
import ImageIO

let goldenURL = URL(fileURLWithPath: CommandLine.arguments[1])
var result: [String: [[Double]]] = [:]
let stems = try FileManager.default.contentsOfDirectory(atPath: goldenURL.path).sorted()
for stem in stems {
    let src = goldenURL.appendingPathComponent(stem).appendingPathComponent("source.png")
    guard let isrc = CGImageSourceCreateWithURL(src as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(isrc, 0, nil) else { continue }
    let request = VNDetectFaceRectanglesRequest()
    try VNImageRequestHandler(cgImage: image).perform([request])
    result[stem] = (request.results ?? []).filter { $0.confidence > 0.6 }.map {
        let b = $0.boundingBox  // Vision: normalised, origin bottom-left
        return [b.minX, 1 - b.maxY, b.width, b.height]
    }
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
try data.write(to: goldenURL.appendingPathComponent("faces.json"))
print(String(data: data, encoding: .utf8)!)
