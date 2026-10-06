import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Image-dependent guards on Core Image's auto proposals (2026-10-06). Each guard answers one measured regression of the
/// unguarded filters on the approved photos (experiments/auto-ci/README.md, per-filter comparison):
///
/// - **CIFaceBalance** turned skin redder (Lab hue 59°→50°, 50°→43°, 46°→42°) by pulling every face toward one target.
///   It now runs only with independent evidence of a global colour cast (near-neutral pixels away from grey), and only
///   as far as it reduces that cast; skin colour itself is never forced toward a "correct" value.
/// - **CIToneCurve** stretched the black point of photos that already span their range (landscapes darkened, p1 26→7)
///   and lifted upper mid-tones into clipping (sunset 1.2→2.9 %). It runs only when the photo does not already span
///   its range (`spansRange`).
/// - **CIToneCurve** (and CIHighlightShadowAdjust when a caller passes it; the app does not, it is local) are
///   then applied together at the largest strength (1, ¾, ½, ¼, 0) that adds no highlight or shadow clipping beyond
///   `clipTolerance`, measured on the proxy.
/// - With a face, the tonal filters keep the skin's chroma within 15 %. A face at or above its (dark) scene is low-key
///   and keeps its lightness within 5 L (the unguarded chain relit the studio portrait 30→43 L); a face clearly darker
///   than its scene (backlit, underexposed) may be lifted toward the scene's median lightness.
/// - **CIVibrance** keeps Core Image's amount unless it alone adds clipping (then the same step-down).
///
/// Pure Core Image and Vision, so the same code runs in the app and in the Mac comparison (experiments/auto-ci).
enum CoreImageAutoGuards {
    /// CIELAB hue angle of plausible skin across tones (measured skin clusters roughly 40–60°; a little margin).
    /// A global cast counts when the near-neutral pixels' mean CIELAB (a, b) is at least this far from grey.
    static let castThreshold = 3.0
    /// New clipping allowed: 0.1 percentage points of the pixels.
    static let clipTolerance = 0.001
    /// A photo "spans its range" when its 1st luma percentile is at most 15 % and its 99th at least 85 %.
    static let spanLow = 0.15, spanHigh = 0.85

    struct Stats: Equatable {
        var highlightClip: Double, shadowClip: Double, p1: Double, p99: Double, meanLuma: Double
        var skinHue: Double?, skinChroma: Double?, skinLightness: Double?
        /// Mean CIELAB (a, b) of the least-coloured 20 % of mid-tone pixels (20 < L < 90): the photo's neutrals.
        var neutralCast: (a: Double, b: Double)?
        /// Median CIELAB lightness of the whole photo.
        var medianLightness: Double = 50
        static func == (x: Stats, y: Stats) -> Bool { x.highlightClip == y.highlightClip && x.p1 == y.p1 && x.p99 == y.p99 }
        var spansRange: Bool { p1 <= spanLow && p99 >= spanHigh }
    }

    struct Result {
        var filters: [CIFilter]
        var notes: [String]
    }

    static func guarded(_ proposed: [CIFilter], proxy: CGImage, context: CIContext = CIContext(options: [.cacheIntermediates: false])) -> Result {
        let input = CIImage(cgImage: proxy)
        let faces = faceRects(in: proxy)
        let base = stats(input, faces: faces, context: context)
        var notes: [String] = [String(format: "original: p1 %.2f p99 %.2f clip %.2f%%/%.2f%%%@", base.p1, base.p99, base.highlightClip * 100,
                                      base.shadowClip * 100, base.skinHue.map { String(format: ", skin hue %.0f°", $0) } ?? "")]
        let named = Dictionary(proposed.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var kept: [CIFilter] = []

        let hasCast = base.neutralCast.map { hypot($0.a, $0.b) >= castThreshold } ?? false
        if named["CIVibrance"] != nil, hasCast {
            notes.append("vibrance not applied: it would amplify the measured colour cast")
        } else if let vibrance = named["CIVibrance"] {
            let amount = (vibrance.value(forKey: "inputAmount") as? NSNumber)?.doubleValue ?? 0
            let t = largestStep { t in
                let f = vibrance.copy() as! CIFilter; f.setValue(amount * t, forKey: "inputAmount")
                return addsNoClipping(apply([f], to: input), base: base, faces: faces, context: context)
            }
            if t > 0 { let f = vibrance.copy() as! CIFilter; f.setValue(amount * t, forKey: "inputAmount"); kept.append(f) }
            notes.append(t == 1 ? "vibrance as proposed" : String(format: "vibrance x%.2f (clipping guard)", t))
        }

        if let balance = named["CIFaceBalance"] {
            // No fixed "correct skin colour" (2026-10-06 review): beards, make-up, coloured light and several faces make
            // pooled face colour unreliable. Face balance runs only with independent evidence of a global cast: the
            // near-neutral pixels' mean colour. It is applied at the largest strength that reduces that cast without
            // reversing it.
            let cast = base.neutralCast
            if let cast, hypot(cast.a, cast.b) >= castThreshold {
                var strength = 0.0
                for s in [1.0, 0.75, 0.5, 0.25] {
                    let f = balance.copy() as! CIFilter; f.setValue(s, forKey: "inputStrength")
                    guard let after = stats(apply(kept + [f], to: input), faces: faces, context: context).neutralCast else { continue }
                    let before = hypot(cast.a, cast.b), now = hypot(after.a, after.b)
                    let reversed = after.a * cast.a + after.b * cast.b < 0 && now > castThreshold
                    if now < before && !reversed { strength = s; break }
                }
                if strength > 0 { let f = balance.copy() as! CIFilter; f.setValue(strength, forKey: "inputStrength"); kept.append(f) }
                notes.append(String(format: "face balance strength %.2f: neutral cast a %.1f b %.1f", strength, cast.a, cast.b))
            } else {
                notes.append(cast.map { String(format: "face balance not applied: no global cast (neutrals a %.1f b %.1f)", $0.a, $0.b) }
                             ?? "face balance not applied: too few neutral pixels to judge a cast")
            }
        }

        var tonal: [CIFilter] = []
        if let curve = named["CIToneCurve"] {
            if base.spansRange { notes.append("tone curve not applied: the photo already spans its range") } else { tonal.append(curve) }
        }
        if let hsa = named["CIHighlightShadowAdjust"] { tonal.append(hsa) }
        if !tonal.isEmpty {
            let t = largestStep { t in
                let image = apply(kept + tonal.map { scaled($0, by: t) }, to: input)
                return addsNoClipping(image, base: base, faces: faces, context: context) && keepsSkin(image, base: base, faces: faces, context: context)
            }
            kept += t > 0 ? tonal.map { scaled($0, by: t) } : []
            notes.append(String(format: "%@ at strength %.2f (clipping and skin guards)", tonal.map(\.name).joined(separator: " + "), t))
        }
        let result = stats(apply(kept, to: input), faces: faces, context: context)
        notes.append(String(format: "result: p1 %.2f p99 %.2f clip %.2f%%/%.2f%%%@", result.p1, result.p99, result.highlightClip * 100,
                            result.shadowClip * 100, result.skinHue.map { String(format: ", skin hue %.0f°", $0) } ?? ""))
        return Result(filters: kept, notes: notes)
    }

    // MARK: Scaling toward no change

    /// The filter's change scaled by `t` toward none (tone curve points toward y = x; highlight/shadow amounts toward
    /// their neutral values).
    static func scaled(_ filter: CIFilter, by t: Double) -> CIFilter {
        let f = filter.copy() as! CIFilter
        switch f.name {
        case "CIToneCurve":
            for k in 0..<5 {
                let key = "inputPoint\(k)"
                guard let p = f.value(forKey: key) as? CIVector else { continue }
                let x = p.x, y = p.y
                f.setValue(CIVector(x: x, y: x + CGFloat(t) * (y - x)), forKey: key)
            }
        case "CIHighlightShadowAdjust":
            let shadow = (f.value(forKey: "inputShadowAmount") as? NSNumber)?.doubleValue ?? 0
            let highlight = (f.value(forKey: "inputHighlightAmount") as? NSNumber)?.doubleValue ?? 1
            f.setValue(shadow * t, forKey: "inputShadowAmount")
            f.setValue(1 + t * (highlight - 1), forKey: "inputHighlightAmount")
        default: break
        }
        return f
    }

    private static func largestStep(_ ok: (Double) -> Bool) -> Double {
        for t in [1.0, 0.75, 0.5, 0.25] where ok(t) { return t }
        return 0
    }

    private static func addsNoClipping(_ image: CIImage, base: Stats, faces: [CGRect], context: CIContext) -> Bool {
        let s = stats(image, faces: [], context: context)
        return s.highlightClip <= base.highlightClip + clipTolerance && s.shadowClip <= base.shadowClip + clipTolerance
    }

    /// Auto must not relight people: with a face, the tonal filters may move its CIELAB lightness by at most
    /// `skinLightnessTolerance` and its chroma by at most `skinChromaTolerance` (a low-key portrait stays low-key).
    static let skinLightnessTolerance = 5.0, skinChromaTolerance = 0.15
    /// A face this many L below the photo's median lightness reads as backlit or underexposed, not low-key.
    static let backlitMargin = 10.0
    /// A face this many L above the photo's median lightness is a lit subject in a low-key photo.
    static let lowKeyMargin = 15.0
    /// No highlights: the 99th luma percentile below this reads as underexposed.
    static let underexposedP99 = 0.7
    /// The most a backlit or underexposed face may be lifted, in L.
    static let liftLimit = 20.0

    private static func keepsSkin(_ image: CIImage, base: Stats, faces: [CGRect], context: CIContext) -> Bool {
        guard !faces.isEmpty, let l0 = base.skinLightness, let c0 = base.skinChroma else { return true }
        let s = stats(image, faces: faces, context: context)
        guard let l1 = s.skinLightness, let c1 = s.skinChroma else { return true }
        guard abs(c1 / max(c0, 1e-6) - 1) <= skinChromaTolerance else { return false }
        // Low-key: the face is lit well above its (dark) scene; it keeps its lightness. Backlit (the face clearly below
        // its scene) or underexposed (no highlights anywhere): the face may be lifted, by at most `liftLimit` L. Otherwise
        // the face keeps its lightness. Heuristic: an intentionally dark photo with no lit subject reads as underexposed.
        let lowKey = l0 >= base.medianLightness + lowKeyMargin
        let needsLift = !lowKey && (l0 < base.medianLightness - backlitMargin || base.p99 < underexposedP99)
        if needsLift { return l1 >= l0 - skinLightnessTolerance && l1 <= l0 + liftLimit }
        return abs(l1 - l0) <= skinLightnessTolerance
    }

    static func apply(_ filters: [CIFilter], to image: CIImage) -> CIImage {
        filters.reduce(image) { current, filter in
            let f = filter.copy() as! CIFilter
            f.setValue(current, forKey: kCIInputImageKey)
            return f.outputImage ?? current
        }
    }

    // MARK: Measurement

    static func faceRects(in image: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).filter { $0.confidence >= 0.5 }.map(\.boundingBox)
    }

    /// Clipping (any channel ≥ 254 / all channels ≤ 1, of 255), luma percentiles, and the mean CIELAB hue and chroma of
    /// the inner 60 % of each face (Vision's normalised boxes, origin bottom-left).
    static func stats(_ image: CIImage, faces: [CGRect], context: CIContext) -> Stats {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &px, rowBytes: w * 4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var histogram = [Int](repeating: 0, count: 256)
        var lHistogram = [Int](repeating: 0, count: 101)
        var high = 0, low = 0, sum = 0.0
        var neutralSamples: [(c: Double, a: Double, b: Double)] = []
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            if max(r, g, b) >= 254 { high += 1 }
            if max(r, g, b) <= 1 { low += 1 }
            let y = (2126 * r + 7152 * g + 722 * b) / 10000
            histogram[min(y, 255)] += 1
            sum += Double(y)
            if (i / 4) % 4 == 0 {   // every 4th pixel for the CIELAB measures
                let lab = Self.lab(Double(r), Double(g), Double(b))
                lHistogram[min(max(Int(lab.l), 0), 100)] += 1
                if lab.l > 20 && lab.l < 90 { neutralSamples.append((hypot(lab.a, lab.b), lab.a, lab.b)) }
            }
        }
        let n = Double(w * h)
        func percentile(_ q: Double) -> Double {
            var acc = 0
            for (v, c) in histogram.enumerated() { acc += c; if Double(acc) >= q * n { return Double(v) / 255 } }
            return 1
        }
        var skinHue: Double?, skinChroma: Double?, skinLightness: Double?
        if !faces.isEmpty {
            var a = 0.0, b = 0.0, l = 0.0, m = 0.0
            for f in faces {
                // Row 0 of the rendered bitmap is the image's top; Vision's boxes have their origin bottom-left.
                let x0 = Int((f.minX + f.width * 0.2) * Double(w)), x1 = Int((f.maxX - f.width * 0.2) * Double(w))
                let y0 = Int((1 - f.maxY + f.height * 0.2) * Double(h)), y1 = Int((1 - f.minY - f.height * 0.2) * Double(h))
                for y in stride(from: max(0, y0), to: min(h, y1), by: 2) {
                    for x in stride(from: max(0, x0), to: min(w, x1), by: 2) {
                        let i = (y * w + x) * 4
                        let lab = Self.lab(Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
                        a += lab.a; b += lab.b; l += lab.l; m += 1
                    }
                }
            }
            if m > 0 { a /= m; b /= m; skinHue = atan2(b, a) * 180 / .pi; skinChroma = hypot(a, b); skinLightness = l / m }
        }
        var stats = Stats(highlightClip: Double(high) / n, shadowClip: Double(low) / n, p1: percentile(0.01), p99: percentile(0.99),
                          meanLuma: sum / n / 255, skinHue: skinHue, skinChroma: skinChroma, skinLightness: skinLightness)
        let sampled = lHistogram.reduce(0, +)
        // The photo's least-coloured 20 % (mid-tones) stand in for its neutrals: a cast moves them all the same way, which a
        // fixed chroma cut-off missed (a warm cast pushed the neutrals past it).
        if neutralSamples.count >= max(50, sampled / 10) {
            let least = neutralSamples.sorted { $0.c < $1.c }.prefix(neutralSamples.count / 5)
            stats.neutralCast = (least.map(\.a).reduce(0, +) / Double(least.count), least.map(\.b).reduce(0, +) / Double(least.count))
        }
        var acc = 0
        for (l, c) in lHistogram.enumerated() { acc += c; if acc * 2 >= sampled { stats.medianLightness = Double(l); break } }
        return stats
    }

    static func lab(_ r: Double, _ g: Double, _ b: Double) -> (l: Double, a: Double, b: Double) {
        func lin(_ c: Double) -> Double { let c = c / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let R = lin(r), G = lin(g), B = lin(b)
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        let x = f((0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047), y = f(0.2126 * R + 0.7152 * G + 0.0722 * B)
        let z = f((0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883)
        return (116 * y - 16, 500 * (x - y), 200 * (y - z))
    }
}
