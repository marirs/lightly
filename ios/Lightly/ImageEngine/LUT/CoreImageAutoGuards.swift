import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Image-dependent guards on Core Image's auto proposals (2026-10-06). Each guard answers one measured regression of the
/// unguarded filters on the approved photos (experiments/auto-ci/README.md, per-filter comparison):
///
/// - **CIFaceBalance** turned skin redder (Lab hue 59°→50°, 50°→43°, 46°→42°) by pulling every face toward one target.
///   It now runs only when the measured skin hue lies outside the band where skin plausibly sits (`skinHueBand`), and
///   only as far as that band's edge: a face already in the band is not "corrected".
/// - **CIToneCurve** stretched the black point of photos that already span their range (landscapes darkened, p1 26→7)
///   and lifted upper mid-tones into clipping (sunset 1.2→2.9 %). It runs only when the photo does not already span
///   its range (`spansRange`).
/// - **CIToneCurve and CIHighlightShadowAdjust** (Radius 0 as proposed: per-pixel, baked exactly into the Auto LUT) are
///   then applied together at the largest strength (1, ¾, ½, ¼, 0) that adds no highlight or shadow clipping beyond
///   `clipTolerance`, measured on the proxy.
/// - With a face, the tonal filters may move the skin's lightness by at most 5 L and its chroma by 15 % (the low-key
///   studio portrait was brightened 30→43 L by the unguarded chain).
/// - **CIVibrance** keeps Core Image's amount unless it alone adds clipping (then the same step-down).
///
/// Pure Core Image and Vision, so the same code runs in the app and in the Mac comparison (experiments/auto-ci).
enum CoreImageAutoGuards {
    /// CIELAB hue angle of plausible skin across tones (measured skin clusters roughly 40–60°; a little margin).
    static let skinHueBand: ClosedRange<Double> = 40...62
    /// New clipping allowed: 0.1 percentage points of the pixels.
    static let clipTolerance = 0.001
    /// A photo "spans its range" when its 1st luma percentile is at most 15 % and its 99th at least 85 %.
    static let spanLow = 0.15, spanHigh = 0.85

    struct Stats: Equatable {
        var highlightClip: Double, shadowClip: Double, p1: Double, p99: Double, meanLuma: Double
        var skinHue: Double?, skinChroma: Double?, skinLightness: Double?
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

        if let vibrance = named["CIVibrance"] {
            let amount = (vibrance.value(forKey: "inputAmount") as? NSNumber)?.doubleValue ?? 0
            let t = largestStep { t in
                let f = vibrance.copy() as! CIFilter; f.setValue(amount * t, forKey: "inputAmount")
                return addsNoClipping(apply([f], to: input), base: base, faces: faces, context: context)
            }
            if t > 0 { let f = vibrance.copy() as! CIFilter; f.setValue(amount * t, forKey: "inputAmount"); kept.append(f) }
            notes.append(t == 1 ? "vibrance as proposed" : String(format: "vibrance x%.2f (clipping guard)", t))
        }

        if let balance = named["CIFaceBalance"] {
            if let hue = base.skinHue, !skinHueBand.contains(hue) {
                let edge = hue < skinHueBand.lowerBound ? skinHueBand.lowerBound : skinHueBand.upperBound
                // Largest strength whose skin hue does not pass the band edge, i.e. moves toward it no further.
                var strength = 0.0
                for s in stride(from: 1.0, through: 0.05, by: -0.05) {
                    let f = balance.copy() as! CIFilter; f.setValue(s, forKey: "inputStrength")
                    guard let after = stats(apply(kept + [f], to: input), faces: faces, context: context).skinHue else { continue }
                    if abs(after - edge) <= abs(hue - edge) && (hue < edge ? after <= edge + 1 : after >= edge - 1) { strength = s; break }
                }
                if strength > 0 { let f = balance.copy() as! CIFilter; f.setValue(strength, forKey: "inputStrength"); kept.append(f) }
                notes.append(String(format: "face balance strength %.2f: skin hue %.0f° outside %.0f–%.0f°", strength, hue, skinHueBand.lowerBound, skinHueBand.upperBound))
            } else {
                notes.append(base.skinHue.map { String(format: "face balance not applied: skin hue %.0f° already plausible", $0) } ?? "face balance not applied: no face measured")
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

    private static func keepsSkin(_ image: CIImage, base: Stats, faces: [CGRect], context: CIContext) -> Bool {
        guard !faces.isEmpty, let l0 = base.skinLightness, let c0 = base.skinChroma else { return true }
        let s = stats(image, faces: faces, context: context)
        guard let l1 = s.skinLightness, let c1 = s.skinChroma else { return true }
        return abs(l1 - l0) <= skinLightnessTolerance && abs(c1 / max(c0, 1e-6) - 1) <= skinChromaTolerance
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
        var high = 0, low = 0, sum = 0.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            if max(r, g, b) >= 254 { high += 1 }
            if max(r, g, b) <= 1 { low += 1 }
            let y = (2126 * r + 7152 * g + 722 * b) / 10000
            histogram[min(y, 255)] += 1
            sum += Double(y)
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
        return Stats(highlightClip: Double(high) / n, shadowClip: Double(low) / n, p1: percentile(0.01), p99: percentile(0.99),
                     meanLuma: sum / n / 255, skinHue: skinHue, skinChroma: skinChroma, skinLightness: skinLightness)
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
