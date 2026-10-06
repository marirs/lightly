// Controlled Auto evaluation (2026-10-06). The approved photos have no underexposed or colour-cast originals, so each
// is degraded in linear light with a known amount: "under" = -1.5 EV, "cast" = tungsten-like (R x1.18, B x0.78).
// Auto (the app's guards, CoreImageAutoGuards) runs on the original and on each degraded copy. Measure: mean CIELAB
// distance to the original, before and after Auto (lower after = moved back toward the photographer's version), and for
// the original itself how far Auto moved it (small = left alone). Sheet: original | degraded | Auto(degraded).
import CoreImage; import Foundation; import ImageIO; import UniformTypeIdentifiers
let ctx = CIContext(); let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!, linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
func load(_ p: String) -> CGImage { let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!; return CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)! }
func cg(_ i: CIImage) -> CGImage { ctx.createCGImage(i, from: i.extent, format: .RGBA8, colorSpace: sRGB)! }
func degrade(_ img: CGImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CGImage {
  let f = CIFilter(name: "CIColorMatrix")!; f.setValue(CIImage(cgImage: img), forKey: kCIInputImageKey)
  f.setValue(CIVector(x: r, y: 0, z: 0, w: 0), forKey: "inputRVector"); f.setValue(CIVector(x: 0, y: g, z: 0, w: 0), forKey: "inputGVector"); f.setValue(CIVector(x: 0, y: 0, z: b, w: 0), forKey: "inputBVector")
  return cg(f.outputImage!) }   // CIColorMatrix works in Core Image's linear working space
func px(_ i: CGImage) -> [UInt8] { var b = [UInt8](repeating: 0, count: i.width*i.height*4); CGContext(data: &b, width: i.width, height: i.height, bitsPerComponent: 8, bytesPerRow: i.width*4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height)); return b }
func dE(_ x: CGImage, _ y: CGImage) -> Double { let a = px(x), b = px(y); var s = 0.0, n = 0
  for i in stride(from: 0, to: a.count, by: 16) { let p = CoreImageAutoGuards.lab(Double(a[i]), Double(a[i+1]), Double(a[i+2])), q = CoreImageAutoGuards.lab(Double(b[i]), Double(b[i+1]), Double(b[i+2])); s += sqrt(pow(p.l-q.l,2)+pow(p.a-q.a,2)+pow(p.b-q.b,2)); n += 1 }
  return s / Double(n) }
func auto(_ img: CGImage) -> (CGImage, [String]) {
  let proposed = CIImage(cgImage: img).autoAdjustmentFilters(options: [.enhance: true, .redEye: false, .crop: false, .level: false]).filter { ["CIFaceBalance", "CIVibrance", "CIToneCurve"].contains($0.name) }
  let g = CoreImageAutoGuards.guarded(proposed, proxy: img)
  return (cg(CoreImageAutoGuards.apply(g.filters, to: CIImage(cgImage: img))), g.notes) }
var rows: [[CGImage]] = []
for path in CommandLine.arguments.dropFirst() {
  let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
  let o = load(path)
  let (ao, _) = auto(o)
  print(String(format: "%-18@ original: Auto moved it ΔE %.1f", name as NSString, dE(ao, o)))
  for (label, d) in [("under -1.5EV", degrade(o, r: 0.354, g: 0.354, b: 0.354)), ("warm cast", degrade(o, r: 1.18, g: 1.0, b: 0.78))] {
    let (ad, notes) = auto(d)
    let before = dE(d, o), after = dE(ad, o)
    print(String(format: "%-18@ %-13@ ΔE to original %.1f → %.1f  (%@)", "" as NSString, label as NSString, before, after, after < before - 0.5 ? "improved" : (after > before + 0.5 ? "WORSE" : "unchanged")))
    print("                     " + notes.dropFirst().dropLast().joined(separator: "; "))
    if ["portrait_light_01", "backlit_01", "portrait_deep_01", "night_01", "wellexposed_02"].contains(name) { rows.append([o, d, ad]) }
  }
}
let th = 220, gap = 6
let W = 3 * 160 * 2 + 40, H = rows.count * (th + gap)
let sheet = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sheet.setFillColor(CGColor(gray: 1, alpha: 1)); sheet.fill(CGRect(x: 0, y: 0, width: W, height: H))
for (i, r) in rows.enumerated() { var x = 0; let y = H - (i + 1) * (th + gap); for img in r { let w = Int(Double(img.width) / Double(img.height) * Double(th)); sheet.draw(img, in: CGRect(x: x, y: y, width: w, height: th)); x += w + gap } }
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "eval-sheet.jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, sheet.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary); CGImageDestinationFinalize(d)
