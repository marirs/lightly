import Foundation

/// Enhance (1.3): the pipeline's image maths, moved verbatim from the measured harness
/// (experiments/enhance-2026-11-12/phone/EnhancePipelineTests.swift, steps 2c-2g) and line for line with the Mac copy
/// (phone_pipeline.py). Float, interleaved HWC, 0-255. Do not "tidy" the arithmetic: every loop computes each value
/// with the same float operations in the same order as the Mac copy, and phone/mathcheck/run.sh checks that bit for
/// bit. Faster loops are welcome only when they keep that property (README step 2d).
enum EnhanceMaths {

    struct Image {
        let w: Int, h: Int, c: Int
        var d: [Float]
        init(w: Int, h: Int, c: Int, d: [Float]? = nil) { self.w = w; self.h = h; self.c = c; self.d = d ?? [Float](repeating: 0, count: w * h * c) }
    }

    struct Detection {
        let box: [Double]
        let score: Double
        let five: [SIMD2<Double>]
    }

    /// PIL bilinear weights (antialiased when shrinking): per output pixel, the first tap and its weights.
    static func resampleTaps(_ inSize: Int, _ outSize: Int) -> [(first: Int, weights: [Float])] {
        let scale = Double(inSize) / Double(outSize), filterScale = max(scale, 1)
        return (0..<outSize).map { x in
            let centre = (Double(x) + 0.5) * scale
            let lo = max(Int(centre - filterScale + 0.5), 0), hi = min(Int(centre + filterScale + 0.5), inSize)
            let w = (lo..<hi).map { max(0, 1 - abs((Double($0) - centre + 0.5) / filterScale)) }
            let sum = w.reduce(0, +)
            return (lo, w.map { sum > 0 ? Float($0 / sum) : 0 })
        }
    }

    static func resize(_ image: Image, _ width: Int, _ height: Int) -> Image {
        let tx = resampleTaps(image.w, width), ty = resampleTaps(image.h, height), c = image.c
        var horizontal = [Float](repeating: 0, count: width * image.h * c)
        image.d.withUnsafeBufferPointer { src in horizontal.withUnsafeMutableBufferPointer { dst in
            parallelFor(image.h) { y in for x in 0..<width {
                let (first, weights) = tx[x]
                for ch in 0..<c {
                    var sum: Float = 0
                    for i in 0..<weights.count { sum += weights[i] * src[(y * image.w + first + i) * c + ch] }
                    dst[(y * width + x) * c + ch] = sum
                }
            } }
        } }
        var out = Image(w: width, h: height, c: c)
        horizontal.withUnsafeBufferPointer { src in out.d.withUnsafeMutableBufferPointer { dst in
            parallelFor(height) { y in
                let (first, weights) = ty[y]
                for x in 0..<width { for ch in 0..<c {
                    var sum: Float = 0
                    for i in 0..<weights.count { sum += weights[i] * src[((first + i) * width + x) * c + ch] }
                    dst[(y * width + x) * c + ch] = sum
                } }
            }
        } }
        return out
    }

    /// Output pixel (u, v) samples the source at m (2 x 3, row-major) applied to (u, v); outside taps take `border`.
    static func warpBilinear(_ source: Image, _ m: [Double], _ width: Int, _ height: Int, border: [Float]) -> Image {
        let c = source.c
        var out = Image(w: width, h: height, c: c)
        source.d.withUnsafeBufferPointer { src in out.d.withUnsafeMutableBufferPointer { dst in
            parallelFor(height) { v in for u in 0..<width {
                let x = m[0] * Double(u) + m[1] * Double(v) + m[2], y = m[3] * Double(u) + m[4] * Double(v) + m[5]
                let x0 = Int(floor(x)), y0 = Int(floor(y))
                let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
                for ch in 0..<c {
                    func tap(_ yy: Int, _ xx: Int) -> Float {
                        xx >= 0 && xx < source.w && yy >= 0 && yy < source.h ? src[(yy * source.w + xx) * c + ch] : border[ch]
                    }
                    let top = tap(y0, x0) * (1 - fx) + tap(y0, x0 + 1) * fx
                    let bottom = tap(y0 + 1, x0) * (1 - fx) + tap(y0 + 1, x0 + 1) * fx
                    dst[(v * width + u) * c + ch] = top * (1 - fy) + bottom * fy
                }
            } }
        } }
        return out
    }

    static func gaussianKernel(_ size: Int, _ sigmaIn: Double) -> [Float] {
        let fixed: [Int: [Float]] = [1: [1], 3: [0.25, 0.5, 0.25], 5: [0.0625, 0.25, 0.375, 0.25, 0.0625],
                                     7: [0.03125, 0.109375, 0.21875, 0.28125, 0.21875, 0.109375, 0.03125]]
        if sigmaIn <= 0, let kernel = fixed[size] { return kernel }
        let sigma = sigmaIn <= 0 ? 0.3 * (Double(size - 1) * 0.5 - 1) + 0.8 : sigmaIn
        let k = (0..<size).map { i -> Double in let x = Double(i) - Double(size - 1) / 2; return exp(-(x * x) / (2 * sigma * sigma)) }
        let sum = k.reduce(0, +)
        return k.map { Float($0 / sum) }
    }

    static func reflect101(_ index: Int, _ size: Int) -> Int {
        if size == 1 { return 0 }
        let period = 2 * size - 2
        let i = ((index % period) + period) % period
        return i < size ? i : period - i
    }

    static func reflect(_ index: Int, _ size: Int) -> Int {
        let period = 2 * size
        let i = ((index % period) + period) % period
        return i < size ? i : period - 1 - i
    }

    // Step 2d speed-ups. Every loop below gives bit-identical results to the step 2c loops: each output value is computed
    // with the same float operations in the same order, only on all cores and with exact shortcuts (see each function).

    /// body(index) for every index on all cores; callers only write disjoint outputs, so the order does not matter.
    static func parallelFor(_ count: Int, _ body: (Int) -> Void) {
        DispatchQueue.concurrentPerform(iterations: count, execute: body)
    }

    /// w x h plane -> h x w plane, in 32 x 32 blocks for the cache.
    static func transpose(_ plane: [Float], _ w: Int, _ h: Int) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        let block = 32
        plane.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { dst in
            parallelFor((h + block - 1) / block) { by in
                let y0 = by * block, y1 = min(y0 + block, h)
                var x0 = 0
                while x0 < w {
                    let x1 = min(x0 + block, w)
                    for y in y0..<y1 { for x in x0..<x1 { dst[x * h + y] = src[y * w + x] } }
                    x0 = x1
                }
            }
        } }
        return out
    }

    /// One axis of separableSum: out[y, x] = sum of weights[i] * plane[y, border(x + i - offset)], accumulated from 0 in
    /// tap order (step 2c's loop). Shortcut: when all taps of an inside window hold one value c, the terms are all
    /// weights[i] * c, so the same accumulation is done once per row and value and reused - the masks are mostly flat 0
    /// and 1 areas. Equal floats are the same value (0 and -0 both give +0 sums), so the result does not change.
    static func weightedRows(_ plane: [Float], _ w: Int, _ h: Int, _ weights: [Float], offset: Int, border: (Int, Int) -> Int) -> [Float] {
        let taps = weights.count
        let columns = (0..<(w * taps)).map { border($0 / taps + $0 % taps - offset, w) }
        var out = [Float](repeating: 0, count: w * h)
        plane.withUnsafeBufferPointer { src in weights.withUnsafeBufferPointer { wt in columns.withUnsafeBufferPointer { col in
            out.withUnsafeMutableBufferPointer { dst in
                parallelFor(h) { y in
                    let row = y * w
                    var runEnd = [Int](repeating: w - 1, count: w)   // last index of the run of equal values that starts at x
                    if w > 1 { for x in stride(from: w - 2, through: 0, by: -1) { runEnd[x] = src[row + x + 1] == src[row + x] ? runEnd[x + 1] : x } }
                    var flatValue = Float.nan                        // NaN equals nothing, so the first flat window computes its sum
                    var flatSum: Float = 0
                    for x in 0..<w {
                        let first = x - offset
                        if first >= 0 && first + taps <= w && runEnd[first] >= first + taps - 1 {
                            let value = src[row + first]
                            if value != flatValue {
                                var sum: Float = 0
                                for i in 0..<taps { sum += wt[i] * value }
                                flatValue = value
                                flatSum = sum
                            }
                            dst[row + x] = flatSum
                        } else {
                            var sum: Float = 0
                            let base = x * taps
                            for i in 0..<taps { sum += wt[i] * src[row + col[base + i]] }
                            dst[row + x] = sum
                        }
                    }
                }
            }
        } } }
        return out
    }

    /// Separable weighted sum along x then y; the y pass runs as an x pass on the transposed plane (same sums).
    static func separableSum(_ plane: [Float], _ w: Int, _ h: Int, _ weights: [Float], offset: Int, border: (Int, Int) -> Int) -> [Float] {
        let horizontal = weightedRows(plane, w, h, weights, offset: offset, border: border)
        let vertical = weightedRows(transpose(horizontal, w, h), h, w, weights, offset: offset, border: border)
        return transpose(vertical, h, w)
    }

    static func gaussianBlur(_ plane: [Float], _ w: Int, _ h: Int, size: Int, sigma: Double) -> [Float] {
        separableSum(plane, w, h, gaussianKernel(size, sigma), offset: size / 2, border: reflect101)
    }

    /// Per row, the minimum over [x - anchor, x - anchor + size - 1] with positions outside the row ignored. van Herk /
    /// Gil-Werman: block-wise prefix and suffix minima, three comparisons per pixel whatever the size (step 2c looped over
    /// the whole window). A minimum does not depend on the order it is taken in, so the result is the same.
    static func minRows(_ plane: [Float], _ w: Int, _ h: Int, size: Int) -> [Float] {
        let anchor = size / 2, n = w + size - 1             // padded row: index j holds x = j - anchor, +inf outside
        var out = [Float](repeating: 0, count: w * h)
        plane.withUnsafeBufferPointer { src in out.withUnsafeMutableBufferPointer { dst in
            parallelFor(h) { y in
                let row = y * w
                var prefix = [Float](repeating: 0, count: n), suffix = [Float](repeating: 0, count: n)
                for j in 0..<n {
                    let x = j - anchor
                    let value = x >= 0 && x < w ? src[row + x] : Float.infinity
                    prefix[j] = j % size == 0 ? value : min(prefix[j - 1], value)
                    suffix[j] = value
                }
                if n > 1 { for j in stride(from: n - 2, through: 0, by: -1) where j % size != size - 1 { suffix[j] = min(suffix[j + 1], suffix[j]) } }
                for x in 0..<w { dst[row + x] = min(suffix[x], prefix[x + size - 1]) }
            }
        } }
        return out
    }

    /// OpenCV erode, size x size rectangle, anchor size / 2; outside the plane counts as the maximum.
    static func erode(_ plane: [Float], _ w: Int, _ h: Int, size: Int) -> [Float] {
        if size <= 1 { return plane }
        let horizontal = minRows(plane, w, h, size: size)
        return transpose(minRows(transpose(horizontal, w, h), h, w, size: size), h, w)
    }

    static func boxMeanReflect(_ plane: [Float], _ w: Int, _ h: Int, radius: Int) -> [Float] {
        let n = 2 * radius + 1
        return separableSum(plane, w, h, [Float](repeating: 1 / Float(n), count: n), offset: radius, border: reflect)
    }

    static let srgbToXYZ: [Double] = [0.412453, 0.357580, 0.180423, 0.212671, 0.715160, 0.072169, 0.019334, 0.119193, 0.950227]
    static let white: [Double] = [0.950456, 1.0, 1.088754]
    static let xyzToSRGB: [Double] = {
        let m = srgbToXYZ
        let (a, b, c, d, e, f, g, h, i) = (m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return [(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
                (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
                (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]
    }()

    static func rgbToLab(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        func linear(_ v: Float) -> Double { v <= 0.04045 ? Double(v / 12.92) : pow((Double(v) + 0.055) / 1.055, 2.4) }
        let lr = linear(r), lg = linear(g), lb = linear(b)
        let x = (srgbToXYZ[0] * lr + srgbToXYZ[1] * lg + srgbToXYZ[2] * lb) / white[0]
        let y = (srgbToXYZ[3] * lr + srgbToXYZ[4] * lg + srgbToXYZ[5] * lb) / white[1]
        let z = (srgbToXYZ[6] * lr + srgbToXYZ[7] * lg + srgbToXYZ[8] * lb) / white[2]
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        return (Float(y > 0.008856 ? 116 * f(y) - 16 : 903.3 * y), Float(500 * (f(x) - f(y))), Float(200 * (f(y) - f(z))))
    }

    static func labToRGB(_ l: Float, _ a: Float, _ b: Float) -> (Float, Float, Float) {
        let l = Double(l)
        let fy = l > 8 ? (l + 16) / 116 : l / 903.3 * 7.787 + 16.0 / 116
        let y = (l > 8 ? fy * fy * fy : l / 903.3) * white[1]
        func inverse(_ f: Double) -> Double { f > 0.206893 ? f * f * f : (f - 16.0 / 116) / 7.787 }
        let x = inverse(fy + Double(a) / 500) * white[0], z = inverse(fy - Double(b) / 200) * white[2]
        func channel(_ row: Int) -> Float {
            let linear = min(max(xyzToSRGB[row * 3] * x + xyzToSRGB[row * 3 + 1] * y + xyzToSRGB[row * 3 + 2] * z, 0), 1)
            return Float(linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055)
        }
        return (channel(0), channel(1), channel(2))
    }

    /// colour_from_original.py: the restored face's lightness, the original crop's colour through a guided filter.
    static func originalColour(_ restored: Image, _ original: Image, radius: Int = 8, epsilon: Float = 1e-3) -> Image {
        let w = restored.w, h = restored.h, n = w * h
        var restoredLab = [Float](repeating: 0, count: n * 3), originalLab = [Float](repeating: 0, count: n * 3)
        func unit(_ v: Float) -> Float { min(max(v, 0), 255) / 255 }
        restoredLab.withUnsafeMutableBufferPointer { rl in originalLab.withUnsafeMutableBufferPointer { ol in
            parallelFor(n) { i in
                let r = rgbToLab(unit(restored.d[i * 3]), unit(restored.d[i * 3 + 1]), unit(restored.d[i * 3 + 2]))
                rl[i * 3] = r.0; rl[i * 3 + 1] = r.1; rl[i * 3 + 2] = r.2
                let o = rgbToLab(unit(original.d[i * 3]), unit(original.d[i * 3 + 1]), unit(original.d[i * 3 + 2]))
                ol[i * 3] = o.0; ol[i * 3 + 1] = o.1; ol[i * 3 + 2] = o.2
            }
        } }
        let guide = (0..<n).map { restoredLab[$0 * 3] / 100 }
        let meanGuide = boxMeanReflect(guide, w, h, radius: radius)
        let guideSquared = boxMeanReflect(guide.map { $0 * $0 }, w, h, radius: radius)
        let variance = (0..<n).map { guideSquared[$0] - meanGuide[$0] * meanGuide[$0] }
        let channels = (0..<2).map { index -> [Float] in
            let source = (0..<n).map { originalLab[$0 * 3 + 1 + index] }
            let meanSource = boxMeanReflect(source, w, h, radius: radius)
            let product = boxMeanReflect((0..<n).map { guide[$0] * source[$0] }, w, h, radius: radius)
            let slope = (0..<n).map { (product[$0] - meanGuide[$0] * meanSource[$0]) / (variance[$0] + epsilon) }
            let offset = (0..<n).map { meanSource[$0] - slope[$0] * meanGuide[$0] }
            let meanSlope = boxMeanReflect(slope, w, h, radius: radius), meanOffset = boxMeanReflect(offset, w, h, radius: radius)
            return (0..<n).map { meanSlope[$0] * guide[$0] + meanOffset[$0] }
        }
        var out = Image(w: w, h: h, c: 3)
        out.d.withUnsafeMutableBufferPointer { dst in
            parallelFor(n) { i in
                let (r, g, b) = labToRGB(restoredLab[i * 3], channels[0][i], channels[1][i])
                dst[i * 3] = min(max(r, 0), 1) * 255; dst[i * 3 + 1] = min(max(g, 0), 1) * 255; dst[i * 3 + 2] = min(max(b, 0), 1) * 255
            }
        }
        return out
    }

    /// CodeFormer's is_gray(threshold 10) on the 8-bit photo.
    static func isGrey(_ rgb: Image) -> Bool {
        let n = rgb.w * rgb.h
        func variance(_ a: Int, _ b: Int) -> Double {
            var sum = 0.0, squares = 0.0
            for i in 0..<n { let d = Double(rgb.d[i * 3 + a] - rgb.d[i * 3 + b]); sum += d; squares += d * d }
            let mean = sum / Double(n)
            return squares / Double(n) - mean * mean
        }
        return (variance(0, 1) + variance(1, 2) + variance(2, 0)) / 3 <= 10
    }

    /// CodeFormer's bgr2gray + adain_npy for grey photos.
    static func greyLike(_ restored: Image, _ crop: Image) -> Image {
        let n = restored.w * restored.h
        let grey = (0..<n).map { 0.2989 * Double(restored.d[$0 * 3]) + 0.5870 * Double(restored.d[$0 * 3 + 1]) + 0.1140 * Double(restored.d[$0 * 3 + 2]) }
        let greyMean = grey.reduce(0, +) / Double(n)
        let greyStd = sqrt(grey.reduce(0) { $0 + ($1 - greyMean) * ($1 - greyMean) } / Double(n) + 1e-5)
        var out = Image(w: restored.w, h: restored.h, c: 3)
        for ch in 0..<3 {
            var sum = 0.0
            for i in 0..<n { sum += Double(crop.d[i * 3 + ch]) }
            let mean = sum / Double(n)
            var squares = 0.0
            for i in 0..<n { let d = Double(crop.d[i * 3 + ch]) - mean; squares += d * d }
            let std = sqrt(squares / Double(n) + 1e-5)
            for i in 0..<n { out.d[i * 3 + ch] = Float((grey[i] - greyMean) / greyStd * std + mean) }
        }
        return out
    }

    /// Pixels not reachable from outside through non-face pixels (4-connected) become face.
    static func fillHoles(_ face: [Bool], _ w: Int, _ h: Int) -> [Bool] {
        var outside = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        func visit(_ i: Int) { if !face[i] && !outside[i] { outside[i] = true; stack.append(i) } }
        for x in 0..<w { visit(x); visit((h - 1) * w + x) }
        for y in 0..<h { visit(y * w); visit(y * w + w - 1) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if y > 0 { visit(i - w) }
            if y < h - 1 { visit(i + w) }
            if x > 0 { visit(i - 1) }
            if x < w - 1 { visit(i + 1) }
        }
        return outside.map { !$0 }
    }

    /// Least-squares similarity x' = a x - b y + tx, y' = b x + a y + ty (photo -> face), row-major 2 x 3.
    static func similarity(_ points: [SIMD2<Double>], _ template: [SIMD2<Double>]) -> [Double] {
        var ata = [[Double]](repeating: [0, 0, 0, 0], count: 4), atb = [Double](repeating: 0, count: 4)
        for (p, t) in zip(points, template) {
            let rows: [[Double]] = [[p.x, -p.y, 1, 0], [p.y, p.x, 0, 1]], values = [t.x, t.y]
            for r in 0..<2 { for i in 0..<4 {
                atb[i] += rows[r][i] * values[r]
                for j in 0..<4 { ata[i][j] += rows[r][i] * rows[r][j] }
            } }
        }
        var a = (0..<4).map { ata[$0] + [atb[$0]] }
        for col in 0..<4 {
            let pivot = (col..<4).max { abs(a[$0][col]) < abs(a[$1][col]) }!
            a.swapAt(col, pivot)
            for r in 0..<4 where r != col {
                let f = a[r][col] / a[col][col]
                for c in col..<5 { a[r][c] -= f * a[col][c] }
            }
        }
        let s = (0..<4).map { a[$0][4] / a[$0][$0] }
        return [s[0], -s[1], s[2], s[1], s[0], s[3]]
    }

    static func invertAffine(_ m: [Double]) -> [Double] {
        let det = m[0] * m[4] - m[1] * m[3]
        let a = m[4] / det, b = -m[1] / det, d = -m[3] / det, e = m[0] / det
        return [a, b, -(a * m[2] + b * m[5]), d, e, -(d * m[2] + e * m[5])]
    }

    static func iou(_ a: [Double], _ b: [Double]) -> Double {
        let ix = max(0, min(a[2], b[2]) - max(a[0], b[0])), iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
        let inter = ix * iy
        let union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
        return union > 0 ? inter / union : 0
    }

    /// RetinaFace PriorBox for a square canvas, canvas pixels: centre x, centre y, w, h per prior.
    static func priors(_ canvas: Int) -> [Float] {
        var out: [Float] = []
        for (step, sizes) in [(8, [16, 32]), (16, [64, 128]), (32, [256, 512])] {
            let cells = Int(ceil(Double(canvas) / Double(step)))
            for i in 0..<cells { for j in 0..<cells { for size in sizes {
                out += [(Float(j) + 0.5) * Float(step), (Float(i) + 0.5) * Float(step), Float(size), Float(size)]
            } } }
        }
        return out
    }

    static func decodeDetections(loc: [Float], score: [Float], landmarks: [Float], priors p: [Float], scale: Double) -> [Detection] {
        let candidates = score.indices.filter { score[$0] > 0.8 }
        let boxes = candidates.map { i -> [Double] in
            let px = Double(p[i * 4]), py = Double(p[i * 4 + 1]), pw = Double(p[i * 4 + 2]), ph = Double(p[i * 4 + 3])
            let cx = px + Double(loc[i * 4]) * 0.1 * pw, cy = py + Double(loc[i * 4 + 1]) * 0.1 * ph
            let w = pw * exp(Double(loc[i * 4 + 2]) * 0.2), h = ph * exp(Double(loc[i * 4 + 3]) * 0.2)
            return [(cx - w / 2) / scale, (cy - h / 2) / scale, (cx + w / 2) / scale, (cy + h / 2) / scale]
        }
        // Highest score first (stable), then greedy NMS as torchvision.ops.nms.
        var order = candidates.indices.sorted { score[candidates[$0]] > score[candidates[$1]] }
        var found: [Detection] = []
        while !order.isEmpty {
            let best = order.removeFirst()
            order.removeAll { iou(boxes[best], boxes[$0]) > 0.4 }
            let i = candidates[best]
            let five = (0..<5).map { k -> SIMD2<Double> in
                [(Double(p[i * 4]) + Double(landmarks[i * 10 + k * 2]) * 0.1 * Double(p[i * 4 + 2])) / scale,
                 (Double(p[i * 4 + 1]) + Double(landmarks[i * 10 + k * 2 + 1]) * 0.1 * Double(p[i * 4 + 3])) / scale]
            }
            let gap = five[0] - five[1]
            if (gap.x * gap.x + gap.y * gap.y).squareRoot() >= 5 { found.append(Detection(box: boxes[best], score: Double(score[i]), five: five)) }
        }
        return found
    }

    /// phone_pipeline.tile_windows: per axis (kept start, kept length, window start). The fewest `tile` px windows that
    /// overlap by at least 2 x pad, spread evenly; each overlap is split at its middle. A side no longer than a
    /// tile is one window whose reads past the photo are mirrored in (mirrorIndex).
    static func tileWindows(_ size: Int, _ tile: Int, _ pad: Int) -> [(Int, Int, Int)] {
        // A side no longer than a tile is one window from 0; its reads past the photo are mirrored in (mirrorIndex).
        if size <= tile { return [(0, size, 0)] }
        let step = tile - 2 * pad, n = (size - tile + step - 1) / step + 1
        let starts = (0..<n).map { Int((Double($0) * Double(size - tile) / Double(n - 1)).rounded(.toNearestOrEven)) }   // Python round
        let cuts = [0] + (0..<(n - 1)).map { (starts[$0] + tile + starts[$0 + 1]) / 2 } + [size]
        return (0..<n).map { (cuts[$0], cuts[$0 + 1] - cuts[$0], starts[$0]) }
    }

    /// phone_pipeline.mirror_index: reflect without repeating the edge pixel, as often as needed; identity inside.
    static func mirrorIndex(_ i: Int, _ size: Int) -> Int {
        if size == 1 { return 0 }
        let period = 2 * (size - 1), j = i % period
        return j >= size ? period - j : j
    }

    /// export_art_classifier.five_views_uint8 geometry with this file's resize, rounded to uint8.
    static func fiveViews(_ rgb: Image) -> [Image] {
        let whole = resize(rgb, 224, 224)
        let (lw, lh) = rgb.w <= rgb.h ? (448, Int(448 * Double(rgb.h) / Double(rgb.w))) : (Int(448 * Double(rgb.w) / Double(rgb.h)), 448)
        let large = resize(rgb, lw, lh)
        func pyRound(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }   // Python's round()
        let corners = [((lw - 224) / 2, (lh - 224) / 2), ((lw - 224) / 2, pyRound(Double(lh) * 0.15)),
                       (max(0, pyRound(Double(lw) * 0.2)), (lh - 224) / 2), (max(0, pyRound(Double(lw) * 0.8) - 224), (lh - 224) / 2)]
        var views = [whole] + corners.map { x0, y0 -> Image in
            var view = Image(w: 224, h: 224, c: 3)
            for y in 0..<224 { for x in 0..<224 { for c in 0..<3 { view.d[(y * 224 + x) * 3 + c] = large.d[((y0 + y) * lw + x0 + x) * 3 + c] } } }
            return view
        }
        for v in views.indices { for i in views[v].d.indices { views[v].d[i] = min(max(views[v].d[i].rounded(.toNearestOrEven), 0), 255) } }
        return views
    }

    /// Blend one restored face into the 2x image in place; toFace is the photo -> face similarity.
    static func pasteFace(_ image: inout Image, _ restored: Image, _ faceMask: [Float], _ toFace: [Double]) {
        var inverse = invertAffine(toFace).map { $0 * 2 }
        inverse[2] += 1; inverse[5] += 1                                   // CodeFormer's back-alignment offset, 0.5 x scale
        let outputToFace = invertAffine(inverse)
        let corners: [(Double, Double)] = [(0, 0), (512, 0), (0, 512), (512, 512)]
        let xs = corners.map { inverse[0] * $0.0 + inverse[1] * $0.1 + inverse[2] }
        let ys = corners.map { inverse[3] * $0.0 + inverse[4] * $0.1 + inverse[5] }
        let x0 = max(Int(floor(xs.min()!)) - 2, 0), y0 = max(Int(floor(ys.min()!)) - 2, 0)
        let x1 = min(Int(ceil(xs.max()!)) + 3, image.w), y1 = min(Int(ceil(ys.max()!)) + 3, image.h)
        guard x1 > x0, y1 > y0 else { return }
        var shift = outputToFace
        shift[2] += shift[0] * Double(x0) + shift[1] * Double(y0)
        shift[5] += shift[3] * Double(x0) + shift[4] * Double(y0)
        let rw = x1 - x0, rh = y1 - y0
        var square = warpBilinear(Image(w: 512, h: 512, c: 1, d: [Float](repeating: 1, count: 512 * 512)), shift, rw, rh, border: [0]).d
        square = erode(square, rw, rh, size: 4)
        let edge = Int(square.reduce(0.0) { $0 + Double($1) }.squareRoot()) / 20
        let softSquare = gaussianBlur(erode(square, rw, rh, size: edge * 2), rw, rh, size: edge * 2 + 1, sigma: 0)
        let parse = warpBilinear(Image(w: 512, h: 512, c: 1, d: faceMask), shift, rw, rh, border: [0]).d
        let pasted = warpBilinear(restored, shift, rw, rh, border: [0, 0, 0])
        let imageWidth = image.w
        image.d.withUnsafeMutableBufferPointer { dst in
            parallelFor(rh) { v in for u in 0..<rw {
                let i = v * rw + u, soft = min(parse[i], softSquare[i])
                for c in 0..<3 {
                    let at = ((y0 + v) * imageWidth + x0 + u) * 3 + c
                    dst[at] = soft * (pasted.d[i * 3 + c] * square[i]) + (1 - soft) * dst[at]
                }
            } }
        }
    }
}
