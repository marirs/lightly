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

/// `.cropframe`: inset 6 %, a 1 pt white border (1.5px in the CSS, floored by the approved render), the area outside darkened (42 % black, clipped
/// to the photo), four 18 pt corner handles of 3 pt white strokes 3 pt outside the frame, and the
/// thirds grid inside.
struct CropFrameMark: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let frame = CGRect(x: size.width * 0.06, y: size.height * 0.06, width: size.width * 0.88, height: size.height * 0.88)
            ZStack(alignment: .topLeading) {
                // `box-shadow: 0 0 0 2000px rgba(0,0,0,.42)` outside the border box.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(frame)
                }
                .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))
                // The border is 1 pt as rendered (the approved references floor CSS border widths (Chromium computes 1.5px as 1px, 2.5px as 2px)); the grid fills the padding box inside it.
                ThirdsGridMark()
                    .frame(width: frame.width - 2, height: frame.height - 2)
                    .offset(x: frame.minX + 1, y: frame.minY + 1)
                Rectangle().strokeBorder(.white, lineWidth: 1)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                ForEach(0..<4, id: \.self) { corner in
                    cornerHandle(corner)
                        .frame(width: 18, height: 18)
                        // `left/top: −3px` from the padding box, inside the 1 pt border.
                        .offset(x: corner % 2 == 0 ? frame.minX - 2 : frame.maxX - 16,
                                y: corner < 2 ? frame.minY - 2 : frame.maxY - 16)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// An L of two 3 pt strokes on the corner's outer sides (`border … ; border-right:0; …`).
    private func cornerHandle(_ corner: Int) -> some View {
        Path { path in
            let left = corner % 2 == 0, top = corner < 2
            let x: CGFloat = left ? 0 : 15, y: CGFloat = top ? 0 : 15
            path.addRect(CGRect(x: x, y: 0, width: 3, height: 18))
            path.addRect(CGRect(x: 0, y: y, width: 18, height: 3))
        }
        .fill(.white)
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
