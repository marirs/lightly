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
    /// Was 0.0125, the trial's filters (owner report 2026-10-16: it repainted the nose top, eye corners and brows, which
    /// came back smoothed). 0.8 % of the long edge still covers the rims' segmentation fringe (0.6 % left a lower-rim
    /// spot on a tilted face, 0.3 % rim lines).
    static let dilationOfLongEdge = 0.008
    /// The model's context: a square of 1.5 × the mask's extent, at least 256 px (the trial's crop).
    static let contextFactor = 1.5, minimumWindow = 256
    /// Paste-back feather (Gaussian sigma, source pixels), as the trial's GaussianBlur(3).
    static let featherSigma: Float = 3
    /// Glare on the old lenses (owner report 2026-10-15: pale streaks stayed below the new pair). In the lower part of
    /// each lens, pixels brighter than their surroundings (blurred over `glareSigmaOfIrisSpan` × d) by `glareContrast` and brighter
    /// than `glareMinLuminance` are painted out too, except within the eye ellipses (× d around each eye's corners).
    static let glareSigmaOfIrisSpan: Float = 0.08, glareContrast: Float = 0.08, glareMinLuminance: Float = 0.45
    static let keepEyeRadiusX: Float = 0.3, keepEyeRadiusY: Float = 0.14
    /// A lens's area around its eye (× d): glare is looked for only there, not on the cheeks.
    static let lensRadiusX: Float = 0.5, lensRadiusY: Float = 0.42
    /// Where the painted-out area lies on the background (owner report 2026-10-15: a skin-coloured smear past a turned
    /// face's outline), it is filled from the surrounding background instead: normalized convolution of the unmasked
    /// background pixels at growing scales (× d), blended in by the background probability.
    static let backgroundFillSigmasOfIrisSpan: [Float] = [0.05, 0.1, 0.2, 0.4, 0.8]
    static let turnedEyeRatio: Float = 0.8
    static let backgroundFillCellsPerIrisSpan: Float = 24
    /// Glare is not looked for within this × d of the nose (landmarks 1, 4, 5, 195): the nose seen through a turned
    /// face's far lens is bright, and painting it out drew a false nostril (2026-10-15).
    static let glareNoseClearanceOfIrisSpan: Float = 0.35
    #if DEBUG
    /// The last mask (analysis pixels over the band box grown by the radius, with its origin), for review tests.
    nonisolated(unsafe) static var lastMaskForDiagnostics: (FloatImage, Int, Int, Int, Int)?
    #endif

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
        var dilated = plane.dilated(threshold: 0.5, radius: radius)
        try addGlare(to: &dilated, frame: plane, width: gw, height: gh, originX: gx0, originY: gy0, radius: radius,
                     analysis: analysis, source: source, sourcePerAnalysis: f)
        #if DEBUG
        lastMaskForDiagnostics = (dilated, gw, gh, gx0, gy0)
        #endif
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
        let canvas = try await modelFill(x0: bx0, y0: by0, x1: bx1, y1: by1, source: source, inpainter: inpainter, masked: masked)
        // Paste back over the mask's box, alpha = the mask feathered by a Gaussian.
        let pw = bx1 - bx0, ph = by1 - by0
        var alpha = FloatImage(width: pw, height: ph, channels: 1)
        for y in 0..<ph { for x in 0..<pw where masked(sourceX: Double(bx0 + x) + 0.5, sourceY: Double(by0 + y) + 0.5) {
            alpha.data[y * pw + x] = 1
        } }
        alpha = alpha.gaussianBlurred(sigma: featherSigma * Float(max(1, f)))
        let backdrop = try backgroundFill(x0: bx0, y0: by0, width: pw, height: ph, source: source, analysis: analysis,
                                          sourcePerAnalysis: f, masked: masked)
        var rgba = [UInt8](repeating: 0, count: pw * ph * 4)
        for y in 0..<ph { for x in 0..<pw {
            let a = alpha.data[y * pw + x]
            guard a > 0.002 else { continue }
            let o = (y * pw + x) * 4
            let t: Float = backdrop.weight[y * pw + x]
            for c in 0..<3 {
                let lama: Float = canvas.rgb(bx0 + x, by0 + y, c)
                let fill: Float = backdrop.rgb[(y * pw + x) * 3 + c]
                let v: Float = lama * (1 - t) + fill * t
                rgba[o + c] = UInt8(min(max(v * 255 + 0.5, 0), 255))
            }
            rgba[o + 3] = UInt8(min(max(a * 255 + 0.5, 0), 255))
        } }
        try addGrain(&rgba, x0: bx0, y0: by0, width: pw, height: ph, source: source, masked: masked)
        let patch = RemovePatch(x: bx0, y: by0, width: pw, height: ph, sourceWidth: W, sourceHeight: H, rgba: rgba)
        let rect = EditRecipe.Rect(x: Double(bx0) / Double(W), y: Double(by0) / Double(H), width: Double(pw) / Double(W), height: Double(ph) / Double(H))
        return (patch, rect)
    }

    /// The model's fill over the mask's box (sRGB 0…1).
    struct Canvas {
        let x0: Int, y0: Int, width: Int, height: Int
        var data: [Float]   // RGB
        func rgb(_ x: Int, _ y: Int, _ c: Int) -> Float {
            let cx = min(max(x - x0, 0), width - 1), cy = min(max(y - y0, 0), height - 1)
            return data[(cy * width + cx) * 3 + c]
        }
    }

    /// The model's fill over the mask's box: one square window of `contextFactor` × the mask's extent (at least
    /// `minimumWindow`), centred on the box, resized to the model's side. Tiling the mask at full detail was tried
    /// (2026-10-16) and dropped: without the whole face as context the tiles lost the brows and left seams.
    static func modelFill(x0 bx0: Int, y0 by0: Int, x1 bx1: Int, y1 by1: Int, source: CGImage, inpainter: any Inpainting,
                          masked: (Double, Double) -> Bool) async throws -> Canvas {
        let W = source.width, H = source.height, n = RemoveEngine.side
        let extent = max(bx1 - bx0, by1 - by0)
        let side = min(max(Int(Double(extent) * contextFactor), minimumWindow), W, H)
        let cx = Double(bx0 + bx1) / 2, cy = Double(by0 + by1) / 2
        let wx = min(max(Int(cx - Double(side) / 2), 0), W - side), wy = min(max(Int(cy - Double(side) / 2), 0), H - side)
        let window = try RemoveEngine.drawRegion(of: source, x: wx, y: wy, width: side, height: side)
        let scale = Double(side) / Double(n)
        var image = [Float](repeating: 0, count: 3 * n * n), mask = [Float](repeating: 0, count: n * n)
        for my in 0..<n { for mx in 0..<n {
            let sx = (Double(mx) + 0.5) * scale - 0.5, sy = (Double(my) + 0.5) * scale - 0.5
            let rgb = RemoveEngine.bilinear(window, width: side, height: side, x: sx, y: sy)
            for c in 0..<3 { image[c * n * n + my * n + mx] = rgb[c] }
            if masked(Double(wx) + sx + 0.5, Double(wy) + sy + 0.5) { mask[my * n + mx] = 1 }
        } }
        try Task.checkCancellation()
        let result = try await inpainter.inpaint(image: image, mask: mask, side: n)
        try Task.checkCancellation()
        let pw = bx1 - bx0, ph = by1 - by0
        var canvas = Canvas(x0: bx0, y0: by0, width: pw, height: ph, data: [Float](repeating: 0, count: pw * ph * 3))
        for y in 0..<ph { for x in 0..<pw {
            let mx = (Double(bx0 + x - wx) + 0.5) / scale - 0.5, my = (Double(by0 + y - wy) + 0.5) / scale - 0.5
            for c in 0..<3 { canvas.data[(y * pw + x) * 3 + c] = Float(RemoveEngine.bilinearPlane(result, plane: c, side: n, x: mx, y: my)) }
        } }
        return canvas
    }

    /// The model's fill is computed at 512 px and scaled up, so it is smoother than the photo (owner report 2026-10-16:
    /// the nose and cheeks looked flattened). The photo's own fine grain is put back: the luminance high-pass (the
    /// luminance minus its Gaussian blur, σ = `grainSigma`) of the unmasked pixels of the patch box gives its strength
    /// (standard deviation); deterministic white noise, blurred by the same σ and rescaled to that strength, is added
    /// equally to the channels of the masked pixels. Seeded by the box's position, so a patch is always the same.
    static let grainSigma: Float = 0.7

    static func addGrain(_ rgba: inout [UInt8], x0: Int, y0: Int, width pw: Int, height ph: Int, source: CGImage,
                         masked: (Double, Double) -> Bool) throws {
        let pixels = try RemoveEngine.drawRegion(of: source, x: x0, y: y0, width: pw, height: ph)
        var luminance = FloatImage(width: pw, height: ph, channels: 1)
        var isMasked = [Bool](repeating: false, count: pw * ph)
        for i in 0..<(pw * ph) {
            luminance.data[i] = (0.2126 * Float(pixels[i * 4]) + 0.7152 * Float(pixels[i * 4 + 1]) + 0.0722 * Float(pixels[i * 4 + 2])) / 255
            isMasked[i] = masked(Double(x0 + i % pw) + 0.5, Double(y0 + i / pw) + 0.5)
        }
        let low = luminance.gaussianBlurred(sigma: grainSigma)
        var sum: Double = 0, sumSquares: Double = 0, count = 0
        for i in 0..<(pw * ph) where !isMasked[i] {
            let v = Double(luminance.data[i] - low.data[i]); sum += v; sumSquares += v * v; count += 1
        }
        guard count > 64 else { return }
        let mean = sum / Double(count)
        let strength = Float(max(0, sumSquares / Double(count) - mean * mean).squareRoot())
        guard strength > 0.001 else { return }
        var noise = FloatImage(width: pw, height: ph, channels: 1)
        var state = UInt64(truncatingIfNeeded: x0 &* 73_856_093 ^ y0 &* 19_349_663) | 1
        for i in 0..<(pw * ph) {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            noise.data[i] = Float(state % 10_000) / 10_000 - 0.5
        }
        noise = noise.gaussianBlurred(sigma: grainSigma)
        var noiseSquares: Double = 0
        for v in noise.data { noiseSquares += Double(v * v) }
        let gain = strength / Float(max((noiseSquares / Double(pw * ph)).squareRoot(), 1e-6))
        for i in 0..<(pw * ph) where isMasked[i] && rgba[i * 4 + 3] > 0 {
            let delta = noise.data[i] * gain * 255
            for c in 0..<3 { rgba[i * 4 + c] = UInt8(min(max(Float(rgba[i * 4 + c]) + delta, 0), 255).rounded()) }
        }
    }

    /// Adds the old lenses' glare to `mask` (analysis pixels over the band box grown by `radius`): pixels in the lower
    /// half of each lens ellipse (`lensRadiusX`, `lensRadiusY`, in the eye line's frame), outside the eye ellipses and
    /// clear of the nose, brighter than their blurred surroundings by `glareContrast` and than `glareMinLuminance`;
    /// dilated by half the radius.
    static func addGlare(to mask: inout FloatImage, frame: FloatImage, width w: Int, height h: Int, originX: Int, originY: Int,
                         radius: Int, analysis: FaceSunglassesAnalysis, source: CGImage, sourcePerAnalysis f: Double) throws {
        // Luminance at each analysis pixel's centre, from the source.
        let sx0 = max(0, Int(Double(originX) * f)), sy0 = max(0, Int(Double(originY) * f))
        let sx1 = min(source.width, Int((Double(originX + w) * f).rounded(.up))), sy1 = min(source.height, Int((Double(originY + h) * f).rounded(.up)))
        guard sx1 > sx0, sy1 > sy0 else { return }
        // Only inside the old frame (owner report 2026-10-16: shiny skin below the old lenses, on the cheeks and nose,
        // was taken for glare and smoothed away): pixels the frame encloses, its mask closed by twice the radius
        // (segmented rims have gaps), unreachable from the box's border.
        let closed = frame.dilated(threshold: 0.5, radius: radius * 2)
        var outside = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
        while let i = stack.popLast() {
            guard !outside[i], closed.data[i] < 0.5 else { continue }
            outside[i] = true
            let x = i % w, y = i / w
            if x > 0 { stack.append(i - 1) }; if x < w - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - w) }; if y < h - 1 { stack.append(i + w) }
        }
        let pixels = try RemoveEngine.drawRegion(of: source, x: sx0, y: sy0, width: sx1 - sx0, height: sy1 - sy0)
        var luminance = FloatImage(width: w, height: h, channels: 1)
        for y in 0..<h { for x in 0..<w {
            let px = min(max(Int((Double(x + originX) + 0.5) * f) - sx0, 0), sx1 - sx0 - 1)
            let py = min(max(Int((Double(y + originY) + 0.5) * f) - sy0, 0), sy1 - sy0 - 1)
            let o = (py * (sx1 - sx0) + px) * 4
            luminance.data[y * w + x] = (0.2126 * Float(pixels[o]) + 0.7152 * Float(pixels[o + 1]) + 0.0722 * Float(pixels[o + 2])) / 255
        } }
        let d = analysis.irisSpan
        let surround = luminance.gaussianBlurred(sigma: max(1, glareSigmaOfIrisSpan * d))
        let L = analysis.landmarks
        let eyes = [(L[33] + L[133]) / 2, (L[362] + L[263]) / 2]
        var glare = FloatImage(width: w, height: h, channels: 1)
        // The eye line's frame, so the lens and eye ellipses turn with a tilted head.
        let ux = simd_normalize(SIMD2(L[263].x - L[33].x, L[263].y - L[33].y)), vy = SIMD2(-ux.y, ux.x)
        func within(_ p: SIMD2<Float>, _ e: SIMD3<Float>, _ rx: Float, _ ry: Float) -> Bool {
            let q = p - SIMD2(e.x, e.y)
            let a = simd_dot(q, ux) / (rx * d), b = simd_dot(q, vy) / (ry * d)
            return a * a + b * b <= 1
        }
        for y in 0..<h { for x in 0..<w where mask.data[y * w + x] < 0.5 && !outside[y * w + x] {
            let i = y * w + x
            guard luminance.data[i] > glareMinLuminance, luminance.data[i] - surround.data[i] > glareContrast else { continue }
            let point = SIMD2(Float(x + originX) + 0.5, Float(y + originY) + 0.5)
            // The lower part of the lens only (glare runs down from the eye; above it the brows and lids are bright).
            let below = eyes.contains { simd_dot(point - SIMD2($0.x, $0.y), vy) > 0 }
            let nearNose = [1, 4, 5, 195].contains { simd_distance(point, SIMD2(L[$0].x, L[$0].y)) < glareNoseClearanceOfIrisSpan * d }
            let inLens = below && !nearNose && eyes.contains { within(point, $0, lensRadiusX, lensRadiusY) }
            let nearEye = eyes.contains { within(point, $0, keepEyeRadiusX, keepEyeRadiusY) }
            if inLens && !nearEye { glare.data[i] = 1 }
        } }
        // As wide as the frame mask: the paste-back feather would fade a thinner area to half strength.
        let grown = glare.dilated(threshold: 0.5, radius: max(1, radius / 2))
        for i in 0..<(w * h) where grown.data[i] > 0.5 { mask.data[i] = 1 }
    }

    /// The background behind the patch box (source pixels): for each pixel, the unmasked background pixels around it
    /// averaged by normalized convolution at the smallest scale that reaches some; `weight` is how much it replaces the
    /// model's fill (0 off the background or outside the mask).
    static func backgroundFill(x0: Int, y0: Int, width pw: Int, height ph: Int, source: CGImage, analysis: FaceSunglassesAnalysis,
                               sourcePerAnalysis f: Double, masked: (Double, Double) -> Bool) throws -> (rgb: [Float], weight: [Float]) {
        let d = analysis.irisSpan * Float(f)
        let margin = Int((backgroundFillSigmasOfIrisSpan.last! * d * 2).rounded(.up))
        let ex0 = max(0, x0 - margin), ey0 = max(0, y0 - margin)
        let ex1 = min(source.width, x0 + pw + margin), ey1 = min(source.height, y0 + ph + margin)
        let ew = ex1 - ex0, eh = ey1 - ey0
        let pixels = try RemoveEngine.drawRegion(of: source, x: ex0, y: ey0, width: ew, height: eh)
        // The segmenter counts glasses as part of the person, so on the far side of a turned face, glasses past the
        // face's outline (outside the face mesh's hull) count as background too: background + accessory there. Only
        // the far side: on the near side the arm runs over hair and the ear, which are not background.
        let hull = faceHull(analysis)
        // The far side of a turned face: its eye (corner to corner) is at most `turnedEyeRatio` of the other's width.
        let L = analysis.landmarks
        func p(_ i: Int) -> SIMD2<Float> { SIMD2(L[i].x, L[i].y) }
        let leftEye = simd_distance(p(33), p(133)), rightEye = simd_distance(p(362), p(263))
        let u = simd_normalize(p(263) - p(33)), centre = (p(468) + p(473)) / 2
        let farSign: Float = rightEye < turnedEyeRatio * leftEye ? 1 : (leftEye < turnedEyeRatio * rightEye ? -1 : 0)
        // (real background, background counting the far side's glasses): colours are taken only from the first; the
        // second decides where the fill replaces the model's.
        func background(_ x: Int, _ y: Int) -> (real: Float, target: Float) {
            let ax = Float((Double(x) + 0.5) / f), ay = Float((Double(y) + 0.5) / f)
            let b = analysis.background.sample(x: ax, y: ay) ?? 0
            let point = SIMD2(ax, ay)
            guard farSign != 0, !inside(hull, point), simd_dot(point - centre, u) * farSign > 0 else { return (b, b) }
            return (b, min(1, b + (analysis.accessory.sample(x: ax, y: ay) ?? 0)))
        }
        // Which patch pixels may take the fill, at full resolution (cheap: one map sample each).
        var rgb = [Float](repeating: 0, count: pw * ph * 3), weight = [Float](repeating: 0, count: pw * ph)
        var pending: [(j: Int, target: Float)] = []
        for j in 0..<(pw * ph) {
            let x = x0 + j % pw, y = y0 + j / pw
            guard masked(Double(x) + 0.5, Double(y) + 0.5) else { continue }
            let target = background(x, y).target
            if target > 0.3 { pending.append((j, target)) }
        }
        guard !pending.isEmpty else { return (rgb, weight) }
        // The normalized convolution runs on a grid of `q` × `q` source-pixel cells, about `backgroundFillCellsPerIrisSpan`
        // cells per d: at full resolution its widest blur (0.8 d) took most of a minute on a mid-range phone (2026-10-15).
        let q = max(1, Int(d / backgroundFillCellsPerIrisSpan))
        let cw = (ew + q - 1) / q, chh = (eh + q - 1) / q
        var weighted = FloatImage(width: cw, height: chh, channels: 3), weights = FloatImage(width: cw, height: chh, channels: 1)
        for y in 0..<eh { for x in 0..<ew {
            guard background(ex0 + x, ey0 + y).real > 0.5, !masked(Double(ex0 + x) + 0.5, Double(ey0 + y) + 0.5) else { continue }
            let i = y * ew + x, c = (y / q) * cw + x / q
            weights.data[c] += 1
            for k in 0..<3 { weighted.data[c * 3 + k] += Float(pixels[i * 4 + k]) / 255 }
        } }
        func sampleCell(_ plane: FloatImage, _ channel: Int, _ gx: Float, _ gy: Float) -> Float {
            let fx = min(max(gx - 0.5, 0), Float(cw - 1)), fy = min(max(gy - 0.5, 0), Float(chh - 1))
            let ix = Int(fx), iy = Int(fy), jx = min(ix + 1, cw - 1), jy = min(iy + 1, chh - 1)
            let tx = fx - Float(ix), ty = fy - Float(iy)
            func at(_ x: Int, _ y: Int) -> Float { plane.data[(y * cw + x) * plane.channels + channel] }
            let top = at(ix, iy) * (1 - tx) + at(jx, iy) * tx, bottom = at(ix, jy) * (1 - tx) + at(jx, jy) * tx
            return top * (1 - ty) + bottom * ty
        }
        for sigma in backgroundFillSigmasOfIrisSpan where !pending.isEmpty {
            let s = max(0.5, sigma * d / Float(q))
            let num = weighted.gaussianBlurred(sigma: s), den = weights.gaussianBlurred(sigma: s)
            pending = pending.filter { item in
                let gx = (Float(x0 - ex0 + item.j % pw) + 0.5) / Float(q), gy = (Float(y0 - ey0 + item.j / pw) + 0.5) / Float(q)
                let n = sampleCell(den, 0, gx, gy)
                guard n > 0.05 * Float(q * q) else { return true }   // cells hold pixel counts
                for k in 0..<3 { rgb[item.j * 3 + k] = sampleCell(num, k, gx, gy) / n }
                weight[item.j] = min(max((item.target - 0.3) / 0.4, 0), 1)
                return false
            }
        }
        return (rgb, weight)
    }

    /// The convex hull of the face mesh's 468 landmarks (analysis pixels), counter-clockwise in image coordinates.
    static func faceHull(_ analysis: FaceSunglassesAnalysis) -> [SIMD2<Float>] {
        let points: [SIMD2<Float>] = analysis.landmarks.prefix(468).map { SIMD2<Float>($0.x, $0.y) }
            .sorted { (a: SIMD2<Float>, b: SIMD2<Float>) -> Bool in a.x != b.x ? a.x < b.x : a.y < b.y }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            let u: SIMD2<Float> = a - o, v: SIMD2<Float> = b - o
            return u.x * v.y - u.y * v.x
        }
        var lower: [SIMD2<Float>] = [], upper: [SIMD2<Float>] = []
        for p in points { while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }; lower.append(p) }
        for p in points.reversed() { while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }; upper.append(p) }
        return Array(lower.dropLast() + upper.dropLast())
    }

    static func inside(_ hull: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        guard hull.count >= 3 else { return false }
        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let u: SIMD2<Float> = b - a, v: SIMD2<Float> = p - a
            if u.x * v.y - u.y * v.x < 0 { return false }
        }
        return true
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
