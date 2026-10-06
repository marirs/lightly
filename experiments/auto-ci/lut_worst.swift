// Worst-case check of the Auto LUT (33^3, as the app bakes it) against the filter chain applied directly, per photo:
// mean, p99.9 and max error (of 255), and where the largest errors are (luma band and edge strength).
import CoreImage; import Foundation; import ImageIO
let ctx = CIContext(); let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func load(_ p: String, _ m: Int) -> CIImage { let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!; return CIImage(cgImage: CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceThumbnailMaxPixelSize: m, kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)!) }
func pixels(_ i: CIImage) -> [Float] { let w = Int(i.extent.width), h = Int(i.extent.height); var o = [Float](repeating: 0, count: w*h*4); o.withUnsafeMutableBytes { ctx.render(i, toBitmap: $0.baseAddress!, rowBytes: w*16, bounds: i.extent, format: .RGBAf, colorSpace: sRGB) }; return o }
func chain(_ i: CIImage, _ fs: [CIFilter]) -> CIImage { fs.reduce(i) { c, f in let g = f.copy() as! CIFilter; g.setValue(c, forKey: kCIInputImageKey); return g.outputImage! } }
for path in CommandLine.arguments.dropFirst() {
  let img = load(path, 1600); let w = Int(img.extent.width), h = Int(img.extent.height)
  // The unguarded proposal (strongest case: every filter at Core Image's own values).
  let only = ProcessInfo.processInfo.environment["ONLY"]; let filters = load(path, 1024).autoAdjustmentFilters(options: [.enhance: true, .redEye: false, .crop: false, .level: false]).filter { only == nil || $0.name == only }
  let direct = pixels(chain(img, filters))
  let n = Int(ProcessInfo.processInfo.environment["N"] ?? "33")!; var lattice = [Float](repeating: 1, count: n*n*n*4)
  for b in 0..<n { for g in 0..<n { for r in 0..<n { let i = (r + n*g + n*n*b)*4; lattice[i] = Float(r)/Float(n-1); lattice[i+1] = Float(g)/Float(n-1); lattice[i+2] = Float(b)/Float(n-1) } } }
  let lat = CIImage(bitmapData: lattice.withUnsafeBytes { Data($0) }, bytesPerRow: n*n*16, size: CGSize(width: n*n, height: n), format: .RGBAf, colorSpace: sRGB)
  let cube = pixels(chain(lat, filters))
  let cf = CIFilter(name: "CIColorCubeWithColorSpace")!; cf.setValue(img, forKey: kCIInputImageKey); cf.setValue(n, forKey: "inputCubeDimension"); cf.setValue(cube.withUnsafeBytes { Data($0) }, forKey: "inputCubeData"); cf.setValue(sRGB, forKey: "inputColorSpace")
  let viaLUT = pixels(cf.outputImage!); let src = pixels(img)
  var errs = [Float](repeating: 0, count: w*h)
  for p in 0..<(w*h) { var m: Float = 0; for c in 0..<3 { m = max(m, abs(direct[p*4+c] - viaLUT[p*4+c]) * 255) }; errs[p] = m }
  let sorted = errs.sorted(); let mean = errs.reduce(0, +) / Float(errs.count)
  // where: luma band of the source and local gradient at the 200 worst pixels
  let worst = errs.enumerated().sorted { $0.element > $1.element }.prefix(200).map(\.offset)
  var hi = 0, mid = 0, lo = 0, edge = 0
  for p in worst { let y = 0.2126*src[p*4] + 0.7152*src[p*4+1] + 0.0722*src[p*4+2]; if y > 0.8 { hi += 1 } else if y < 0.2 { lo += 1 } else { mid += 1 }
    let x = p % w; if x > 0 && x < w-1 { let g = abs(src[(p+1)*4+1] - src[(p-1)*4+1]); if g > 0.1 { edge += 1 } } }
  print("\((path as NSString).lastPathComponent) [\(filters.map(\.name).joined(separator: ","))]: mean \(String(format: "%.2f", mean)), p99.9 \(String(format: "%.1f", sorted[sorted.count * 999 / 1000])), max \(String(format: "%.1f", sorted.last!)) /255; worst 200 px: highlights \(hi), mid \(mid), shadows \(lo), on edges \(edge)")
}
