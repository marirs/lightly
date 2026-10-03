import CoreGraphics
import Foundation

/// Model results the Background and Portrait stages need, computed once per photo and cached
/// for the session (recipe `derivedRef`s point at them by digest).
struct SceneCache: Sendable {
    var subject: SubjectMatte?
    /// True once subject separation ran (a nil `subject` then means "no clear subject").
    var subjectAnalysed = false
    var disparity: DisparityMap?
    var people: PeopleAnalysis?
    /// Person segmentation (for hair), when computed.
    var personMatte: FloatImage?
    /// Bundled background images, decoded.
    var replacementImages: [String: CGImage] = [:]
}

/// Stages 7 (background.replace) and 8 (background.focus) for one frame.
enum BackgroundStage {

    /// Applies replacement and Focus & Blur to `linear` (the frame after Develop). The matte and
    /// disparity are resized to the frame; refine strokes edit the matte first (§R8).
    /// `replacementLinear` is the replacement already rendered at the frame size, with the
    /// photo's global colour applied (stage 7 note).
    static func render(_ linear: FloatImage, background: EditRecipe.Background, cache: SceneCache,
                       replacementLinear: FloatImage?, interactive: Bool) -> FloatImage {
        let hasReplacement = background.replacement != nil && replacementLinear != nil
        let blur = Float(background.focus.blur)
        guard hasReplacement || blur > 0 else { return linear }
        var matte = cache.subject.map { $0.matte.resized(width: linear.width, height: linear.height) }
        if var m = matte {
            applyRefinements(background.subject.refinements, to: &m)
            matte = m
        }
        // Depth: the recorded map only. Revision 1 (§R8, G3): a blur is never built from the matte
        // alone. Without depth there is no blur; a replacement is still composited sharp.
        guard let map = cache.disparity, background.focus.depth.source != .subjectMatte else {
            guard hasReplacement, let replacementLinear, let matte else { return linear }
            var out = replacementLinear
            for i in 0..<out.pixelCount {
                let a = matte.data[i]
                for c in 0..<3 { out.data[i * 3 + c] = linear.data[i * 3 + c] * a + out.data[i * 3 + c] * (1 - a) }
            }
            return out
        }
        let up = map.disparity.resized(width: linear.width, height: linear.height)
        let radius = max(2, RefocusRenderer.roundHalfEven(0.006 * Float(linear.longSide)))
        var disparity = FloatImage.guidedFilter(guide: linear.encodedGrey(), source: up, radius: radius, epsilon: 1e-3)
        for i in 0..<disparity.pixelCount { disparity.data[i] = min(max(disparity.data[i], 0), 1) }
        var scene = RefocusRenderer.buildScene(linear: linear, disparity: disparity, matte: matte)
        if hasReplacement, let replacementLinear {
            // §R2.4 "plane" placement; `replacementDepth` is not read (revision 1, G6).
            scene = RefocusRenderer.replacingBackground(scene, with: replacementLinear, ownDisparity: nil)
        }
        let target = background.focus.target.map { (Float($0.x), Float($0.y)) } ?? RefocusRenderer.defaultTarget(matte: matte, faces: cache.people?.faces ?? [])
        let params = RefocusRenderer.Parameters(
            targetX: target.0, targetY: target.1, blur: blur, focusDepth: Float(background.focus.depthOfField),
            style: background.focus.style, bokeh: background.focus.bokeh, styleAmount: Float(background.focus.styleAmount),
            layersPerSide: interactive ? 4 : RefocusRenderer.layersPerSide,
            // The recipe stores depth (0 near); the renderer works in disparity (G4).
            focalOverride: background.focus.depth.focusDepth.map { 1 - Float($0) },
            // A null target with a subject means "focus on the subject" (§R4).
            subjectFocus: background.focus.target == nil && matte != nil ? true : nil)
        return RefocusRenderer.render(scene, params)
    }

    /// Refine edges: add or erase brush strokes on the matte (points in source coordinates,
    /// radius as a fraction of the long edge), with a soft edge.
    static func applyRefinements(_ strokes: [EditRecipe.RefineStroke], to matte: inout FloatImage) {
        let w = matte.width, h = matte.height, long = Float(max(w, h))
        for stroke in strokes {
            let r = Float(stroke.radius) * long
            var points = stroke.points.map { (Float($0.x) * Float(w - 1), Float($0.y) * Float(h - 1)) }
            // Densify so a fast stroke is continuous.
            if points.count > 1 {
                var dense: [(Float, Float)] = []
                for (a, b) in zip(points, points.dropFirst()) {
                    let steps = max(1, Int(((b.0 - a.0) * (b.0 - a.0) + (b.1 - a.1) * (b.1 - a.1)).squareRoot() / max(r * 0.3, 1)))
                    for s in 0..<steps { let t = Float(s) / Float(steps); dense.append((a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)) }
                }
                dense.append(points.last!)
                points = dense
            }
            for (px, py) in points {
                let x0 = max(0, Int(px - r - 1)), x1 = min(w - 1, Int(px + r + 1)), y0 = max(0, Int(py - r - 1)), y1 = min(h - 1, Int(py + r + 1))
                guard x0 <= x1, y0 <= y1 else { continue }
                for y in y0...y1 { for x in x0...x1 {
                    let d = ((Float(x) - px) * (Float(x) - px) + (Float(y) - py) * (Float(y) - py)).squareRoot()
                    let brush = min(max((r - d) / max(r * 0.25, 1), 0), 1)
                    let i = y * w + x
                    matte.data[i] = stroke.mode == .add ? max(matte.data[i], brush) : matte.data[i] * (1 - brush)
                } }
            }
        }
    }

    // MARK: - Replacement image

    /// The replacement drawn at `width × height` as encoded RGBA8 (before the photo's colour).
    static func replacementRGBA8(_ replacement: EditRecipe.Replacement, width: Int, height: Int,
                                 image: CGImage?) -> [UInt8]? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: ColorPipeline.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        // CGContext's origin is bottom-left; draw in top-left coordinates.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        switch replacement {
        case .colour(let hex):
            context.setFillColor(cgColour(hex))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        case .gradient(let angle, let stops):
            drawCSSGradient(in: context, width: CGFloat(width), height: CGFloat(height), angle: angle, stops: stops)
        case .image(_, let x, let y, let scale):
            guard let image else { return nil }
            // Aspect-fill, zoomed by `scale`, positioned by x/y percent (CSS background-position).
            let factor = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height)) * CGFloat(scale / 100)
            let dw = CGFloat(image.width) * factor, dh = CGFloat(image.height) * factor
            let left = (CGFloat(width) - dw) * CGFloat(x / 100), top = (CGFloat(height) - dh) * CGFloat(y / 100)
            context.saveGState()
            context.translateBy(x: left, y: top + dh)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: dw, height: dh))
            context.restoreGState()
        }
        guard let data = context.data else { return nil }
        return [UInt8](UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    /// CSS `linear-gradient(<angle>deg, …)`: 0deg points up, clockwise; the gradient line passes
    /// through the centre and is long enough that the corners get the end colours.
    static func drawCSSGradient(in context: CGContext, width: CGFloat, height: CGFloat, angle: Double, stops: [EditRecipe.GradientStop]) {
        let radians = angle * .pi / 180
        let dx = sin(radians), dy = -cos(radians)
        let half = (abs(width * dx) + abs(height * dy)) / 2
        let centre = CGPoint(x: width / 2, y: height / 2)
        let start = CGPoint(x: centre.x - dx * half, y: centre.y - dy * half), end = CGPoint(x: centre.x + dx * half, y: centre.y + dy * half)
        let colours = stops.map { cgColour($0.colour) } as CFArray
        let locations = stops.map { CGFloat($0.position) }
        guard let gradient = CGGradient(colorsSpace: ColorPipeline.sRGB, colors: colours, locations: locations) else { return }
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    static func cgColour(_ hex: String) -> CGColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return CGColor(colorSpace: ColorPipeline.sRGB, components: [
            CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255, 1])!
    }
}
