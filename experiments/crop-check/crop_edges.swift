import CoreGraphics
import ImageIO
import Foundation
// crop_edges <screenshot of the crop editor> <saved image> <screen px per saved px>
// Finds where the saved image's content sits in the screenshot (normalised cross-correlation at the given scale,
// grey, 1/4 resolution), then measures how white the screenshot is along that rectangle's four edges compared with
// lines 12 px inside and outside: the crop frame's white border lies on the saved image's edges only if they match.
func load(_ p: String) -> CGImage { let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil as CFDictionary?)!; return CGImageSourceCreateImageAtIndex(s, 0, nil as CFDictionary?)! }
func rgba(_ i: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: w*h*4)
    let c = CGContext(data: &b, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high; c.draw(i, in: CGRect(x: 0, y: 0, width: w, height: h)); return b }
func grey(_ p: [UInt8], _ n: Int) -> [Float] { (0..<n).map { Float(p[$0*4]) * 0.299 + Float(p[$0*4+1]) * 0.587 + Float(p[$0*4+2]) * 0.114 } }
let a = CommandLine.arguments
let shot = load(a[1]), saved = load(a[2]); let scale = Double(a[3])!
let f = 4
let W = shot.width / f, H = shot.height / f
let S = grey(rgba(shot, W, H), W*H)
let w = Int((Double(saved.width) * scale / Double(f)).rounded()), h = Int((Double(saved.height) * scale / Double(f)).rounded())
var T = grey(rgba(saved, w, h), w*h)
let tm = T.reduce(0, +) / Float(T.count); T = T.map { $0 - tm }; let tn = sqrt(T.reduce(0) { $0 + $1*$1 })
var best = (score: Float(-2), x: 0, y: 0)
for y in 0...(H - h) { for x in 0...(W - w) {
    var sum: Float = 0, sum2: Float = 0, dot: Float = 0
    var j = 0
    while j < h { var i = 0; let row = (y + j) * W + x; let trow = j * w
        while i < w { let v = S[row + i]; sum += v; sum2 += v*v; dot += v * T[trow + i]; i += 2 }; j += 2 }
    let n = Float(((w + 1) / 2) * ((h + 1) / 2)); let mean = sum / n
    let sn = sqrt(max(sum2 - n * mean * mean, 1e-6))
    let score = dot / (sn * tn) * 2   // sampled every 2nd pixel of T as well
    if score > best.score { best = (score, x, y) }
} }
let rx = best.x * f, ry = best.y * f, rw = w * f, rh = h * f
print("saved content found at x \(rx)…\(rx + rw), y \(ry)…\(ry + rh) (screen px), correlation \(String(format: "%.2f", best.score))")
let full = rgba(shot, shot.width, shot.height)
func whiteness(vertical: Bool, at c: Int, from s: Int, to e: Int) -> Double {
    var white = 0, n = 0
    for t in stride(from: s, to: e, by: 2) {
        let (x, y) = vertical ? (c, t) : (t, c)
        guard x >= 0, y >= 0, x < shot.width, y < shot.height else { continue }
        // the best of ±3 px across the line (a 1 pt border, rounded positions)
        var hit = false
        for d in -3...3 { let (xx, yy) = vertical ? (x + d, y) : (x, y + d)
            guard xx >= 0, yy >= 0, xx < shot.width, yy < shot.height else { continue }
            let k = (yy * shot.width + xx) * 4; if full[k] > 235 && full[k+1] > 235 && full[k+2] > 235 { hit = true } }
        if hit { white += 1 }; n += 1 }
    return n == 0 ? 0 : Double(white) / Double(n) }
for (name, vertical, pos, s, e, inward) in [("left", true, rx, ry, ry + rh, 1), ("right", true, rx + rw, ry, ry + rh, -1),
                                             ("top", false, ry, rx, rx + rw, 1), ("bottom", false, ry + rh, rx, rx + rw, -1)] {
    let on = whiteness(vertical: vertical, at: pos, from: s, to: e)
    let inside = whiteness(vertical: vertical, at: pos + 12 * inward, from: s, to: e)
    let outside = whiteness(vertical: vertical, at: pos - 12 * inward, from: s, to: e)
    print(String(format: "%-6@ white on the edge %.2f, 12 px inside %.2f, 12 px outside %.2f", name as NSString, on, inside, outside))
}
