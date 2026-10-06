// Is CIHighlightShadowAdjust (Radius 0, as Core Image's auto proposes it) per-pixel? Bake it into a 65^3 LUT from a
// lattice image, apply the LUT to the photo, compare with the filter applied to the photo directly; also compare the
// filter on a 2x-downscaled photo vs downscaling the full result (a local filter differs with scale).
import CoreImage; import Foundation; import ImageIO
let ctx = CIContext(); let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func load(_ p: String, _ m: Int) -> CIImage { let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!; return CIImage(cgImage: CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceThumbnailMaxPixelSize: m, kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)!) }
func hsa(_ i: CIImage, shadow: Double) -> CIImage { let f = CIFilter(name: "CIHighlightShadowAdjust")!; f.setValue(i, forKey: kCIInputImageKey); f.setValue(0, forKey: "inputRadius"); f.setValue(shadow, forKey: "inputShadowAmount"); f.setValue(1, forKey: "inputHighlightAmount"); return f.outputImage! }
func pixels(_ i: CIImage) -> [Float] { let w = Int(i.extent.width), h = Int(i.extent.height); var o = [Float](repeating: 0, count: w*h*4); o.withUnsafeMutableBytes { ctx.render(i, toBitmap: $0.baseAddress!, rowBytes: w*16, bounds: i.extent, format: .RGBAf, colorSpace: sRGB) }; return o }
for path in CommandLine.arguments.dropFirst() {
  let img = load(path, 800)
  let direct = pixels(hsa(img, shadow: 0.25))
  // LUT via a lattice (65^3) and the CIColorCubeWithColorSpace filter
  let n = 65; var lattice = [Float](repeating: 1, count: n*n*n*4)
  for b in 0..<n { for g in 0..<n { for r in 0..<n { let i = (r + n*g + n*n*b)*4; lattice[i] = Float(r)/Float(n-1); lattice[i+1] = Float(g)/Float(n-1); lattice[i+2] = Float(b)/Float(n-1) } } }
  let lat = CIImage(bitmapData: lattice.withUnsafeBytes { Data($0) }, bytesPerRow: n*n*16, size: CGSize(width: n*n, height: n), format: .RGBAf, colorSpace: sRGB)
  let cube = pixels(hsa(lat, shadow: 0.25))
  let cf = CIFilter(name: "CIColorCubeWithColorSpace")!; cf.setValue(img, forKey: kCIInputImageKey); cf.setValue(n, forKey: "inputCubeDimension"); cf.setValue(cube.withUnsafeBytes { Data($0) }, forKey: "inputCubeData"); cf.setValue(sRGB, forKey: "inputColorSpace")
  let viaLUT = pixels(cf.outputImage!)
  var d = 0.0, mx = 0.0; for i in 0..<direct.count where i % 4 != 3 { let e = Double(abs(direct[i] - viaLUT[i])) * 255; d += e; mx = max(mx, e) }
  print("\((path as NSString).lastPathComponent): filter vs baked LUT: mean |Δ| \(String(format: "%.2f", d / Double(direct.count / 4 * 3))) /255, max \(String(format: "%.1f", mx))")
}
