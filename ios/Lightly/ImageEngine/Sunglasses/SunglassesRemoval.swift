import CoreGraphics
import Foundation
import simd

/// §7.5 composite step 1: a face found wearing glasses has them painted out before the chosen pair goes on. The fill
/// is Remove's LaMa model on a square window around the glasses, stored as a `RemovePatch` by digest exactly as Remove
/// stores a stroke (`faceEdit.sunglasses.removed`), so preview and export composite the same pixels and the model never
/// runs again for it (remove-evaluation §7).
enum SunglassesRemoval {

    /// The glasses mask is widened to catch rims and their shadows: the trial's MaxFilters 15, 15, 15 and 9 px on a
    /// 2000 px photo, i.e. a radius of 25 px per 2000 px of the long edge.
    static let dilationOfLongEdge = 0.0125
    /// The model's context: a square of 1.5 × the mask's extent, at least 256 px (the trial's crop).
    static let contextFactor = 1.5, minimumWindow = 256
    /// Paste-back feather (Gaussian sigma, source pixels), as the trial's GaussianBlur(3).
    static let featherSigma: Float = 3

    /// The patch for `analysis`'s face, or nil when the face has no glasses. `source` is the full-resolution photo the
    /// analysis was made on or a larger copy of it (same aspect).
    static func patch(for analysis: FaceSunglassesAnalysis, source: CGImage, inpainter: any Inpainting) async throws
        -> (patch: RemovePatch, rect: EditRecipe.Rect)? {
        guard let glasses = analysis.glassesMask() else { return nil }
        let W = source.width, H = source.height
        let f = Double(W) / Double(analysis.analysisWidth)   // source pixels per analysis pixel
        // Dilate in analysis pixels over the band grown by the radius.
        let radius = Int((dilationOfLongEdge * Double(max(analysis.analysisWidth, analysis.analysisHeight))).rounded())
        let gx0 = glasses.x0 - radius, gy0 = glasses.y0 - radius
        let gw = glasses.width + 2 * radius, gh = glasses.height + 2 * radius
        var plane = FloatImage(width: gw, height: gh, channels: 1)
        for y in 0..<glasses.height { for x in 0..<glasses.width where glasses.mask[y * glasses.width + x] {
            plane.data[(y + radius) * gw + x + radius] = 1
        } }
        let dilated = plane.dilated(threshold: 0.5, radius: radius)
        func masked(sourceX x: Double, sourceY y: Double) -> Bool {
            let ax = Int((x / f).rounded(.down)) - gx0, ay = Int((y / f).rounded(.down)) - gy0
            guard ax >= 0, ay >= 0, ax < gw, ay < gh else { return false }
            return dilated.data[ay * gw + ax] > 0.5
        }
        // The mask's bounding box in source pixels.
        var lo = SIMD2(Int.max, Int.max), hi = SIMD2(Int.min, Int.min)
        for y in 0..<gh { for x in 0..<gw where dilated.data[y * gw + x] > 0.5 {
            lo = SIMD2(min(lo.x, x), min(lo.y, y)); hi = SIMD2(max(hi.x, x), max(hi.y, y))
        } }
        guard lo.x <= hi.x else { return nil }
        let bx0 = max(0, Int(Double(lo.x + gx0) * f)), by0 = max(0, Int(Double(lo.y + gy0) * f))
        let bx1 = min(W, Int((Double(hi.x + gx0 + 1) * f).rounded(.up))), by1 = min(H, Int((Double(hi.y + gy0 + 1) * f).rounded(.up)))
        guard bx1 > bx0, by1 > by0 else { return nil }
        // The context window.
        let extent = max(bx1 - bx0, by1 - by0)
        let side = min(max(Int(Double(extent) * contextFactor), minimumWindow), W, H)
        let cx = Double(bx0 + bx1) / 2, cy = Double(by0 + by1) / 2
        let wx = min(max(Int(cx - Double(side) / 2), 0), W - side), wy = min(max(Int(cy - Double(side) / 2), 0), H - side)
        let window = try RemoveEngine.drawRegion(of: source, x: wx, y: wy, width: side, height: side)
        let n = RemoveEngine.side, scale = Double(side) / Double(n)
        var image = [Float](repeating: 0, count: 3 * n * n), mask = [Float](repeating: 0, count: n * n)
        for my in 0..<n { for mx in 0..<n {
            let sx = (Double(mx) + 0.5) * scale - 0.5, sy = (Double(my) + 0.5) * scale - 0.5
            let rgb = RemoveEngine.bilinear(window, width: side, height: side, x: sx, y: sy)
            for c in 0..<3 { image[c * n * n + my * n + mx] = rgb[c] }
            if masked(sourceX: Double(wx) + sx + 0.5, sourceY: Double(wy) + sy + 0.5) { mask[my * n + mx] = 1 }
        } }
        try Task.checkCancellation()
        let result = try await inpainter.inpaint(image: image, mask: mask, side: n)
        try Task.checkCancellation()
        // Paste back over the mask's box, alpha = the mask feathered by a Gaussian.
        let pw = bx1 - bx0, ph = by1 - by0
        var alpha = FloatImage(width: pw, height: ph, channels: 1)
        for y in 0..<ph { for x in 0..<pw where masked(sourceX: Double(bx0 + x) + 0.5, sourceY: Double(by0 + y) + 0.5) {
            alpha.data[y * pw + x] = 1
        } }
        alpha = alpha.gaussianBlurred(sigma: featherSigma * Float(max(1, f)))
        var rgba = [UInt8](repeating: 0, count: pw * ph * 4)
        for y in 0..<ph { for x in 0..<pw {
            let a = alpha.data[y * pw + x]
            guard a > 0.002 else { continue }
            let mx = (Double(bx0 + x - wx) + 0.5) / scale - 0.5, my = (Double(by0 + y - wy) + 0.5) / scale - 0.5
            let o = (y * pw + x) * 4
            for c in 0..<3 {
                rgba[o + c] = UInt8(min(max(RemoveEngine.bilinearPlane(result, plane: c, side: n, x: mx, y: my) * 255 + 0.5, 0), 255))
            }
            rgba[o + 3] = UInt8(min(max(a * 255 + 0.5, 0), 255))
        } }
        let patch = RemovePatch(x: bx0, y: by0, width: pw, height: ph, sourceWidth: W, sourceHeight: H, rgba: rgba)
        let rect = EditRecipe.Rect(x: Double(bx0) / Double(W), y: Double(by0) / Double(H), width: Double(pw) / Double(W), height: Double(ph) / Double(H))
        return (patch, rect)
    }

    /// Composites a removal patch onto `image` (linear RGB at any render size), blending in sRGB-encoded values as
    /// RemoveEngine.compositeRegion does on RGBA8.
    static func composite(_ patch: RemovePatch, onto image: inout FloatImage) {
        let W = image.width, H = image.height
        let sx = Double(W) / Double(patch.sourceWidth), sy = Double(H) / Double(patch.sourceHeight)
        let x0 = max(Int((Double(patch.x) * sx).rounded(.down)), 0), y0 = max(Int((Double(patch.y) * sy).rounded(.down)), 0)
        let x1 = min(Int((Double(patch.x + patch.width) * sx).rounded(.up)), W)
        let y1 = min(Int((Double(patch.y + patch.height) * sy).rounded(.up)), H)
        guard x1 > x0, y1 > y0 else { return }
        for y in y0..<y1 { for x in x0..<x1 {
            let px = (Double(x) + 0.5) / sx - Double(patch.x) - 0.5, py = (Double(y) + 0.5) / sy - Double(patch.y) - 0.5
            let s = patch.sample(x: px, y: py)
            guard s.w > 0 else { continue }
            let o = image.index(x, y)
            var e = ColourMath.encoded(fromLinear: SIMD3(image.data[o], image.data[o + 1], image.data[o + 2]))
            e = e * Float(1 - s.w) + SIMD3(Float(s.x), Float(s.y), Float(s.z)) * Float(s.w)
            let l = ColourMath.linear(fromEncoded: e)
            image.data[o] = l.x; image.data[o + 1] = l.y; image.data[o + 2] = l.z
        } }
    }
}
