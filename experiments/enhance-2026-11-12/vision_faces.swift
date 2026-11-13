// Enhance step 2a: Apple Vision face rectangles (what the iOS app's PersonDetector uses) for each image.
// Prints one JSON object: {"<image path>": [[x, y, width, height] in pixels, top-left origin], ...}.
// Run: swift vision_faces.swift <image> [<image> ...]
import Foundation
import Vision
import ImageIO

var result: [String: [[Double]]] = [:]
for path in CommandLine.arguments.dropFirst() {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
        continue
    }
    let width = Double(image.width), height = Double(image.height)
    let request = VNDetectFaceRectanglesRequest()
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    // Vision boxes are normalised with a bottom-left origin.
    result[path] = (request.results ?? []).map { face in
        let box = face.boundingBox
        return [box.minX * width, (1 - box.maxY) * height, box.width * width, box.height * height]
    }
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
