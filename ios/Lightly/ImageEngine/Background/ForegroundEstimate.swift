import Foundation

/// background.replace's subject colour (rendering-v2 revision 5): the foreground colour F behind a soft matte
/// edge, Germer et al., "Fast multi-level foreground estimation" (2020), exactly as pymatting's
/// `estimate_foreground_ml` and the contract reference `experiments/depth/refocus.py estimate_foreground`
/// (Float, Gauss-Seidel in row-major order, nearest-neighbour level resizing). Golden-checked against
/// shared/fixtures/rendering `foreground`.
///
/// Why: where the matte is soft (hair), the observed pixel is a mix of subject and old background; compositing it
/// over a replacement kept the old background's colour (a red wall through hair).
enum ForegroundEstimate {
    static let regularization: Float = 1e-5
    static let gradientWeight: Float = 1
    static let smallIterations = 10
    static let bigIterations = 2
    static let smallSize = 32

    /// F (interleaved linear RGB, clipped to [0, 1]) of `image` (linear RGB) given `alpha` (one channel).
    static func estimate(_ image: FloatImage, alpha: FloatImage) -> FloatImage {
        precondition(image.channels == 3 && alpha.channels == 1 && image.width == alpha.width && image.height == alpha.height)
        let w0 = image.width, h0 = image.height
        var fMean = [Float](repeating: 0, count: 3), bMean = [Float](repeating: 0, count: 3)
        var fCount = 0, bCount = 0
        for p in 0..<(w0 * h0) {
            let a = alpha.data[p]
            if a > 0.9 { for c in 0..<3 { fMean[c] += image.data[p * 3 + c] }; fCount += 1 }
            if a < 0.1 { for c in 0..<3 { bMean[c] += image.data[p * 3 + c] }; bCount += 1 }
        }
        for c in 0..<3 { fMean[c] /= Float(fCount) + 1e-5; bMean[c] /= Float(bCount) + 1e-5 }
        var fPrev = FloatImage(width: 1, height: 1, channels: 3, data: fMean)
        var bPrev = FloatImage(width: 1, height: 1, channels: 3, data: bMean)
        let levels = Int(ceil(log2(Double(max(w0, h0)))))
        let dx = [-1, 1, 0, 0], dy = [0, 0, -1, 1]
        var bf = [Float](repeating: 0, count: 3), bb = [Float](repeating: 0, count: 3)
        for level in 0...levels {
            let w = Int(pow(Double(w0), Double(level) / Double(levels)).rounded())
            let h = Int(pow(Double(h0), Double(level) / Double(levels)).rounded())
            let img = nearest(image, width: w, height: h)
            let a = nearest(alpha, width: w, height: h)
            var f = nearest(fPrev, width: w, height: h)
            var b = nearest(bPrev, width: w, height: h)
            let iterations = (w <= smallSize && h <= smallSize) ? smallIterations : bigIterations
            for _ in 0..<iterations {
                for y in 0..<h {
                    for x in 0..<w {
                        let p = y * w + x
                        let a0 = a.data[p], a1 = 1 - a0
                        var a00 = a0 * a0
                        let a01 = a0 * a1
                        var a11 = a1 * a1
                        for c in 0..<3 { bf[c] = a0 * img.data[p * 3 + c]; bb[c] = a1 * img.data[p * 3 + c] }
                        for d in 0..<4 {
                            let x2 = min(max(x + dx[d], 0), w - 1), y2 = min(max(y + dy[d], 0), h - 1)
                            let q = y2 * w + x2
                            let da = regularization + gradientWeight * abs(a0 - a.data[q])
                            a00 += da
                            a11 += da
                            for c in 0..<3 { bf[c] += da * f.data[q * 3 + c]; bb[c] += da * b.data[q * 3 + c] }
                        }
                        let inv = 1 / (a00 * a11 - a01 * a01)
                        for c in 0..<3 {
                            f.data[p * 3 + c] = min(max(inv * a11 * bf[c] - inv * a01 * bb[c], 0), 1)
                            b.data[p * 3 + c] = min(max(-inv * a01 * bf[c] + inv * a00 * bb[c], 0), 1)
                        }
                    }
                }
            }
            fPrev = f
            bPrev = b
        }
        return fPrev
    }

    private static func nearest(_ src: FloatImage, width: Int, height: Int) -> FloatImage {
        var out = FloatImage(width: width, height: height, channels: src.channels)
        for y in 0..<height {
            let sy = min(src.height - 1, y * src.height / height)
            for x in 0..<width {
                let sx = min(src.width - 1, x * src.width / width)
                for c in 0..<src.channels { out.data[(y * width + x) * src.channels + c] = src.data[(sy * src.width + sx) * src.channels + c] }
            }
        }
        return out
    }
}
