import SwiftUI

/// The Lightly Labs eight-ray aperture/spark mark.
///
/// Drawn as a vector rather than shipped as a raster so that spec §32 can be
/// satisfied: the mark must stay legible from 16pt to 1024pt, and stroke weight
/// must be *optically* corrected rather than mathematically uniform.
///
/// Optical corrections applied here:
/// - Cardinal rays (N/E/S/W) are drawn slightly longer than diagonal rays.
///   Mathematically equal rays read as *shorter* on the cardinals because the
///   eye compares them against the square bounding box.
/// - Stroke weight scales with size but is floored, so the mark does not
///   disappear into a hairline at favicon dimensions.
struct BrandMark: View {
    /// Edge length of the square the mark is drawn into.
    let size: CGFloat
    /// Colour of the rays.
    let tint: Color

    /// Fraction of the radius left empty at the centre. The gap is what makes
    /// the mark read as an aperture rather than an asterisk.
    private let innerGapRatio: CGFloat = 0.30

    /// Diagonal rays stop short of the cardinals by this fraction, correcting
    /// the optical illusion that makes equal-length rays look uneven.
    private let diagonalShortening: CGFloat = 0.86

    var body: some View {
        Canvas { context, canvasSize in
            let centre = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let radius = min(canvasSize.width, canvasSize.height) / 2
            let innerRadius = radius * innerGapRatio

            var path = Path()
            for index in 0..<8 {
                let angle = Angle.degrees(Double(index) * 45)
                let isCardinal = index.isMultiple(of: 2)
                let outerRadius = isCardinal ? radius : radius * diagonalShortening

                path.move(to: point(from: centre, angle: angle, distance: innerRadius))
                path.addLine(to: point(from: centre, angle: angle, distance: outerRadius))
            }

            context.stroke(
                path,
                with: .color(tint),
                style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true) // Decorative; the wordmark carries the label.
    }

    /// Stroke weight as a fraction of size, with a floor so the mark survives at
    /// favicon and notification sizes (spec §32 size ladder).
    private var strokeWidth: CGFloat {
        max(1.25, size * 0.035)
    }

    private func point(from centre: CGPoint, angle: Angle, distance: CGFloat) -> CGPoint {
        CGPoint(
            x: centre.x + cos(angle.radians) * distance,
            y: centre.y + sin(angle.radians) * distance
        )
    }
}

#Preview("Size ladder — spec §32") {
    // Renders the exact ladder the spec requires verifying before the mark is
    // locked: 16, 24, 32, 40, 60, 120, 1024 (1024 shown scaled for preview).
    VStack(spacing: 24) {
        HStack(alignment: .bottom, spacing: 16) {
            ForEach([16, 24, 32, 40, 60, 120] as [CGFloat], id: \.self) { size in
                VStack(spacing: 6) {
                    BrandMark(size: size, tint: .primary)
                    Text("\(Int(size))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        BrandMark(size: 200, tint: .primary)
    }
    .padding()
}
