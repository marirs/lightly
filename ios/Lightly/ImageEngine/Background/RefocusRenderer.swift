import Foundation

/// Background › Focus & Blur and Change background (rendering-v2 stages 7 and 8), following the
/// refocus specification in docs/v1/depth-evaluation.md §6 and its executable reference
/// `experiments/depth/refocus.py` (§R1–§R8). CPU implementation using the §R7 latitude: each
/// layer is blurred by gathering at a reduced resolution (radius ≥ 6 px there), then upsampled.
///
/// Rendering-v2 revision 1 (docs/v1/contract-fixes-1.md): R_max 0.06 of the long edge,
/// h = 0.5·focusDepth/100, CoC scaled by max(d_f, 1 − d_f) − h, the subject plane kept sharp when
/// the focus is on it, and pull-push to 1×1. DevelopModel refuses a contract whose focus
/// constants differ from these. Kernels are applied as convolutions with reflect borders, as the
/// reference does. Swirl's half-angle follows the reference code (12·r·s/diagonal).
enum RefocusRenderer {

    // [contract] constants of §R1–§R4.
    static let maxCoCFractionOfLongSide: Float = 0.06
    static let focusHalfWidthPerUnit: Float = 0.5
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
        /// The stored focal disparity (`1 − depth.focusDepth`); nil resolves the target (§R3, G4).
        var focalOverride: Float?
        /// nil: decided by the tap (M(target) ≥ 0.5). true for a null recipe target with a subject.
        var subjectFocus: Bool?
        /// R_max at Blur 100 as a fraction of the image's long side; nil: the contract's 0.06.
        /// The editor sets it from the displayed photo so the on-screen strength is the prototype's.
        var maxRadiusFraction: Float?
    }

    /// Owner ruling (contract revision 3): the prototype blurs the displayed photo with CSS
    /// `blur(blur/9 px)`, the same in points on every device. Measured on the native renderer
    /// (contract-fixes-1 §1: σ = 0.0133 of the long edge at Blur 55 with R_max = 0.06 of it), the
    /// fitted Gaussian σ is 0.403 × R_max, so R_max at Blur 100 is 100 / 9 / 0.403 = 27.57 pt on
    /// screen. Depth shaping, styles and the subject rule are unchanged; only this scale moves.
    static let sigmaPerMaxRadius: Float = 0.0133 / (0.55 * 0.06)
    static let maxRadiusPointsAtBlur100: Float = 100 / 9 / sigmaPerMaxRadius

    /// R_max as a fraction of the source's long side for a photo displayed `displayLongEdgePoints`
    /// long, whose frame (after Edit's geometry) is `frameLongPixels` of a `sourceLongPixels` source.
    static func maxRadiusFraction(displayLongEdgePoints: Double, frameLongPixels: Int, sourceLongPixels: Int) -> Float {
        maxRadiusPointsAtBlur100 * Float(frameLongPixels) / Float(max(sourceLongPixels, 1)) / Float(max(displayLongEdgePoints, 1))
    }

    static func halfWidth(focusDepth: Float) -> Float {
        focusHalfWidthPerUnit * min(max(focusDepth, 0), 100) / 100
    }

    static func radiusMax(blur: Float, longSide: Int, fraction: Float? = nil) -> Float {
        min(max(blur, 0), 100) / 100 * (fraction ?? maxCoCFractionOfLongSide) * Float(longSide)
    }

    /// S = max(d_f, 1 − d_f): where Blur reaches R_max (§R4, revision 1).
    static func defocusRange(focal: Float) -> Float { max(focal, 1 - focal) }

    /// Signed CoC in px (§R4): > 0 in front of the focal band, < 0 behind it.
    @inline(__always)
    static func signedCoC(disparity: Float, focal: Float, halfWidth: Float, radiusMax: Float) -> Float {
        let delta = disparity - focal
        let span = max(defocusRange(focal: focal) - halfWidth, 1e-6)
        let magnitude = min(max((abs(delta) - halfWidth) / span, 0), 1)
        return (delta > 0 ? 1 : delta < 0 ? -1 : 0) * magnitude * radiusMax
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
    /// `includeColour: false` builds only the disparity planes (the colour planes are `linear`
    /// unchanged), for resolving the focal plane of a tap.
    static func buildScene(linear: FloatImage, disparity: FloatImage, matte: FloatImage?, includeColour: Bool = true) -> Scene {
        let w = linear.width, h = linear.height, long = Float(max(w, h))
        let clippedMatte = matte.map { m -> FloatImage in
            var clipped = m
            for i in 0..<clipped.data.count { clipped.data[i] = min(max(clipped.data[i], 0), 1) }
            return clipped
        }
        let ones = FloatImage(width: w, height: h, channels: 1, repeating: 1)
        guard let matte = clippedMatte else {
            return Scene(background: Plane(colour: linear, alpha: ones, disparity: disparity), subject: nil,
                         subjectMedian: nil, originalBackgroundMedian: median(disparity.data), original: linear)
        }
        // Background colour: exclude a band outside the matte, then fill from what remains.
        let backgroundColour = includeColour
            ? linear.filled(valid: inverted(ellipseMorphology(matte, threshold: 0.02, radius: roundHalfEven(0.004 * long), dilate: true)))
            : linear
        // Background disparity: a wider band, because model depth bleeds across outlines.
        let depthBand = ellipseMorphology(matte, threshold: 0.02, radius: roundHalfEven(0.015 * long), dilate: true)
        let backgroundDisparity = disparity.filled(valid: inverted(depthBand))
        var outside: [Float] = []
        for i in 0..<depthBand.pixelCount where depthBand.data[i] < 0.5 { outside.append(disparity.data[i]) }

        // Subject disparity: eroded interior, filled outward, compressed toward its median.
        var interior = ellipseMorphology(matte, threshold: 0.5, radius: roundHalfEven(0.01 * long), dilate: false)
        if interior.data.reduce(0, +) < 50 { interior = ellipseMorphology(matte, threshold: 0.5, radius: 0, dilate: true) }
        var inside: [Float] = []
        for i in 0..<interior.pixelCount where interior.data[i] > 0.5 { inside.append(disparity.data[i]) }
        let subjectMedian = inside.isEmpty ? 1 : median(inside)
        var subjectDisparity = disparity.filled(valid: interior)
        for i in 0..<subjectDisparity.pixelCount {
            subjectDisparity.data[i] = subjectMedian + subjectDepthCompression * (subjectDisparity.data[i] - subjectMedian)
        }

        guard includeColour else {
            return Scene(background: Plane(colour: linear, alpha: ones, disparity: backgroundDisparity),
                         subject: Plane(colour: linear, alpha: matte, disparity: subjectDisparity),
                         subjectMedian: subjectMedian,
                         originalBackgroundMedian: outside.isEmpty ? 0 : median(outside), original: nil)
        }
        // De-contaminated subject colour (I = M·F + (1−M)·B solved where the matte is reliable).
        let solid = ellipseMorphology(matte, threshold: 0.95, radius: 0, dilate: true)
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

    private static func tapPixel(_ scene: Scene, x: Float, y: Float) -> (Int, Int) {
        let w = scene.background.disparity.width, h = scene.background.disparity.height
        return (Int((min(max(x, 0), 1) * Float(w - 1)).rounded(.down)), Int((min(max(y, 0), 1) * Float(h - 1)).rounded(.down)))
    }

    /// True when the tap lands on the subject plane (M(tap) ≥ 0.5), the topmost plane there (§R3).
    static func focusIsOnSubject(_ scene: Scene, x: Float, y: Float) -> Bool {
        guard let subject = scene.subject else { return false }
        let (cx, cy) = tapPixel(scene, x: x, y: y)
        return subject.alpha.data[cy * subject.alpha.width + cx] >= 0.5
    }

    /// Disparity under the tap: median over a small window of the topmost plane there.
    static func focalDisparity(_ scene: Scene, x: Float, y: Float) -> Float {
        let w = scene.background.disparity.width, h = scene.background.disparity.height
        let (cx, cy) = tapPixel(scene, x: x, y: y)
        var plane = scene.background
        if let subject = scene.subject, focusIsOnSubject(scene, x: x, y: y) { plane = subject }
        let radius = max(2, roundHalfEven(0.01 * Float(max(w, h))))
        var window: [Float] = []
        for yy in max(0, cy - radius)...min(h - 1, cy + radius) {
            for xx in max(0, cx - radius)...min(w - 1, cx + radius) { window.append(plane.disparity.data[yy * w + xx]) }
        }
        return median(window)
    }

    /// The focal disparity a tap resolves to (§R3) from the photo's depth and matte, for storing as
    /// `depth.focusDepth = 1 − d_f` (revision 1, G4). Runs on the analysis-resolution maps.
    static func focalDisparityAtTap(disparity: FloatImage, matte: FloatImage?, x: Float, y: Float) -> Float {
        let placeholder = FloatImage(width: disparity.width, height: disparity.height, channels: 3)
        let resizedMatte = matte?.resized(width: disparity.width, height: disparity.height)
        let scene = buildScene(linear: placeholder, disparity: disparity, matte: resizedMatte, includeColour: false)
        return focalDisparity(scene, x: x, y: y)
    }

    /// The default focus target with no tap: the centre of the first usable face when it lies on
    /// the subject (the approved screens focus on the face, prototype `ph.target`), else the
    /// subject's matte centroid, else the image centre.
    static func defaultTarget(matte: FloatImage?, faces: [DetectedFace]) -> (x: Float, y: Float) {
        if let matte, let face = faces.first(where: \.isUsable) {
            let x = Float(face.box.x + face.box.width / 2), y = Float(face.box.y + face.box.height / 2)
            let mx = Int((min(max(x, 0), 1) * Float(matte.width - 1)).rounded(.down))
            let my = Int((min(max(y, 0), 1) * Float(matte.height - 1)).rounded(.down))
            if matte.data[my * matte.width + mx] >= 0.5 { return (x, y) }
        }
        return defaultTarget(matte: matte)
    }

    /// The subject's matte centroid, else the image centre.
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
        let radiusMax = radiusMax(blur: params.blur, longSide: max(w, h), fraction: params.maxRadiusFraction)
        if radiusMax < 0.5 {
            // blur = 0: the photo unchanged, or the subject over its replacement.
            return scene.original ?? composite(scene)
        }
        let halfWidth = halfWidth(focusDepth: params.focusDepth)
        let focal = params.focalOverride ?? focalDisparity(scene, x: params.targetX, y: params.targetY)
        // Revision 1 (§R4): focusing on the subject keeps the whole subject plane sharp.
        let subjectInFocus = scene.subject != nil
            && (params.subjectFocus ?? focusIsOnSubject(scene, x: params.targetX, y: params.targetY))
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
            if !(planeIndex == 1 && subjectInFocus) {
                for i in 0..<coc.pixelCount {
                    coc.data[i] = signedCoC(disparity: plane.disparity.data[i], focal: focal, halfWidth: halfWidth, radiusMax: radiusMax)
                }
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
        guard radius >= 0.5 else { return Kernel(taps: [(0, 0, 1)]) }
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
            return motionKernel(radius: radius, directionDegrees: styleAmount * 3.6 - 180)
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

    /// Motion: a 1 px wide streak of length 3 × radius at the angle (y up, as the reference).
    static func motionKernel(radius: Float, directionDegrees: Float) -> Kernel {
        guard radius >= 0.5 else { return Kernel(taps: [(0, 0, 1)]) }
        let theta = Double(directionDegrees) * .pi / 180
        let half = 1.5 * Double(radius)
        return shapeKernel(extent: 1.5 * radius) { x, y in
            let xd = Double(x), yd = -Double(y)
            let along = xd * cos(theta) + yd * sin(theta), across = -xd * sin(theta) + yd * cos(theta)
            return abs(along) <= half && abs(across) <= 0.5
        }
    }

    /// The kernel as a dense size × size matrix, row 0 at the top (golden comparisons).
    static func matrix(_ kernel: Kernel) -> (size: Int, values: [Float]) {
        let half = Int(kernel.taps.map { max(abs($0.dx), abs($0.dy)) }.max() ?? 0)
        let size = 2 * half + 1
        var values = [Float](repeating: 0, count: size * size)
        for tap in kernel.taps { values[(Int(tap.dy) + half) * size + Int(tap.dx) + half] = tap.w }
        return (size, values)
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
                // Zero-weight taps are kept so the kernel's extent is the reference's grid.
                taps.append((Float(x), Float(y), Float(hits)))
            }
        }
        if taps.allSatisfy({ $0.2 == 0 }) { taps = [(0, 0, 1)] }
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

    /// Convolution with the kernel ('same' size, numpy-reflect borders), as the reference's FFT
    /// convolution: the tap at kernel offset (dx, dy) reads the input at (x − dx, y − dy).
    static func gather(_ image: FloatImage, _ kernel: Kernel) -> FloatImage {
        let kernel = Kernel(taps: kernel.taps.filter { $0.w != 0 })
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
                            let sx = reflect101(x - dx, w), sy = reflect101(y - dy, h)
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
                        for c in 0..<ch { base[(y * w + x) * ch + c] += sampleReflect(image, sx, sy, c) / Float(samples) }
                    }
                }
            }
        }
        return out
    }

    /// numpy 'reflect' (OpenCV BORDER_REFLECT_101): … 2 1 | 0 1 2 … n−1 | n−2 …
    @inline(__always)
    static func reflect101(_ i: Int, _ n: Int) -> Int {
        guard n > 1 else { return 0 }
        let period = 2 * (n - 1)
        var k = i % period
        if k < 0 { k += period }
        return k < n ? k : period - k
    }

    /// OpenCV BORDER_REFLECT (edge repeated): … 1 0 | 0 1 2 … n−1 | n−1 n−2 …
    @inline(__always)
    static func reflectEdge(_ i: Int, _ n: Int) -> Int {
        let period = 2 * n
        var k = i % period
        if k < 0 { k += period }
        return k < n ? k : period - 1 - k
    }

    /// Bilinear sample with BORDER_REFLECT outside the image (cv2.warpAffine in rotationalBlur).
    @inline(__always)
    static func sampleReflect(_ image: FloatImage, _ x: Float, _ y: Float, _ c: Int) -> Float {
        let x0f = x.rounded(.down), y0f = y.rounded(.down)
        let fx = x - x0f, fy = y - y0f
        let x0 = Int(x0f), y0 = Int(y0f)
        let xa = reflectEdge(x0, image.width), xb = reflectEdge(x0 + 1, image.width)
        let ya = reflectEdge(y0, image.height), yb = reflectEdge(y0 + 1, image.height)
        let w = image.width, ch = image.channels
        let top = image.data[(ya * w + xa) * ch + c] * (1 - fx) + image.data[(ya * w + xb) * ch + c] * fx
        let bottom = image.data[(yb * w + xa) * ch + c] * (1 - fx) + image.data[(yb * w + xb) * ch + c] * fx
        return top * (1 - fy) + bottom * fy
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
        let blurred = small.gaussianBlurred(sigma: sigma / Float(scale), truncation: 4, reflectBorders: true)
        return n == 0 ? blurred : blurred.resized(width: image.width, height: image.height)
    }

    // MARK: - Helpers

    /// numpy median: the mean of the two middle values for an even count.
    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Python's round(): halves to even.
    static func roundHalfEven(_ value: Float) -> Int { Int(value.rounded(.toNearestOrEven)) }

    /// Binary dilation or erosion of `plane > threshold` by OpenCV's elliptic structuring element of
    /// size 2r+1 (cv2.getStructuringElement(MORPH_ELLIPSE)); pixels outside the image are ignored.
    static func ellipseMorphology(_ plane: FloatImage, threshold: Float, radius: Int, dilate: Bool) -> FloatImage {
        let w = plane.width, h = plane.height
        var binary = FloatImage(width: w, height: h, channels: 1)
        for i in 0..<binary.pixelCount { binary.data[i] = plane.data[i * plane.channels] > threshold ? 1 : 0 }
        guard radius > 0 else { return binary }
        // Row extents of the element: cv2 uses dx = round(c·sqrt((r² − dy²)/r²)) with c = r.
        let extents: [Int] = (-radius...radius).map { dy in
            Int((Double(radius) * ((Double(radius * radius - dy * dy)) / Double(radius * radius)).squareRoot()).rounded(.toNearestOrEven))
        }
        var out = FloatImage(width: w, height: h, channels: 1)
        let source = binary
        out.data.withUnsafeMutableBufferPointer { dst in
            let base = dst.baseAddress!
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    var value: Float = dilate ? 0 : 1
                    rows: for (index, dy) in (-radius...radius).enumerated() {
                        let yy = y + dy
                        guard yy >= 0, yy < h else { continue }
                        let dx = extents[index]
                        for xx in max(0, x - dx)...min(w - 1, x + dx) {
                            let v = source.data[yy * w + xx]
                            if dilate, v > 0 { value = 1; break rows }
                            if !dilate, v == 0 { value = 0; break rows }
                        }
                    }
                    base[y * w + x] = value
                }
            }
        }
        return out
    }

    static func inverted(_ mask: FloatImage) -> FloatImage {
        var out = mask
        for i in 0..<out.pixelCount { out.data[i] = 1 - out.data[i] }
        return out
    }
}
