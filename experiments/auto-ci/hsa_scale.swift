// Does CIHighlightShadowAdjust (Radius 0) give the same result at preview size and at export size?
// Apply at 800 px and at 3200 px; downscale the 3200 result to 800; compare.
import CoreImage; import Foundation; import ImageIO
let ctx = CIContext(); let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func load(_ p: String, _ m: Int) -> CIImage { let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!; return CIImage(cgImage: CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceThumbnailMaxPixelSize: m, kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)!) }
func hsa(_ i: CIImage) -> CIImage { let f = CIFilter(name: "CIHighlightShadowAdjust")!; f.setValue(i, forKey: kCIInputImageKey); f.setValue(0, forKey: "inputRadius"); f.setValue(0.25, forKey: "inputShadowAmount"); f.setValue(1, forKey: "inputHighlightAmount"); return f.outputImage! }
func px(_ i: CIImage, _ w: Int, _ h: Int) -> [Float] { let s = i.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / i.extent.width, y: CGFloat(h) / i.extent.height)); var o = [Float](repeating: 0, count: w*h*4); o.withUnsafeMutableBytes { ctx.render(s, toBitmap: $0.baseAddress!, rowBytes: w*16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: sRGB) }; return o }
for path in CommandLine.arguments.dropFirst() {
  let small = load(path, 800), big = load(path, 3200); let w = Int(small.extent.width), h = Int(small.extent.height)
  let a = px(hsa(small), w, h), b = px(hsa(big), w, h), a0 = px(small, w, h), b0 = px(big, w, h)
  var d = 0.0, m: Float = 0, base = 0.0; for i in 0..<a.count where i % 4 != 3 { let e = abs(a[i] - b[i]) * 255; d += Double(e); m = max(m, e); base += Double(abs(a0[i] - b0[i]) * 255) }
  let n = Double(a.count / 4 * 3)
  print("\((path as NSString).lastPathComponent): preview-size vs export-size result: mean \(String(format: "%.2f", d / n)) max \(String(format: "%.1f", m)) /255 (resampling alone: mean \(String(format: "%.2f", base / n)))")
}
