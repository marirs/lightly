// Per-filter effect of Core Image auto enhancement: original, each proposed filter alone, all applied filters.
// Skin = Lab of the inner 60 % of Vision face boxes; clipped = share of pixels with any channel >= 254;
// p1/p99 luma; mean luma. Also prints CIHighlightShadowAdjust's parameters.
import CoreImage; import Foundation; import ImageIO; import Vision
let ctx = CIContext()
func load(_ p: String, _ m: Int) -> CGImage { let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!; return CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceThumbnailMaxPixelSize: m, kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)! }
func rgba(_ i: CGImage) -> [UInt8] { var b = [UInt8](repeating: 0, count: i.width*i.height*4); CGContext(data: &b, width: i.width, height: i.height, bitsPerComponent: 8, bytesPerRow: i.width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height)); return b }
func lab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
  func l(_ c: Double) -> Double { let c = c / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
  let R = l(r), G = l(g), B = l(b)
  var x = (0.4124*R + 0.3576*G + 0.1805*B) / 0.95047, y = 0.2126*R + 0.7152*G + 0.0722*B, z = (0.0193*R + 0.1192*G + 0.9505*B) / 1.08883
  func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787*t + 16/116 }
  x = f(x); y = f(y); z = f(z); return (116*y - 16, 500*(x - y), 200*(y - z)) }
func measure(_ img: CGImage, faces: [CGRect]) -> String {
  let b = rgba(img), w = img.width, h = img.height
  var lum: [Double] = []; lum.reserveCapacity(w*h/4); var clip = 0, n = 0
  for y in stride(from: 0, to: h, by: 2) { for x in stride(from: 0, to: w, by: 2) { let i = (y*w+x)*4; let r = Double(b[i]), g = Double(b[i+1]), bb = Double(b[i+2]); lum.append(0.2126*r + 0.7152*g + 0.0722*bb); if max(r, g, bb) >= 254 { clip += 1 }; n += 1 } }
  lum.sort(); let mean = lum.reduce(0, +) / Double(lum.count)
  var skin = ""
  if !faces.isEmpty { var L = 0.0, A = 0.0, B = 0.0, m = 0.0
    for f in faces { let r = CGRect(x: f.minX * Double(w), y: (1 - f.maxY) * Double(h), width: f.width * Double(w), height: f.height * Double(h)).insetBy(dx: f.width * Double(w) * 0.2, dy: f.height * Double(h) * 0.2)
      for y in stride(from: Int(r.minY), to: Int(r.maxY), by: 2) { for x in stride(from: Int(r.minX), to: Int(r.maxX), by: 2) { let i = (y*w+x)*4; let c = lab(Double(b[i]), Double(b[i+1]), Double(b[i+2])); L += c.0; A += c.1; B += c.2; m += 1 } } }
    L /= m; A /= m; B /= m; skin = String(format: " skin L %.0f a %.1f b %.1f hue %.0f° chroma %.1f", L, A, B, atan2(B, A) * 180 / .pi, hypot(A, B)) }
  return String(format: "luma %.0f p1 %.0f p99 %.0f clip %.2f%%", mean, lum[lum.count/100], lum[lum.count*99/100], Double(clip)/Double(n)*100) + skin }
for path in CommandLine.arguments.dropFirst() {
  let name = (path as NSString).lastPathComponent
  let proxy = load(path, 1024)
  let req = VNDetectFaceRectanglesRequest(); try? VNImageRequestHandler(cgImage: proxy).perform([req])
  let faces = (req.results ?? []).map(\.boundingBox)
  let filters = CIImage(cgImage: proxy).autoAdjustmentFilters(options: [.enhance: true, .redEye: false, .crop: false, .level: false])
  print("== \(name) (\(faces.count) face)")
  print("   original:            \(measure(proxy, faces: faces))")
  func render(_ fs: [CIFilter]) -> CGImage { var o = CIImage(cgImage: proxy); for f in fs { let c = f.copy() as! CIFilter; c.setValue(o, forKey: kCIInputImageKey); o = c.outputImage! }; return ctx.createCGImage(o, from: o.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)! }
  for f in filters {
    let params = f.inputKeys.filter { $0 != kCIInputImageKey }.map { k -> String in if let n = f.value(forKey: k) as? NSNumber { return "\(k.dropFirst(5))=\(String(format: "%.3f", n.doubleValue))" }; if let v = f.value(forKey: k) as? CIVector { return "\(k.dropFirst(5))=(" + (0..<v.count).map { String(format: "%.2f", v.value(at: $0)) }.joined(separator: ",") + ")" }; return String(k) }.joined(separator: " ")
    print("   only \(f.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(measure(render([f]), faces: faces))   [\(params)]") }
  print("   all proposed:        \(measure(render(filters), faces: faces))")
}
