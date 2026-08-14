import SwiftUI

/// The minimal snow-mountain line artwork anchored to the bottom of the launch
/// screen (spec §4.1).
///
/// Drawn procedurally from a fixed ridge profile so it scales to any device
/// width without a raster asset, and so the parallax response in §4.1 ("the
/// mountain artwork moves subtly with the gesture") can be driven continuously.
///
/// The profile is intentionally hand-tuned rather than generated: a random or
/// purely algorithmic ridge reads as noise, not as a place.
struct MountainArtwork: View {
    /// Colour of the ridge lines.
    let tint: Color

    /// Vertical offset applied by the swipe gesture, in points. Positive values
    /// move the artwork up. Callers pass a damped fraction of the drag so the
    /// response feels attached but restrained.
    var parallaxOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack {
                // Far ridge — lighter and higher, establishing depth.
                ridge(peaks: Self.farRidge, width: width, height: height)
                    .stroke(tint.opacity(0.45), style: strokeStyle)
                    .offset(y: -parallaxOffset * 0.35)

                // Near ridge — the primary silhouette.
                ridge(peaks: Self.nearRidge, width: width, height: height)
                    .stroke(tint.opacity(0.85), style: strokeStyle)
                    .offset(y: -parallaxOffset * 0.6)
            }
        }
        .accessibilityHidden(true) // Decorative.
    }

    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round)
    }

    /// Builds a ridge path from normalised control points.
    ///
    /// - Parameter peaks: points in unit space where `x` runs 0...1 left to
    ///   right and `y` runs 0 (top of the artwork band) to 1 (baseline).
    private func ridge(peaks: [CGPoint], width: CGFloat, height: CGFloat) -> Path {
        Path { path in
            guard let first = peaks.first else { return }
            path.move(to: CGPoint(x: first.x * width, y: first.y * height))
            for peak in peaks.dropFirst() {
                path.addLine(to: CGPoint(x: peak.x * width, y: peak.y * height))
            }
        }
    }

    /// Normalised profile of the distant ridge.
    ///
    /// Deliberately low and shallow. It exists to suggest depth behind the main
    /// massif; if it competes for attention the band reads as visual noise
    /// rather than as a horizon.
    private static let farRidge: [CGPoint] = [
        CGPoint(x: 0.00, y: 0.86),
        CGPoint(x: 0.16, y: 0.62),
        CGPoint(x: 0.30, y: 0.80),
        CGPoint(x: 0.40, y: 0.70),
        CGPoint(x: 0.52, y: 0.84),
        CGPoint(x: 0.66, y: 0.58),
        CGPoint(x: 0.82, y: 0.79),
        CGPoint(x: 1.00, y: 0.72)
    ]

    /// Normalised profile of the near ridge.
    ///
    /// One dominant massif left of centre with a lower shoulder to its right,
    /// rather than an even sawtooth. Alternating peaks of similar height read as
    /// a zigzag pattern; an asymmetric composition with a single clear summit
    /// reads as a mountain.
    private static let nearRidge: [CGPoint] = [
        CGPoint(x: 0.00, y: 1.00),
        CGPoint(x: 0.14, y: 0.72),
        CGPoint(x: 0.24, y: 0.84),
        CGPoint(x: 0.42, y: 0.34),
        CGPoint(x: 0.56, y: 0.78),
        CGPoint(x: 0.70, y: 0.56),
        CGPoint(x: 0.84, y: 0.88),
        CGPoint(x: 1.00, y: 0.80)
    ]
}

#Preview {
    MountainArtwork(tint: .primary)
        .frame(height: 180)
        .padding()
}
