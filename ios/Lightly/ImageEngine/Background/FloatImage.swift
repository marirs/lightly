import CoreGraphics
import Foundation

/// A float image, interleaved channels, row-major. The Background and Portrait stages work in it
/// (linear light where the specification says so). Sized for previews and capped export working
/// resolutions; every operation is parallel over rows.
struct FloatImage: Sendable {
    let width: Int
    let height: Int
    let channels: Int
    var data: [Float]

    init(width: Int, height: Int, channels: Int, repeating value: Float = 0) {
        self.width = width
        self.height = height
        self.channels = channels
        data = [Float](repeating: value, count: width * height * channels)
    }

    init(width: Int, height: Int, channels: Int, data: [Float]) {
        precondition(data.count == width * height * channels)
        self.width = width
        self.height = height
        self.channels = channels
        self.data = data
    }

    var pixelCount: Int { width * height }
    var longSide: Int { max(width, height) }

    @inline(__always) func index(_ x: Int, _ y: Int) -> Int { (y * width + x) * channels }

    // MARK: - Conversion

    /// RGBA8 sRGB → linear RGB (3 channels).
    static func linear(fromRGBA8 pixels: [UInt8], width: Int, height: Int) -> FloatImage {
        var image = FloatImage(width: width, height: height, channels: 3)
        let table = (0..<256).map { ColourMath.toLinear(Float($0) / 255) }
        image.data.withUnsafeMutableBufferPointer { out in
            let base = out.baseAddress!
            pixels.withUnsafeBufferPointer { src in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for x in 0..<width {
                        let i = y * width + x
                        base[i * 3] = table[Int(src[i * 4])]
                        base[i * 3 + 1] = table[Int(src[i * 4 + 1])]
                        base[i * 3 + 2] = table[Int(src[i * 4 + 2])]
                    }
                }
            }
        }
        return image
    }

    /// Linear RGB → RGBA8 sRGB (clamped, reference rounding).
    func rgba8FromLinear() -> [UInt8] {
        var out = [UInt8](repeating: 255, count: pixelCount * 4)
        out.withUnsafeMutableBufferPointer { dst in
            let base = dst.baseAddress!
            data.withUnsafeBufferPointer { src in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for x in 0..<width {
                        let i = y * width + x
                        for c in 0..<3 {
                            base[i * 4 + c] = DevelopFrameRenderer.encode8(ColourMath.toEncoded(min(max(src[i * channels + c], 0), 1)))
                        }
                    }
                }
            }
        }
        return out
    }

    /// One channel as its own image.
    func channel(_ c: Int) -> FloatImage {
        var out = FloatImage(width: width, height: height, channels: 1)
        for i in 0..<pixelCount { out.data[i] = data[i * channels + c] }
        return out
    }

    // MARK: - Resampling

    /// Area-average downsample (or bilinear upsample) to `newWidth × newHeight`.
    func resized(width newWidth: Int, height newHeight: Int) -> FloatImage {
        if newWidth == width && newHeight == height { return self }
        var out = FloatImage(width: newWidth, height: newHeight, channels: channels)
        let channels = channels, width = width, height = height
        let shrinking = newWidth < width && newHeight < height
        out.data.withUnsafeMutableBufferPointer { dst in
            let base = dst.baseAddress!
            data.withUnsafeBufferPointer { src in
                DispatchQueue.concurrentPerform(iterations: newHeight) { oy in
                    if shrinking {
                        let y0 = oy * height / newHeight, y1 = max((oy + 1) * height / newHeight, y0 + 1)
                        for ox in 0..<newWidth {
                            let x0 = ox * width / newWidth, x1 = max((ox + 1) * width / newWidth, x0 + 1)
                            let count = Float((y1 - y0) * (x1 - x0))
                            for c in 0..<channels {
                                var sum: Float = 0
                                for y in y0..<y1 { for x in x0..<x1 { sum += src[(y * width + x) * channels + c] } }
                                base[(oy * newWidth + ox) * channels + c] = sum / count
                            }
                        }
                    } else {
                        let sy = min(max((Float(oy) + 0.5) * Float(height) / Float(newHeight) - 0.5, 0), Float(height - 1))
                        let iy = Int(sy), fy = sy - Float(iy), iy1 = min(iy + 1, height - 1)
                        for ox in 0..<newWidth {
                            let sx = min(max((Float(ox) + 0.5) * Float(width) / Float(newWidth) - 0.5, 0), Float(width - 1))
                            let ix = Int(sx), fx = sx - Float(ix), ix1 = min(ix + 1, width - 1)
                            for c in 0..<channels {
                                let a = src[(iy * width + ix) * channels + c] * (1 - fx) + src[(iy * width + ix1) * channels + c] * fx
                                let b = src[(iy1 * width + ix) * channels + c] * (1 - fx) + src[(iy1 * width + ix1) * channels + c] * fx
                                base[(oy * newWidth + ox) * channels + c] = a * (1 - fy) + b * fy
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Bilinear sample at continuous pixel coordinates (pixel centres at integers).
    @inline(__always)
    func sample(_ x: Float, _ y: Float, _ c: Int) -> Float {
        let cx = min(max(x, 0), Float(width - 1)), cy = min(max(y, 0), Float(height - 1))
        let ix = Int(cx), iy = Int(cy), ix1 = min(ix + 1, width - 1), iy1 = min(iy + 1, height - 1)
        let fx = cx - Float(ix), fy = cy - Float(iy)
        let a = data[(iy * width + ix) * channels + c] * (1 - fx) + data[(iy * width + ix1) * channels + c] * fx
        let b = data[(iy1 * width + ix) * channels + c] * (1 - fx) + data[(iy1 * width + ix1) * channels + c] * fx
        return a * (1 - fy) + b * fy
    }

    // MARK: - Filters

    /// Mean over a (2r+1)² box, edges clamped. Separable, O(1) per pixel.
    func boxFiltered(radius: Int) -> FloatImage {
        guard radius > 0 else { return self }
        let horizontal = Self.box1D(self, radius: radius, vertical: false)
        return Self.box1D(horizontal, radius: radius, vertical: true)
    }

    private static func box1D(_ image: FloatImage, radius: Int, vertical: Bool) -> FloatImage {
        var out = FloatImage(width: image.width, height: image.height, channels: image.channels)
        let w = image.width, h = image.height, ch = image.channels
        let lines = vertical ? w : h, length = vertical ? h : w
        let norm = 1 / Float(2 * radius + 1)
        out.data.withUnsafeMutableBufferPointer { dst in
            let base = dst.baseAddress!
            image.data.withUnsafeBufferPointer { src in
                DispatchQueue.concurrentPerform(iterations: lines) { line in
                    @inline(__always) func at(_ i: Int) -> Int {
                        let k = min(max(i, 0), length - 1)
                        return vertical ? (k * w + line) * ch : (line * w + k) * ch
                    }
                    for c in 0..<ch {
                        var sum: Float = 0
                        for i in -radius...radius { sum += src[at(i) + c] }
                        for i in 0..<length {
                            base[at(i) + c] = sum * norm
                            sum += src[at(i + radius + 1) + c] - src[at(i - radius) + c]
                        }
                    }
                }
            }
        }
        return out
    }

    /// Separable Gaussian (single plane or every channel), clamped edges.
    func gaussianBlurred(sigma: Float) -> FloatImage {
        guard sigma >= 0.3 else { return self }
        let radius = max(1, Int((3 * sigma).rounded(.up)))
        var kernel = (-radius...radius).map { exp(-0.5 * pow(Float($0) / sigma, 2)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        return Self.convolve1D(Self.convolve1D(self, kernel, vertical: false), kernel, vertical: true)
    }

    static func convolve1D(_ image: FloatImage, _ kernel: [Float], vertical: Bool) -> FloatImage {
        var out = FloatImage(width: image.width, height: image.height, channels: image.channels)
        let w = image.width, h = image.height, ch = image.channels, r = kernel.count / 2
        out.data.withUnsafeMutableBufferPointer { dst in
            let base = dst.baseAddress!
            image.data.withUnsafeBufferPointer { src in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        for c in 0..<ch {
                            var sum: Float = 0
                            for k in -r...r {
                                let sx = vertical ? x : min(max(x + k, 0), w - 1)
                                let sy = vertical ? min(max(y + k, 0), h - 1) : y
                                sum += kernel[k + r] * src[(sy * w + sx) * ch + c]
                            }
                            base[(y * w + x) * ch + c] = sum
                        }
                    }
                }
            }
        }
        return out
    }

    /// Binary dilation of `plane > threshold` by a disc of `radius` (single channel, result 0/1).
    func dilated(threshold: Float, radius: Int) -> FloatImage {
        var binary = FloatImage(width: width, height: height, channels: 1)
        for i in 0..<pixelCount { binary.data[i] = data[i * channels] > threshold ? 1 : 0 }
        guard radius > 0 else { return binary }
        // A box mean above zero marks every pixel within the radius of a set pixel (square
        // structuring element; within a pixel of a disc at these radii).
        let spread = binary.boxFiltered(radius: radius)
        var out = binary
        for i in 0..<pixelCount { out.data[i] = spread.data[i] > 1e-6 ? 1 : 0 }
        return out
    }

    /// Binary erosion of `plane > threshold` by `radius`.
    func eroded(threshold: Float, radius: Int) -> FloatImage {
        var binary = FloatImage(width: width, height: height, channels: 1)
        for i in 0..<pixelCount { binary.data[i] = data[i * channels] > threshold ? 1 : 0 }
        guard radius > 0 else { return binary }
        let spread = binary.boxFiltered(radius: radius)
        var out = binary
        for i in 0..<pixelCount { out.data[i] = spread.data[i] > 1 - 1e-6 ? 1 : 0 }
        return out
    }

    // MARK: - Pull-push fill (§R6, Kraus & Strengert)

    /// Normalised fill of premultiplied colour with coverage: defined everywhere; where coverage
    /// is 0 the colour comes from coarser levels.
    static func pullPushFill(premultiplied: FloatImage, coverage: FloatImage) -> FloatImage {
        var levels: [(FloatImage, FloatImage)] = [(premultiplied, coverage)]
        while min(levels.last!.1.width, levels.last!.1.height) > 4 {
            let (colour, alpha) = levels.last!
            let w = (alpha.width + 1) / 2, h = (alpha.height + 1) / 2
            var downColour = colour.resized(width: w, height: h)
            var downAlpha = alpha.resized(width: w, height: h)
            for i in 0..<downAlpha.pixelCount {
                let a = downAlpha.data[i]
                let boosted = min(a * 4, 1)
                let gain = boosted / max(a, 1e-6)
                for c in 0..<downColour.channels { downColour.data[i * downColour.channels + c] *= gain }
                downAlpha.data[i] = boosted
            }
            levels.append((downColour, downAlpha))
        }
        var (filled, coarseAlpha) = levels.removeLast()
        for i in 0..<filled.pixelCount {
            let a = max(coarseAlpha.data[i], 1e-6)
            for c in 0..<filled.channels { filled.data[i * filled.channels + c] /= a }
        }
        coarseAlpha = FloatImage(width: 1, height: 1, channels: 1)
        for (colour, alpha) in levels.reversed() {
            let up = filled.resized(width: alpha.width, height: alpha.height)
            var next = colour
            for i in 0..<alpha.pixelCount {
                let a = min(max(alpha.data[i], 0), 1)
                for c in 0..<next.channels { next.data[i * next.channels + c] += (1 - a) * up.data[i * up.channels + c] }
            }
            filled = next
        }
        return filled
    }

    /// Keeps `self` where `valid` is 1 and fills elsewhere from the valid pixels.
    func filled(valid: FloatImage) -> FloatImage {
        var premultiplied = self
        for i in 0..<pixelCount { for c in 0..<channels { premultiplied.data[i * channels + c] *= valid.data[i] } }
        let fill = Self.pullPushFill(premultiplied: premultiplied, coverage: valid)
        var out = self
        for i in 0..<pixelCount {
            let v = valid.data[i]
            for c in 0..<channels { out.data[i * channels + c] = data[i * channels + c] * v + fill.data[i * channels + c] * (1 - v) }
        }
        return out
    }

    // MARK: - Guided filter (He et al.)

    static func guidedFilter(guide: FloatImage, source: FloatImage, radius: Int, epsilon: Float) -> FloatImage {
        let meanI = guide.boxFiltered(radius: radius), meanP = source.boxFiltered(radius: radius)
        var ii = guide, ip = guide
        for i in 0..<guide.pixelCount { ii.data[i] = guide.data[i] * guide.data[i]; ip.data[i] = guide.data[i] * source.data[i] }
        let meanII = ii.boxFiltered(radius: radius), meanIP = ip.boxFiltered(radius: radius)
        var a = guide, b = guide
        for i in 0..<guide.pixelCount {
            let variance = meanII.data[i] - meanI.data[i] * meanI.data[i]
            let covariance = meanIP.data[i] - meanI.data[i] * meanP.data[i]
            a.data[i] = covariance / (variance + epsilon)
            b.data[i] = meanP.data[i] - a.data[i] * meanI.data[i]
        }
        let meanA = a.boxFiltered(radius: radius), meanB = b.boxFiltered(radius: radius)
        var out = guide
        for i in 0..<guide.pixelCount { out.data[i] = meanA.data[i] * guide.data[i] + meanB.data[i] }
        return out
    }

    /// Luma of a linear RGB image, encoded (grey guide for the guided filter).
    func encodedGrey() -> FloatImage {
        var out = FloatImage(width: width, height: height, channels: 1)
        for i in 0..<pixelCount {
            let y = 0.2126 * data[i * channels] + 0.7152 * data[i * channels + 1] + 0.0722 * data[i * channels + 2]
            out.data[i] = ColourMath.toEncoded(y)
        }
        return out
    }
}
