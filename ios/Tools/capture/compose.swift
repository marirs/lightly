import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
// compose left.png right.png out.jpg (JPEG q80 review copy; the PNGs stay the evidence) : side by side (reference left, native right), 24px gap, scaled to the same height.
func load(_ p: String) -> CGImage {
    let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(s, 0, nil)!
}
let a = CommandLine.arguments
let l = load(a[1]), r = load(a[2])
let h = max(l.height, r.height)
let lw = l.width * h / l.height, rw = r.width * h / r.height
let gap = 24
let ctx = CGContext(data: nil, width: lw + gap + rw, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: lw + gap + rw, height: h))
ctx.interpolationQuality = .high
ctx.draw(l, in: CGRect(x: 0, y: 0, width: lw, height: h))
ctx.draw(r, in: CGRect(x: lw + gap, y: 0, width: rw, height: h))
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[3]) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary); CGImageDestinationFinalize(d)
print("\(a[3]) ref \(l.width)x\(l.height) native \(r.width)x\(r.height)")
