import CoreGraphics

/// Free crop on the straightened frame (owner amendment 2026-10-05): `EditRecipe.Geometry.cropRect` is a fraction of the
/// frame after quarter turns, flips, perspective and straighten (GeometryTransform), so while Crop is active the stage shows
/// that frame uncropped and the rectangle is edited in its own fractions. Rotation and straightening therefore need no
/// extra mapping. Pure functions, tested in CropGeometryTests.
enum CropGeometry {
    static func scaled(_ rect: EditRecipe.Rect, magnification: Double) -> EditRecipe.Rect {
        let scale = max(0.01, magnification)
        let width = min(1, max(minimumFraction, rect.width / scale))
        let height = min(1, max(minimumFraction, rect.height / scale))
        return .init(x: min(max(rect.x + (rect.width - width) / 2, 0), 1 - width),
                     y: min(max(rect.y + (rect.height - height) / 2, 0), 1 - height), width: width, height: height)
    }

    enum Edge: Equatable { case left, right, top, bottom }

    enum Handle: Equatable {
        case corner(left: Bool, top: Bool)
        case edge(Edge)
        /// Inside the rectangle: moves it.
        case move
    }

    /// The smallest crop, as a fraction of the frame on each side.
    static let minimumFraction = 0.05

    /// The handle under `point` (displayed points) for `rect` shown at `size`; nil away from the rectangle.
    /// Corners and edges are reachable `reach` points either side of the line (a 44 pt target).
    static func handle(at point: CGPoint, rect: EditRecipe.Rect, size: CGSize, reach: CGFloat = 22) -> Handle? {
        let r = CGRect(x: rect.x * size.width, y: rect.y * size.height, width: rect.width * size.width, height: rect.height * size.height)
        guard point.x >= r.minX - reach, point.x <= r.maxX + reach, point.y >= r.minY - reach, point.y <= r.maxY + reach else { return nil }
        let toLeft = abs(point.x - r.minX), toRight = abs(point.x - r.maxX)
        let toTop = abs(point.y - r.minY), toBottom = abs(point.y - r.maxY)
        let nearX = min(toLeft, toRight) <= reach, nearY = min(toTop, toBottom) <= reach
        if nearX && nearY { return .corner(left: toLeft <= toRight, top: toTop <= toBottom) }
        if nearX { return .edge(toLeft <= toRight ? .left : .right) }
        if nearY { return .edge(toTop <= toBottom ? .top : .bottom) }
        return r.contains(point) ? .move : nil
    }

    /// `start` changed by dragging `handle` by (dx, dy), as fractions of the frame. `ratio` is the locked width:height
    /// in pixels (nil = Free); `frameAspect` is the frame's width / height in pixels. The result stays inside the frame
    /// and at least `minimumFraction` on each side.
    static func dragged(_ start: EditRecipe.Rect, handle: Handle, dx: Double, dy: Double,
                        ratio: Double?, frameAspect: Double) -> EditRecipe.Rect {
        let m = minimumFraction
        var x0 = start.x, y0 = start.y, x1 = start.x + start.width, y1 = start.y + start.height
        switch handle {
        case .move:
            let x = min(max(start.x + dx, 0), 1 - start.width), y = min(max(start.y + dy, 0), 1 - start.height)
            return .init(x: x, y: y, width: start.width, height: start.height)
        case .corner(let left, let top):
            if left { x0 = min(max(x0 + dx, 0), x1 - m) } else { x1 = max(min(x1 + dx, 1), x0 + m) }
            if top { y0 = min(max(y0 + dy, 0), y1 - m) } else { y1 = max(min(y1 + dy, 1), y0 + m) }
            guard let ratio else { break }
            // The width leads; the height follows the ratio, anchored at the opposite corner.
            var width = x1 - x0
            var height = width * frameAspect / ratio
            let room = top ? y1 : 1 - y0
            if height > room { height = room; width = height * ratio / frameAspect }
            if left { x0 = x1 - width } else { x1 = x0 + width }
            if top { y0 = y1 - height } else { y1 = y0 + height }
        case .edge(let edge):
            switch edge {
            case .left: x0 = min(max(x0 + dx, 0), x1 - m)
            case .right: x1 = max(min(x1 + dx, 1), x0 + m)
            case .top: y0 = min(max(y0 + dy, 0), y1 - m)
            case .bottom: y1 = max(min(y1 + dy, 1), y0 + m)
            }
            guard let ratio else { break }
            if edge == .left || edge == .right {
                // The other side follows the ratio about the rectangle's centre, within the frame.
                var width = x1 - x0, height = width * frameAspect / ratio
                if height > 1 { height = 1; width = height * ratio / frameAspect; if edge == .left { x0 = x1 - width } else { x1 = x0 + width } }
                let centre = (start.y + start.y + start.height) / 2
                y0 = min(max(centre - height / 2, 0), 1 - height); y1 = y0 + height
            } else {
                var height = y1 - y0, width = height * ratio / frameAspect
                if width > 1 { width = 1; height = width * frameAspect / ratio; if edge == .top { y0 = y1 - height } else { y1 = y0 + height } }
                let centre = (start.x + start.x + start.width) / 2
                x0 = min(max(centre - width / 2, 0), 1 - width); x1 = x0 + width
            }
        }
        return .init(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
