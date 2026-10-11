import SwiftUI

/// Marks drawn over the photo for Edit and Effects (prototype `marksFor`), sized to the fitted
/// image, and the touches they take.

/// `.grid3`: thirds lines (1 pt, white at 45 %) at 0, ⅓ and ⅔ of each axis, as the CSS
/// background tiles draw them.
struct ThirdsGridMark: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let w = geometry.size.width, h = geometry.size.height
                for i in 0..<3 {
                    let x = (w / 3 * CGFloat(i)).rounded(.down), y = (h / 3 * CGFloat(i)).rounded(.down)
                    path.addRect(CGRect(x: x, y: 0, width: 1, height: h))
                    path.addRect(CGRect(x: 0, y: y, width: w, height: 1))
                }
            }
            .fill(Color.white.opacity(0.45))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The inline crop frame (owner, 2026-10-11): on the photo itself, the area outside dimmed (50 % black, lighter while
/// adjusting so the surroundings stay readable), a 1 pt white border, 3 pt white L handles on the four corners and bars
/// on the middle of each edge (drawn inside the frame, with a soft shadow on light photos), and the thirds grid only
/// while a drag or pinch is under way.
struct CropFrameMark: View {
    /// The crop rectangle in fractions of the shown (uncropped) frame.
    let rect: EditRecipe.Rect
    var isAdjusting = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let frame = CGRect(x: size.width * rect.x, y: size.height * rect.y, width: size.width * rect.width, height: size.height * rect.height)
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(frame)
                }
                .fill(Color.black.opacity(isAdjusting ? 0.35 : 0.5), style: FillStyle(eoFill: true))
                if isAdjusting {
                    ThirdsGridMark()
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
                Rectangle().strokeBorder(.white.opacity(0.9), lineWidth: 1)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                handles(in: frame)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2)
            }
            .animation(.easeOut(duration: 0.15), value: isAdjusting)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Corner Ls (20 pt arms) and edge bars (24 pt), 3 pt thick, inside the border.
    private func handles(in frame: CGRect) -> Path {
        let thickness: CGFloat = 3
        let arm = min(20, frame.width / 3, frame.height / 3)
        let bar = min(24, frame.width / 3, frame.height / 3)
        return Path { path in
            for (x, y, dx, dy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                                   (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
                path.addRect(CGRect(x: dx > 0 ? x : x - arm, y: dy > 0 ? y : y - thickness, width: arm, height: thickness))
                path.addRect(CGRect(x: dx > 0 ? x : x - thickness, y: dy > 0 ? y : y - arm, width: thickness, height: arm))
            }
            path.addRect(CGRect(x: frame.midX - bar / 2, y: frame.minY, width: bar, height: thickness))
            path.addRect(CGRect(x: frame.midX - bar / 2, y: frame.maxY - thickness, width: bar, height: thickness))
            path.addRect(CGRect(x: frame.minX, y: frame.midY - bar / 2, width: thickness, height: bar))
            path.addRect(CGRect(x: frame.maxX - thickness, y: frame.midY - bar / 2, width: thickness, height: bar))
        }
    }
}

/// `.stroke`: Remove strokes in translucent red (235, 60, 60 at 42 %), round-capped, the width
/// of the brush. One layer, so overlapping parts do not darken.
struct RemoveStrokesMark: View {
    /// Each stroke's points on the frame (normalised) and its radius in frame points.
    let strokes: [(points: [CGPoint], radius: CGFloat)]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                ForEach(strokes.indices, id: \.self) { index in
                    let stroke = strokes[index]
                    Path { path in
                        let points = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                        guard let first = points.first else { return }
                        path.move(to: first)
                        if points.count == 1 { path.addLine(to: first) }
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(Color.white, style: StrokeStyle(lineWidth: stroke.radius * 2, lineCap: .round, lineJoin: .round))
                }
            }
            .compositingGroup()
            .colorMultiply(Color(red: 235 / 255, green: 60 / 255, blue: 60 / 255))
            .opacity(0.42)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
