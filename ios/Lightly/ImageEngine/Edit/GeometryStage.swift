import CoreGraphics
import Foundation
import simd

/// Stage 4, `edit.geometry` (rendering-v2 §7): source → frame, in this order, each step in the
/// frame the previous one produced (what the person sees):
/// quarter turns → flips → perspective → straighten → crop.
///
/// The whole chain is one projective map in pixel coordinates (continuous, origin top-left,
/// pixel centres at +0.5), so a point can be carried either way: content points stored in source
/// coordinates (Remove strokes, refine strokes, focus target, face boxes) are drawn on the frame
/// with `frame(fromSource:)`, and a touch on the frame is stored with `source(fromFrame:)`.
struct GeometryTransform: Sendable, Equatable {
    let sourceWidth: Int
    let sourceHeight: Int
    let frameWidth: Int
    let frameHeight: Int
    /// Maps homogeneous source pixel coordinates to frame pixel coordinates.
    let sourceToFrame: simd_double3x3
    let frameToSource: simd_double3x3
    let isIdentity: Bool

    /// ±100 scales the far edge by 1 ∓ 0.3 (rendering-v2.json `perspective`).
    static let perspectiveEdgeScalePerUnit = 0.3

    init(_ geometry: EditRecipe.Geometry, sourceWidth: Int, sourceHeight: Int) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        var matrix = matrix_identity_double3x3
        var width = Double(sourceWidth), height = Double(sourceHeight)

        // 1. Quarter turns, clockwise: (x, y) in W × H → (H − y, x) in H × W.
        for _ in 0..<((geometry.quarterTurns % 4 + 4) % 4) {
            let turn = simd_double3x3(rows: [SIMD3(0, -1, height), SIMD3(1, 0, 0), SIMD3(0, 0, 1)])
            matrix = turn * matrix
            swap(&width, &height)
        }
        // 2. Flips in the turned frame.
        if geometry.flipHorizontal {
            matrix = simd_double3x3(rows: [SIMD3(-1, 0, width), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]) * matrix
        }
        if geometry.flipVertical {
            matrix = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, -1, height), SIMD3(0, 0, 1)]) * matrix
        }
        // 3. Perspective (keystone about the centre), zoomed so no empty area shows.
        if geometry.perspectiveVertical != 0 || geometry.perspectiveHorizontal != 0 {
            matrix = Self.keystone(vertical: geometry.perspectiveVertical, horizontal: geometry.perspectiveHorizontal,
                                   width: width, height: height) * matrix
        }
        // 4. Straighten: rotate about the centre (clockwise positive) and zoom by the smallest
        //    factor that leaves no empty corner.
        if geometry.straighten != 0 {
            let theta = geometry.straighten * .pi / 180
            let zoom = Self.straightenZoom(degrees: geometry.straighten, width: width, height: height)
            let c = cos(theta) * zoom, s = sin(theta) * zoom
            let cx = width / 2, cy = height / 2
            let rotate = simd_double3x3(rows: [SIMD3(c, -s, cx - c * cx + s * cy), SIMD3(s, c, cy - s * cx - c * cy), SIMD3(0, 0, 1)])
            matrix = rotate * matrix
        }
        // 5. Crop: `rect` in the straightened frame (fractions).
        let rect = geometry.cropRect
        let cropX = rect.x * width, cropY = rect.y * height
        matrix = simd_double3x3(rows: [SIMD3(1, 0, -cropX), SIMD3(0, 1, -cropY), SIMD3(0, 0, 1)]) * matrix
        frameWidth = max(1, Int((rect.width * width).rounded()))
        frameHeight = max(1, Int((rect.height * height).rounded()))

        sourceToFrame = matrix
        frameToSource = matrix.inverse
        isIdentity = geometry == Self.neutralGeometry
    }

    static let neutralGeometry = EditRecipe.Geometry(quarterTurns: 0, flipHorizontal: false, flipVertical: false,
                                                     perspectiveVertical: 0, perspectiveHorizontal: 0, straighten: 0,
                                                     cropAspect: .original, cropRect: .init(x: 0, y: 0, width: 1, height: 1))

    /// The turned frame's size (before the crop), in which the crop rect is expressed.
    static func turnedSize(_ geometry: EditRecipe.Geometry, sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        geometry.quarterTurns % 2 == 0 ? (sourceWidth, sourceHeight) : (sourceHeight, sourceWidth)
    }

    // MARK: Points

    /// A normalised source point on the frame (normalised); may fall outside [0, 1] when cropped away.
    func frame(fromSource point: CGPoint) -> CGPoint {
        let p = sourceToFrame * SIMD3(Double(point.x) * Double(sourceWidth), Double(point.y) * Double(sourceHeight), 1)
        return CGPoint(x: p.x / p.z / Double(frameWidth), y: p.y / p.z / Double(frameHeight))
    }

    /// A normalised frame point (a touch) in normalised source coordinates.
    func source(fromFrame point: CGPoint) -> CGPoint {
        let p = frameToSource * SIMD3(Double(point.x) * Double(frameWidth), Double(point.y) * Double(frameHeight), 1)
        return CGPoint(x: p.x / p.z / Double(sourceWidth), y: p.y / p.z / Double(sourceHeight))
    }

    // MARK: Rendering

    /// The frame from RGBA8 source pixels (bilinear, edge-clamped; the zoom rules leave no empty
    /// area, so clamping only touches the outermost half pixel).
    func render(_ pixels: [UInt8], width: Int, height: Int) -> (pixels: [UInt8], width: Int, height: Int) {
        guard !isIdentity else { return (pixels, width, height) }
        // The transform was made for (sourceWidth, sourceHeight); a render at another resolution of
        // the same photo scales into it.
        let scaleX = Double(width) / Double(sourceWidth), scaleY = Double(height) / Double(sourceHeight)
        let outWidth = max(1, Int((Double(frameWidth) * scaleX).rounded()))
        let outHeight = max(1, Int((Double(frameHeight) * scaleY).rounded()))
        let frameScaleX = Double(frameWidth) / Double(outWidth), frameScaleY = Double(frameHeight) / Double(outHeight)
        let m = frameToSource
        var output = [UInt8](repeating: 255, count: outWidth * outHeight * 4)
        pixels.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                let src = source.baseAddress!, dst = destination.baseAddress!
                DispatchQueue.concurrentPerform(iterations: outHeight) { row in
                    for column in 0..<outWidth {
                        let fx = (Double(column) + 0.5) * frameScaleX, fy = (Double(row) + 0.5) * frameScaleY
                        let p = m * SIMD3(fx, fy, 1)
                        // Source pixel coordinates at this render's resolution, centres at +0.5.
                        let sx = min(max(p.x / p.z * scaleX - 0.5, 0), Double(width - 1))
                        let sy = min(max(p.y / p.z * scaleY - 0.5, 0), Double(height - 1))
                        let x0 = Int(sx), y0 = Int(sy)
                        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
                        let tx = sx - Double(x0), ty = sy - Double(y0)
                        let o = (row * outWidth + column) * 4
                        for c in 0..<3 {
                            let a = Double(src[(y0 * width + x0) * 4 + c]), b = Double(src[(y0 * width + x1) * 4 + c])
                            let d = Double(src[(y1 * width + x0) * 4 + c]), e = Double(src[(y1 * width + x1) * 4 + c])
                            let top = a + (b - a) * tx, bottom = d + (e - d) * tx
                            dst[o + c] = UInt8(min(max((top + (bottom - top) * ty).rounded(), 0), 255))
                        }
                    }
                }
            }
        }
        return (output, outWidth, outHeight)
    }

    // MARK: Steps

    /// [contract] the smallest zoom that leaves no empty corner after a rotation by `degrees`.
    static func straightenZoom(degrees: Double, width: Double, height: Double) -> Double {
        let theta = abs(degrees) * .pi / 180
        let c = cos(theta), s = sin(theta)
        return max(c + height / width * s, c + width / height * s)
    }

    /// Keystone about the frame centre: vertical v > 0 narrows the top edge to 1 − 0.3·v/100 of its
    /// width (v < 0 the bottom edge); horizontal h > 0 shortens the right edge (h < 0 the left).
    /// Then the smallest zoom about the centre that leaves no empty area.
    // rendering-v2 revision 2 §7.2 (C3) fixes the sign convention and the zoom as implemented
    // here: top/right edges for positive values, then the no-empty-area zoom that straighten uses.
    static func keystone(vertical: Double, horizontal: Double, width: Double, height: Double) -> simd_double3x3 {
        let k = perspectiveEdgeScalePerUnit
        let top = vertical > 0 ? 1 - k * vertical / 100 : 1, bottom = vertical < 0 ? 1 + k * vertical / 100 : 1
        let right = horizontal > 0 ? 1 - k * horizontal / 100 : 1, left = horizontal < 0 ? 1 + k * horizontal / 100 : 1
        let cx = width / 2, cy = height / 2
        // Corners about the centre: x scaled by its edge's vertical factor, y by its side's factor.
        func corner(_ sx: Double, _ sy: Double) -> SIMD2<Double> {
            let edge = sy < 0 ? top : bottom, side = sx < 0 ? left : right
            return SIMD2(cx + sx * cx * edge, cy + sy * cy * side)
        }
        let from = [SIMD2(0, 0), SIMD2(width, 0), SIMD2(width, height), SIMD2(0, height)]
        let to = [corner(-1, -1), corner(1, -1), corner(1, 1), corner(-1, 1)]
        let warp = homography(from: from, to: to)
        // Zoom z about the centre so the frame rectangle lies inside the warped quad.
        func covers(_ z: Double) -> Bool {
            for p in from {
                let q = SIMD2(cx + (p.x - cx) / z, cy + (p.y - cy) / z)
                if !inside(q, quad: to) { return false }
            }
            return true
        }
        var low = 1.0, high = 4.0
        if !covers(low) {
            for _ in 0..<40 { let mid = (low + high) / 2; if covers(mid) { high = mid } else { low = mid } }
            low = high
        }
        let z = low
        let zoom = simd_double3x3(rows: [SIMD3(z, 0, cx - z * cx), SIMD3(0, z, cy - z * cy), SIMD3(0, 0, 1)])
        return zoom * warp
    }

    private static func inside(_ p: SIMD2<Double>, quad: [SIMD2<Double>]) -> Bool {
        // Convex, clockwise in y-down coordinates: every edge's cross product must be ≥ 0.
        for i in 0..<4 {
            let a = quad[i], b = quad[(i + 1) % 4]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if cross < -1e-9 { return false }
        }
        return true
    }

    /// The projective map taking four points to four points (direct linear solve, h33 = 1).
    static func homography(from: [SIMD2<Double>], to: [SIMD2<Double>]) -> simd_double3x3 {
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let (x, y, u, v) = (from[i].x, from[i].y, to[i].x, to[i].y)
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        // Gaussian elimination with partial pivoting on the 8 × 9 augmented matrix.
        for column in 0..<8 {
            let pivot = (column..<8).max { abs(a[$0][column]) < abs(a[$1][column]) }!
            a.swapAt(column, pivot)
            for row in 0..<8 where row != column {
                let f = a[row][column] / a[column][column]
                for k in column..<9 { a[row][k] -= f * a[column][k] }
            }
        }
        let h = (0..<8).map { a[$0][8] / a[$0][$0] }
        return simd_double3x3(rows: [SIMD3(h[0], h[1], h[2]), SIMD3(h[3], h[4], h[5]), SIMD3(h[6], h[7], 1)])
    }

    // MARK: Crop aspect

    /// The largest centred crop of `aspect` (w/h in pixels) in a W × H frame, as fractions.
    static func centredRect(aspect: Double, width: Int, height: Int) -> EditRecipe.Rect {
        let frameAspect = Double(width) / Double(height)
        if aspect >= frameAspect {
            let h = frameAspect / aspect
            return .init(x: 0, y: (1 - h) / 2, width: 1, height: h)
        }
        let w = aspect / frameAspect
        return .init(x: (1 - w) / 2, y: 0, width: w, height: 1)
    }

    /// w/h of a fixed aspect, nil for original and free.
    static func ratio(_ aspect: EditRecipe.Geometry.Aspect) -> Double? {
        switch aspect {
        case .original, .free: nil
        case .square: 1
        case .fourFive: 4.0 / 5
        case .threeTwo: 3.0 / 2
        case .sixteenNine: 16.0 / 9
        case .nineSixteen: 9.0 / 16
        }
    }
}
