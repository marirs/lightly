import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
// tile <out.png> <columns> <cellWidth> img... : grid contact sheet
let a = CommandLine.arguments
let out = a[1], cols = Int(a[2])!, cw = Int(a[3])!
let imgs = a.dropFirst(4).map { p -> CGImage in let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!; return CGImageSourceCreateImageAtIndex(s, 0, nil)! }
let ch = imgs.map { $0.height * cw / $0.width }.max()!
let rows = (imgs.count + cols - 1) / cols
let W = cols * cw + (cols - 1) * 12, H = rows * ch + (rows - 1) * 12
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 0, green: 0.6, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
ctx.interpolationQuality = .high
for (i, im) in imgs.enumerated() {
    let r = i / cols, c = i % cols, h = im.height * cw / im.width
    ctx.draw(im, in: CGRect(x: c * (cw + 12), y: H - (r * (ch + 12)) - h, width: cw, height: h))
}
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
