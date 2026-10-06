// Core Image auto enhancement as the iOS app applies it: autoAdjustmentFilters(.enhance, no red-eye, no crop, no
// level) on a ≤1024 px proxy; only CIFaceBalance, CIVibrance, CIToneCurve applied. Writes before|after pairs and
// prints the filters and parameters per photo, plus simple measurements of the change.
import CoreImage; import Foundation; import ImageIO; import UniformTypeIdentifiers
let applied: Set<String> = ["CIFaceBalance", "CIVibrance", "CIToneCurve"]
let ctx = CIContext()
func load(_ p: String, _ max: Int) -> CGImage { let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!; return CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceThumbnailMaxPixelSize: max, kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)! }
func stats(_ img: CGImage) -> (Double, Double, Double) {
  let w = img.width, h = img.height; var b = [UInt8](repeating: 0, count: w*h*4)
  let c = CGContext(data: &b, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
  var lum = 0.0, clip = 0, sat = 0.0
  for i in 0..<(w*h) { let r = Double(b[i*4]), g = Double(b[i*4+1]), bb = Double(b[i*4+2]); lum += 0.2126*r + 0.7152*g + 0.0722*bb; if max(r, g, bb) >= 254 { clip += 1 }; sat += max(r, g, bb) - min(r, g, bb) }
  let n = Double(w*h); return (lum / n, Double(clip) / n * 100, sat / n)
}
var tiles: [(CGImage, CGImage, String)] = []
for path in CommandLine.arguments.dropFirst() {
  let name = (path as NSString).lastPathComponent
  let proxy = load(path, 1024), shown = load(path, 600)
  let filters = CIImage(cgImage: proxy).autoAdjustmentFilters(options: [.enhance: true, .redEye: false, .crop: false, .level: false])
  var out = CIImage(cgImage: shown); var used: [String] = []; var omitted: [String] = []
  for f in filters {
    guard applied.contains(f.name) else { omitted.append(f.name); continue }
    let params = f.inputKeys.filter { $0 != kCIInputImageKey }.map { k -> String in
      if let n = f.value(forKey: k) as? NSNumber { return "\(k.replacingOccurrences(of: "input", with: ""))=\(String(format: "%.3f", n.doubleValue))" }
      if let v = f.value(forKey: k) as? CIVector { return "\(k.replacingOccurrences(of: "input", with: ""))=(" + (0..<v.count).map { String(format: "%.2f", v.value(at: $0)) }.joined(separator: ",") + ")" }
      return k }
    used.append("\(f.name)[\(params.joined(separator: " "))]")
    f.setValue(out, forKey: kCIInputImageKey); out = f.outputImage!
  }
  let after = ctx.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
  let s0 = stats(shown), s1 = stats(after)
  print("\(name): mean luma \(String(format: "%.0f→%.0f", s0.0, s1.0)), clipped \(String(format: "%.2f→%.2f", s0.1, s1.1)) %, chroma \(String(format: "%.0f→%.0f", s0.2, s1.2))")
  print("   applied: \(used.isEmpty ? "none" : used.joined(separator: "; "))"); if !omitted.isEmpty { print("   omitted: \(omitted)") }
  tiles.append((shown, after, name))
}
// Sheet: rows of before|after, each tile scaled to 300 px high.
let th = 300, gap = 8
let rowsW = tiles.map { t in Int(Double(t.0.width) / Double(t.0.height) * Double(th)) * 2 + gap }
let W = (rowsW.max() ?? 600) * 2 + gap, perRow = 2
let rows = (tiles.count + perRow - 1) / perRow, H = rows * (th + gap)
let sheet = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sheet.setFillColor(CGColor(gray: 1, alpha: 1)); sheet.fill(CGRect(x: 0, y: 0, width: W, height: H))
for (i, t) in tiles.enumerated() {
  let tw = Int(Double(t.0.width) / Double(t.0.height) * Double(th)), col = i % perRow, row = i / perRow
  let x0 = col * ((rowsW.max() ?? 600) + gap), y0 = H - (row + 1) * (th + gap)
  sheet.draw(t.0, in: CGRect(x: x0, y: y0, width: tw, height: th)); sheet.draw(t.1, in: CGRect(x: x0 + tw + 4, y: y0, width: tw, height: th))
}
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "auto-sheet.jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, sheet.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary); CGImageDestinationFinalize(d)
