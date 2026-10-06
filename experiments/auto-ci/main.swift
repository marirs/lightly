// Mac check of the app's guards (compiled together with ios/.../CoreImageAutoGuards.swift): original | Core Image as
// proposed | guarded, per photo, with the guards' notes; sheet guarded-sheet.jpg.
import CoreImage; import Foundation; import ImageIO; import UniformTypeIdentifiers
let ctx = CIContext()
func load(_ p: String, _ m: Int) -> CGImage { let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!; return CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceThumbnailMaxPixelSize: m, kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)! }
func cg(_ i: CIImage) -> CGImage { ctx.createCGImage(i, from: i.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)! }
var rows: [[CGImage]] = []
for path in CommandLine.arguments.dropFirst() {
  let name = (path as NSString).lastPathComponent
  let proxy = load(path, 1024)
  let proposed = CIImage(cgImage: proxy).autoAdjustmentFilters(options: [.enhance: true, .redEye: false, .crop: false, .level: false])
  let g = CoreImageAutoGuards.guarded(proposed, proxy: proxy)
  print("== \(name)"); g.notes.forEach { print("   \($0)") }
  let input = CIImage(cgImage: proxy)
  rows.append([proxy, cg(CoreImageAutoGuards.apply(proposed, to: input)), cg(CoreImageAutoGuards.apply(g.filters, to: input))])
}
let th = 260, gap = 6
let widths = rows.map { r in r.map { Int(Double($0.width) / Double($0.height) * Double(th)) }.reduce(0, +) + 2 * gap }
let perRow = 2, colW = (widths.max() ?? 800) + 20, W = colW * perRow, H = ((rows.count + 1) / perRow) * (th + gap)
let sheet = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sheet.setFillColor(CGColor(gray: 1, alpha: 1)); sheet.fill(CGRect(x: 0, y: 0, width: W, height: H))
for (i, r) in rows.enumerated() {
  var x = (i % perRow) * colW; let y = H - (i / perRow + 1) * (th + gap)
  for img in r { let w = Int(Double(img.width) / Double(img.height) * Double(th)); sheet.draw(img, in: CGRect(x: x, y: y, width: w, height: th)); x += w + gap }
}
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "guarded-sheet.jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, sheet.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary); CGImageDestinationFinalize(d)
