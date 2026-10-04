import Foundation
import CoreGraphics
import ImageIO
// pixdiff a.png b.png : differing pixels (any channel > 0), max channel delta, bounding box of the differences.
func rgba(_ p: String) -> (Int, Int, [UInt8]) {
    let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!
    let i = CGImageSourceCreateImageAtIndex(s, 0, nil)!
    var d = [UInt8](repeating: 0, count: i.width * i.height * 4)
    let c = CGContext(data: &d, width: i.width, height: i.height, bitsPerComponent: 8, bytesPerRow: i.width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
    return (i.width, i.height, d)
}
let (w1, h1, a) = rgba(CommandLine.arguments[1]), (w2, h2, b) = rgba(CommandLine.arguments[2])
guard w1 == w2, h1 == h2 else { print("SIZE \(w1)x\(h1) vs \(w2)x\(h2)"); exit(0) }
let skipTop = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3])! : 0
var n = 0, mx = 0, x0 = w1, y0 = h1, x1 = -1, y1 = -1
for y in skipTop..<h1 { for x in 0..<w1 {
    let o = (y * w1 + x) * 4; var d = 0
    for k in 0..<3 { d = max(d, abs(Int(a[o + k]) - Int(b[o + k]))) }
    if d > 0 { n += 1; mx = max(mx, d); x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y) }
} }
print(n == 0 ? "IDENTICAL" : "DIFF pixels=\(n) max=\(mx) box=\(x0),\(y0)-\(x1),\(y1) of \(w1)x\(h1)")
