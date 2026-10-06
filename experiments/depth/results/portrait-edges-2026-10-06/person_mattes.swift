// Apple Vision on macOS at the app's input size (long edge 1600): person segmentation (.accurate, .balanced) and the
// foreground-instance mask, each written as an 8-bit PNG at the input size.
import CoreImage; import Foundation; import ImageIO; import UniformTypeIdentifiers; import Vision
func load(_ p: String) -> CGImage { let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!; return CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)! }
func write(_ buffer: CVPixelBuffer, _ w: Int, _ h: Int, _ path: String) {
  var image = CIImage(cvPixelBuffer: buffer)
  image = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / image.extent.width, y: CGFloat(h) / image.extent.height))
  let cg = CIContext().createCGImage(image, from: CGRect(x: 0, y: 0, width: w, height: h), format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray)!)!
  let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
}
let image = load(CommandLine.arguments[1]); let tag = CommandLine.arguments[2]
print(tag, image.width, image.height)
for (name, q) in [("accurate", VNGeneratePersonSegmentationRequest.QualityLevel.accurate), ("balanced", .balanced)] {
  let r = VNGeneratePersonSegmentationRequest(); r.qualityLevel = q
  let h = VNImageRequestHandler(cgImage: image); try h.perform([r])
  let b = r.results!.first!.pixelBuffer
  print(" person \(name): \(CVPixelBufferGetWidth(b))x\(CVPixelBufferGetHeight(b))")
  write(b, image.width, image.height, "\(tag)-person-\(name).png")
}
let fg = VNGenerateForegroundInstanceMaskRequest(); let h = VNImageRequestHandler(cgImage: image); try h.perform([fg])
let o = fg.results!.first!; let b = try o.generateScaledMaskForImage(forInstances: o.allInstances, from: h)
print(" instance: \(CVPixelBufferGetWidth(b))x\(CVPixelBufferGetHeight(b))")
write(b, image.width, image.height, "\(tag)-instance-mac.png")
