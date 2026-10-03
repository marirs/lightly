import Foundation

/// Background › Focus & Blur and Change background (rendering-v2 stages 7 and 8), following the
/// refocus specification in docs/v1/depth-evaluation.md §6 and its executable reference
/// `experiments/depth/refocus.py` (§R1–§R8). CPU implementation using the §R7 latitude: each
/// layer is blurred by gathering at a reduced resolution (radius ≥ 6 px there), then upsampled.
///
/// Contract notes (reported, not resolved here):
/// - rendering-v2.json gives `maxBlurRadius` 0.03 of the long edge; the refocus specification
///   gives 0.035 and marks it [contract]. This port follows the specification (0.035), which is
///   what the reference renders, and records the gap in docs/v1/slice3-ios.md.
/// - Swirl's half-angle: the prose says 6·r·s/diagonal, the reference code uses 12·r·s/diagonal.
///   This port follows the reference code.
enum RefocusRenderer {

    // [contract] constants of §R1–§R4.
    static let maxCoCFractionOfLongSide: Float = 0.035
    static let maxFocusHalfWidth: Float = 0.30
    static let layersPerSide = 8
    static let subjectDepthCompression: Float = 0.5
    static let replacementMinimumGap: Float = 0.10
    static let highlightThreshold: Float = 0.70
    static let highlightGain: Float = 0.85

    struct Parameters: Equatable, Sendable {
        var targetX: Float = 0.5
        var targetY: Float = 0.5
        var blur: Float = 0
        /// "Focus depth": depth of field, the width of the sharp band (T3).
        var focusDepth: Float = 40
        var style: EditRecipe.Focus.Style = .lens
        var bokeh: EditRecipe.Focus.Bokeh = .round
        var styleAmount: Float = 50
        /// Layers per side: 8 for export, 4 allowed for interactive preview (§R7).
        var layersPerSide: Int = RefocusRenderer.layersPerSide
    }

    /// A plane of §R2: linear colour (not premultiplied), coverage, disparity (larger = nearer).
    struct Plane: Sendable {
        var colour: FloatImage
        var alpha: FloatImage
        var disparity: FloatImage
    }

    struct Scene: Sendable {
        var background: Plane
        var subject: Plane?
        /// Median disparity of the subject's interior (for replacement placement).
        var subjectMedian: Float?
        var originalBackgroundMedian: Float
        /// The photo itself while the background is still the photo's own: blur 0 returns it
        /// unchanged (the de-contaminated split is only needed once something is blurred or
        /// replaced). nil after a replacement.
        var original: FloatImage?
    }

    // MARK: - §R2 scene

    /// Splits the photo into a background plane and, with a matte, a subject plane.
    static func buildScene(linear: FloatImage, disparity: FloatImage, matte: FloatImage?) -> Scene {
        let w = linear.width, h = linear.height, long = Float(max(w, h))
        let ones = FloatImage(width: w, height: h, channels: 1, repeating: 1)
        guard let matte else {
            return Scene(background: Plane(colour: linear, alpha: ones, disparity: disparity), subject: nil,
                         subjectMedian: nil, originalBackgroundMedian: median(disparity.data), original: linear)
        }
        // Background colour: exclude a band outside the matte, then fill from what remains.
        let colourBand = matte.dilated(threshold: 0.02, radius: Int((0.004 * long).rounded()))
        let backgroundColour = linear.filled(valid: inverted(colourBand))
        // Background disparity: a wider band, because model depth bleeds across outlines.
        let depthBand = matte.dilated(threshold: 0.02, radius: Int((0.015 * long).rounded()))
        let backgroundDisparity = disparity.filled(valid: inverted(depthBand))
        var outside: [Float] = []
        for i in 0..<depthBand.pixelCount where depthBand.data[i] < 0.5 { outside.append(disparity.data[i]) }

        // Subject disparity: eroded interior, filled outward, compressed toward its median.
        var interior = matte.eroded(threshold: 0.5, radius: Int((0.01 * long).rounded()))
        if interior.data.reduce(0, +) < 50 { interior = matte.dilated(threshold: 0.5, radius: 0) }
        var inside: [Float] = []
        for i in 0..<interior.pixelCount where interior.data[i] > 0.5 { inside.append(disparity.data[i]) }
        let subjectMedian = inside.isEmpty ? 1 : median(inside)
        var subjectDisparity = disparity.filled(valid: interior)
        for i in 0..<subjectDisparity.pixelCount {
            subjectDisparity.data[i] = subjectMedian + subjectDepthCompression * (subjectDisparity.data[i] - subjectMedian)
        }

        // De-contaminated subject colour (I = M·F + (1−M)·B solved where the matte is reliable).
        let solid = matte.dilated(threshold: 0.95, radius: 0)
        let interiorFill = linear.filled(valid: solid)
        var subjectColour = linear
        for i in 0..<linear.pixelCount {
            let m = matte.data[i]
            let reliability = min(max((m - 0.3) / 0.4, 0), 1)
            for c in 0..<3 {
                let solved = (linear.data[i * 3 + c] - (1 - m) * backgroundColour.data[i * 3 + c]) / max(m, 1e-3)
                subjectColour.data[i * 3 + c] = max(reliability * solved + (1 - reliability) * interiorFill.data[i * 3 + c], 0)
            }
        }
        return Scene(background: Plane(colour: backgroundColour, alpha: ones, disparity: backgroundDisparity),
                     subject: Plane(colour: subjectColour, alpha: matte, disparity: subjectDisparity),
                     subjectMedian: subjectMedian,
                     originalBackgroundMedian: outside.isEmpty ? 0 : median(outside), original: linear)
    }

    /// §R2.4: the replacement becomes the background plane, behind the subject. With its own
    /// estimated disparity it keeps its near-to-far structure; otherwise it is a flat plane where
    /// the original background was.
    static func replacingBackground(_ scene: Scene, with replacement: FloatImage, ownDisparity: FloatImage?) -> Scene {
        var scene = scene
        scene.original = nil
        let nearest = max(0, (scene.subjectMedian ?? 1) - replacementMinimumGap)
        var disparity = FloatImage(width: replacement.width, height: replacement.height, channels: 1,
                                   repeating: min(scene.originalBackgroundMedian, nearest))
        if let ownDisparity {
            for i in 0..<disparity.pixelCount { disparity.data[i] = min(max(ownDisparity.data[i], 0), 1) * nearest }
        }
        scene.background = Plane(colour: replacement,
                                 alpha: FloatImage(width: replacement.width, height: replacement.height, channels: 1, repeating: 1),
                                 disparity: disparity)
        return scene
    }

    // MARK: - §R3 focus

    /// Disparity under the tap: median over a small window of the topmost plane there.
    static func focalDisparity(_ scene: Scene, x: Float, y: Float) -> Float {
        let w = scene.background.disparity.width, h = scene.background.disparity.height
        let cx = Int((min(max(x, 0), 1) * Float(w - 1)).rounded(.down)), cy = Int((min(max(y, 0), 1) * Float(h - 1)).rounded(.down))
        var plane = scene.background
        if let subject = scene.subject, subject.alpha.data[cy * w + cx] >= 0.5 { plane = subject }
        let radius = max(2, Int((0.01 * Float(max(w, h))).rounded()))
        var window: [Float] = []
        for yy in max(0, cy - radius)...min(h - 1, cy + radius) {
            for xx in max(0, cx - radius)...min(w - 1, cx + radius) { window.append(plane.disparity.data[yy * w + xx]) }
        }
        return median(window)
    }

    /// The default focus target: the subject's matte centroid, else the image centre.
    static func defaultTarget(matte: FloatImage?) -> (x: Float, y: Float) {
        guard let matte else { return (0.5, 0.5) }
        var sx: Float = 0, sy: Float = 0, total: Float = 0
        for y in 0..<matte.height {
            for x in 0..<matte.width {
                let m = matte.data[y * matte.width + x]
                guard m > 0.5 else { continue }
                sx += Float(x) * m; sy += Float(y) * m; total += m
            }
        }
        guard total > 0 else { return (0.5, 0.5) }
        return (sx / total / Float(max(matte.width - 1, 1)), sy / total / Float(max(matte.height - 1, 1)))
    }

    // MARK: - §R4–§R6 render

    /// Renders the refocused image; returns linear RGB.
    static func render(_ scene: Scene, _ params: Parameters) -> FloatImage {
        let w = scene.background.colour.width, h = scene.background.colour.height
        let radiusMax = min(max(params.blur, 0), 100) / 100 * maxCoCFractionOfLongSide * Float(max(w, h))
        if radiusMax < 0.5 {
            // blur = 0: the photo unchanged, or the subject over its replacement.
            return scene.original ?? composite(scene)
        }
        let halfWidth = maxFocusHalfWidth * pow(min(max(params.focusDepth, 0), 100) / 100, 1.5)
        let focal = focalDisparity(scene, x: params.targetX, y: params.targetY)
        let useHighlights = params.style != .soft
        let k = max(1, params.layersPerSide)
        let step = radiusMax / Float(k)

        let planes = [scene.background] + (scene.subject.map { [$0] } ?? [])
        var behind: [(layer: Int, plane: Int, image: FloatImage)] = []
        var frontSums = planes.map { _ in FloatImage(width: w, height: h, channels: 4) }
        var cocMaps: [FloatImage] = []

        for (planeIndex, plane) in planes.enumerated() {
            let colour = useHighlights ? expandHighlights(plane.colour) : plane.colour
            var coc = FloatImage(width: w, height: h, channels: 1)
            for i in 0..<coc.pixelCount {
                let delta = plane.disparity.data[i] - focal
                let magnitude = min(max((abs(delta) - halfWidth) / max(1 - halfWidth, 1e-6), 0), 1)
                coc.data[i] = (delta > 0 ? 1 : delta < 0 ? -1 : 0) * magnitude * radiusMax
            }
            cocMaps.append(coc)
            for layer in -k...k {
                var premultiplied = FloatImage(width: w, height: h, channels: 4)
                var any = false
                for i in 0..<coc.pixelCount {
                    let weight = max(0, 1 - abs(coc.data[i] / step - Float(layer))) * plane.alpha.data[i]
                    guard weight > 1e-4 else { continue }
                    any = true
                    premultiplied.data[i * 4] = colour.data[i * 3] * weight
                    premultiplied.data[i * 4 + 1] = colour.data[i * 3 + 1] * weight
                    premultiplied.data[i * 4 + 2] = colour.data[i * 3 + 2] * weight
                    premultiplied.data[i * 4 + 3] = weight
                }
                guard any else { continue }
                let blurred = blurLayer(premultiplied, radius: Float(abs(layer)) * step, params: params)
                if layer < 0 {
                    behind.append((layer, planeIndex, blurred))
                } else {
                    for i in 0..<frontSums[planeIndex].data.count { frontSums[planeIndex].data[i] += blurred.data[i] }
                }
            }
        }

        // §R6.1–2: behind the focal band, "over" far to near, then normalise with pull-push.
        var behindColour = FloatImage(width: w, height: h, channels: 3)
        var behindAlpha = FloatImage(width: w, height: h, channels: 1)
        for item in behind.sorted(by: { ($0.layer, $0.plane) < ($1.layer, $1.plane) }) {
            for i in 0..<behindAlpha.pixelCount {
                let a = item.image.data[i * 4 + 3]
                for c in 0..<3 { behindColour.data[i * 3 + c] = item.image.data[i * 4 + c] + (1 - a) * behindColour.data[i * 3 + c] }
                behindAlpha.data[i] = a + (1 - a) * behindAlpha.data[i]
            }
        }
        var result: FloatImage
        if behindAlpha.data.contains(where: { $0 > 0 }) {
            for i in 0..<behindAlpha.pixelCount { behindAlpha.data[i] = min(max(behindAlpha.data[i], 0), 1) }
            result = FloatImage.pullPushFill(premultiplied: behindColour, coverage: behindAlpha)
        } else {
            result = FloatImage(width: w, height: h, channels: 3)
        }
        // §R6.3: focal and in-front layers summed per plane, then background first, subject last.
        for front in frontSums {
            for i in 0..<result.pixelCount {
                let coverage = front.data[i * 4 + 3]
                let overflow = max(coverage, 1)
                let alpha = coverage / overflow
                for c in 0..<3 { result.data[i * 3 + c] = front.data[i * 4 + c] / overflow + (1 - alpha) * result.data[i * 3 + c] }
            }
        }
        if useHighlights { result = compressHighlights(result) }
        if params.style == .soft { result = addGlow(result, cocMaps: cocMaps, scene: scene, params: params, radiusMax: radiusMax) }
        return result
    }

    /// Replacement without blur: subject over the background plane.
    static func composite(_ scene: Scene) -> FloatImage {
        guard let subject = scene.subject else { return scene.background.colour }
        var out = scene.background.colour
        for i in 0..<out.pixelCount {
            let a = subject.alpha.data[i]
            for c in 0..<3 { out.data[i * 3 + c] = subject.colour.data[i * 3 + c] * a + out.data[i * 3 + c] * (1 - a) }
        }
        return out
    }

    // MARK: - §R1 highlights

    static func expandHighlights(_ image: FloatImage) -> FloatImage {
        var out = image
        let t = highlightThreshold, k = highlightGain
        for i in 0..<image.pixelCount {
            let peak = max(image.data[i * 3], image.data[i * 3 + 1], image.data[i * 3 + 2])
            guard peak > t else { continue }
            let u = min(max((peak - t) / (1 - t), 0), 1)
            let expanded = t + (1 - t) * u / (1 - k * u)
            let gain = expanded / max(peak, 1e-6)
            for c in 0..<3 { out.data[i * 3 + c] *= gain }
        }
        return out
    }

    static func compressHighlights(_ image: FloatImage) -> FloatImage {
        var out = image
        let t = highlightThreshold, k = highlightGain
        for i in 0..<image.pixelCount {
            let peak = max(image.data[i * 3], image.data[i * 3 + 1], image.data[i * 3 + 2])
            guard peak > t else { continue }
            let v = max(peak - t, 0) / (1 - t)
            let compressed = t + (1 - t) * v / (1 + k * v)
            let gain = compressed / max(peak, 1e-6)
            for c in 0..<3 { out.data[i * 3 + c] *= gain }
        }
        return out
    }

    // MARK: - §R5 kernels and §R7 reduced-resolution gather

    /// A normalised kernel as (dx, dy, weight) taps in pixels.
    struct Kernel { let taps: [(dx: Float, dy: Float, w: Float)] }

    /// The style's kernel at `radius` px (circumscribed), anti-aliased by 4× supersampling.
    static func kernel(style: EditRecipe.Focus.Style, bokeh: EditRecipe.Focus.Bokeh, radius: Float, styleAmount: Float) -> Kernel {
        switch style {
        case .soft:
            let half = Int((radius * 1.5).rounded(.up)), sigma = radius / 2
            var taps: [(Float, Float, Float)] = []
            for y in -half...half { for x in -half...half {
                let w = exp(-0.5 * (Float(x * x + y * y)) / (sigma * sigma))
                taps.append((Float(x), Float(y), w))
            } }
            return normalised(taps)
        case .motion:
            let theta = (styleAmount * 3.6 - 180) * .pi / 180
            let half = 1.5 * radius
            return shapeKernel(extent: 1.5 * radius) { x, y in
                // y up for the angle convention of the reference.
                let along = x * cos(theta) + (-y) * sin(theta), across = -x * sin(theta) + (-y) * cos(theta)
                return abs(along) <= half && abs(across) <= 0.5
            }
        case .swirl:
            let r = radius * (1 - 0.5 * styleAmount / 100)
            return shapeKernel(extent: r) { x, y in x * x + y * y <= r * r }
        case .lens:
            return shapeKernel(extent: radius) { x, y in
                let u = x / radius, v = -y / radius  // unit radius, y up
                switch bokeh {
                case .round: return u * u + v * v <= 1
                case .hex:
                    let vertices = (0..<6).map { (cos(Float($0) * .pi / 3), sin(Float($0) * .pi / 3)) }
                    return insidePolygon(u, v, vertices)
                case .heart:
                    let hx = u * 1.25, hy = v * 1.25 + 0.15
                    let a = hx * hx + hy * hy - 1
                    return a * a * a - hx * hx * hy * hy * hy <= 0
                case .star:
                    return insideStar(u, v)
                }
            }
        }
    }

    private static func shapeKernel(extent: Float, inside: (Float, Float) -> Bool) -> Kernel {
        let half = Int(extent.rounded(.up))
        var taps: [(Float, Float, Float)] = []
        let ss = 4
        for y in -half...half {
            for x in -half...half {
                var hits = 0
                for sy in 0..<ss { for sx in 0..<ss {
                    let px = Float(x) - 0.5 + (Float(sx) + 0.5) / Float(ss)
                    let py = Float(y) - 0.5 + (Float(sy) + 0.5) / Float(ss)
                    if inside(px, py) { hits += 1 }
                } }
                if hits > 0 { taps.append((Float(x), Float(y), Float(hits))) }
            }
        }
        if taps.isEmpty { taps = [(0, 0, 1)] }
        return normalised(taps)
    }

    private static func normalised(_ taps: [(Float, Float, Float)]) -> Kernel {
        let total = taps.reduce(0) { $0 + $1.2 }
        return Kernel(taps: taps.map { ($0.0, $0.1, $0.2 / total) })
    }

    private static func insidePolygon(_ x: Float, _ y: Float, _ vertices: [(Float, Float)]) -> Bool {
        for i in 0..<vertices.count {
            let (x0, y0) = vertices[i], (x1, y1) = vertices[(i + 1) % vertices.count]
            if (x1 - x0) * (y - y0) - (y1 - y0) * (x - x0) < 0 { return false }
        }
        return true
    }

    private static func insideStar(_ x: Float, _ y: Float, points: Int = 5, inner: Float = 0.45) -> Bool {
        let sector = 2 * Float.pi / Float(points)
        let angle = atan2(y, x) - .pi / 2
        var local = (angle + sector / 2).truncatingRemainder(dividingBy: sector)
        if local < 0 { local += sector }
        local -= sector / 2
        let r = (x * x + y * y).squareRoot()
        let px = r * cos(abs(local)), py = r * sin(abs(local))
        let valleyX = inner * cos(sector / 2), valleyY = inner * sin(sector / 2)
        let cross = (valleyX - 1) * (py - 0) - (valleyY - 0) * (px - 1)
        return cross <= 0
    }

    /// Blurs a premultiplied RGBA layer with the style kernel of `radius`, at the reduced
    /// resolution §R7 allows (largest n with radius/2ⁿ ≥ 6 px), then upsamples.
    static func blurLayer(_ layer: FloatImage, radius: Float, params: Parameters) -> FloatImage {
        guard radius >= 0.5 else { return layer }
        var n = 0
        while radius / Float(1 << (n + 1)) >= 6 { n += 1 }
        let scale = 1 << n
        let small = n == 0 ? layer : layer.resized(width: max(1, layer.width / scale), height: max(1, layer.height / scale))
        let r = radius / Float(scale)
        var blurred = gather(small, kernel(style: params.style, bokeh: params.bokeh, radius: r, styleAmount: params.styleAmount))
        if params.style == .swirl {
            // Rotational blur about the image centre whose half-angle grows with the CoC.
            let s = params.styleAmount / 100
            let diagonal = Float((small.width * small.width + small.height * small.height)).squareRoot()
            let halfAngle = 1.5 * r * s / (0.5 * diagonal) * 4
            blurred = rotationalBlur(blurred, halfAngle: halfAngle)
        }
        return n == 0 ? blurred : blurred.resized(width: layer.width, height: layer.height)
    }

    /// Kernel gather with clamped (≈ reflect) borders.
    static func gather(_ image: FloatImage, _ kernel: Kernel) -> FloatImage {
        guard kernel.taps.count > 1 else { return image }
        var out = FloatImage(width: image.width, height: image.height, channels: image.channels)
        let w = image.width, h = image.height, ch = image.channels
        let taps = kernel.taps.map { (Int($0.dx), Int($0.dy), $0.w) }
        out.data.withUnsafeMutableBufferPointer { dst in
            let base = dst.baseAddress!
            image.data.withUnsafeBufferPointer { src in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    var acc = [Float](repeating: 0, count: ch)
                    for x in 0..<w {
                        for c in 0..<ch { acc[c] = 0 }
                        for (dx, dy, weight) in taps {
                            let sx = min(max(x + dx, 0), w - 1), sy = min(max(y + dy, 0), h - 1)
                            let o = (sy * w + sx) * ch
                            for c in 0..<ch { acc[c] += weight * src[o + c] }
                        }
                        for c in 0..<ch { base[(y * w + x) * ch + c] = acc[c] }
                    }
                }
            }
        }
        return out
    }

    /// Mean of copies rotated about the centre over [−halfAngle, +halfAngle] radians.
    static func rotationalBlur(_ image: FloatImage, halfAngle: Float) -> FloatImage {
        guard halfAngle > 1e-5 else { return image }
        let w = image.width, h = image.height, ch = image.channels
        let arc = halfAngle * Float((w * w + h * h)).squareRoot() / 2
        let samples = min(max(Int((arc / 1.5).rounded(.up)) * 2 + 1, 3), 49)
        let cx = Float(w - 1) / 2, cy = Float(h - 1) / 2
        var out = FloatImage(width: w, height: h, channels: ch)
        let angles = (0..<samples).map { -halfAngle + 2 * halfAngle * Float($0) / Float(samples - 1) }
        out.data.withUnsafeMutableBufferPointer { dst in
            let base = dst.baseAddress!
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    for angle in angles {
                        let dx = Float(x) - cx, dy = Float(y) - cy
                        let sx = cx + dx * cos(angle) - dy * sin(angle), sy = cy + dx * sin(angle) + dy * cos(angle)
                        for c in 0..<ch { base[(y * w + x) * ch + c] += image.sample(sx, sy, c) / Float(samples) }
                    }
                }
            }
        }
        return out
    }

    // MARK: - §R5.2 glow

    static func addGlow(_ result: FloatImage, cocMaps: [FloatImage], scene: Scene, params: Parameters, radiusMax: Float) -> FloatImage {
        let amount = params.styleAmount / 100
        guard amount > 0, radiusMax > 0 else { return result }
        var defocus = FloatImage(width: result.width, height: result.height, channels: 1)
        for i in 0..<defocus.pixelCount {
            var d = abs(cocMaps[0].data[i]) / radiusMax
            if let subject = scene.subject, cocMaps.count > 1 {
                let a = subject.alpha.data[i]
                d = d * (1 - a) + abs(cocMaps[1].data[i]) / radiusMax * a
            }
            defocus.data[i] = d
        }
        var bright = result
        for i in 0..<result.pixelCount {
            let y = 0.2126 * result.data[i * 3] + 0.7152 * result.data[i * 3 + 1] + 0.0722 * result.data[i * 3 + 2]
            let weight = min(max((y - 0.35) / 0.65, 0), 1)
            for c in 0..<3 { bright.data[i * 3 + c] *= weight }
        }
        let glow = blurLarge(bright, sigma: max(1, 0.6 * radiusMax))
        let softDefocus = blurLarge(defocus, sigma: max(1, 0.25 * radiusMax))
        var out = result
        for i in 0..<result.pixelCount {
            for c in 0..<3 {
                let g = min(max(glow.data[i * 3 + c] * 0.9 * amount * softDefocus.data[i], 0), 1)
                out.data[i * 3 + c] = 1 - (1 - result.data[i * 3 + c]) * (1 - g)
            }
        }
        return out
    }

    /// A large Gaussian computed at reduced resolution.
    static func blurLarge(_ image: FloatImage, sigma: Float) -> FloatImage {
        var n = 0
        while sigma / Float(1 << (n + 1)) >= 3 { n += 1 }
        let scale = 1 << n
        let small = n == 0 ? image : image.resized(width: max(1, image.width / scale), height: max(1, image.height / scale))
        let blurred = small.gaussianBlurred(sigma: sigma / Float(scale))
        return n == 0 ? blurred : blurred.resized(width: image.width, height: image.height)
    }

    // MARK: - Helpers

    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func inverted(_ mask: FloatImage) -> FloatImage {
        var out = mask
        for i in 0..<out.pixelCount { out.data[i] = 1 - out.data[i] }
        return out
    }
}
