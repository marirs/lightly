// Face rectangles for an evaluation manifest, with the SAME detector and threshold as the pinned protocol
// detector (experiments/lut3d/reference/faces.swift: VNDetectFaceRectanglesRequest, confidence > 0.6).
// Only the input listing differs: this reads "image_id<TAB>absolute_png_path" lines from a file instead of
// golden/<stem>/source.png folders.
//   swift data_tools/faces_for_manifest.swift <list.tsv> <out faces.json>
// Output: {image_id: [[x, y, w, h] normalised, origin top-left]}
import Foundation
import Vision
import ImageIO

let listing = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
var result: [String: [[Double]]] = [:]
for line in listing.split(separator: "\n") {
    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { continue }
    let url = URL(fileURLWithPath: parts[1])
    guard let isrc = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(isrc, 0, nil) else { continue }
    let request = VNDetectFaceRectanglesRequest()
    try VNImageRequestHandler(cgImage: image).perform([request])
    result[parts[0]] = (request.results ?? []).filter { $0.confidence > 0.6 }.map {
        let b = $0.boundingBox  // Vision: normalised, origin bottom-left
        return [b.minX, 1 - b.maxY, b.width, b.height]
    }
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("faces for \(result.count) images")
