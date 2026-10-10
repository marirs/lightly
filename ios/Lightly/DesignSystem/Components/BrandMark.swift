import SwiftUI

/// The Lightly logo (owner choice 2026-10-10, Lightly 2 "spectrum rays"): the eight-ray aperture mark, each ray in
/// its own colour with a soft glow of that colour.
///
/// Geometry and colours are copied from the approved mockup (`rayEnds`, `SPECTRUM`, `SPARK`, `appIcon('rays')` in
/// docs/ui/directions/lightly-2-concept/index.html), in its 1024-unit space:
/// - ray i points at (i·45° − 90°), i.e. clockwise from the top; it runs from radius 118 to radius 352, and the
///   diagonal rays stop at 0.86 of that;
/// - each ray is a 38-unit round-capped stroke, over a 64-unit stroke at 75 % opacity blurred by 22 units (the glow);
/// - `.mark` is the mark alone (`SPARK`, view box 120…904); `.tile` is the app icon: the mark on #050506 with
///   228-unit corners (`LOGO_TILE`).
struct BrandMark: View {
    enum Style { case mark, tile }

    /// Edge length of the square the mark (or tile) is drawn into.
    let size: CGFloat
    var style: Style = .mark

    /// `SPECTRUM`, from the top ray clockwise.
    static let spectrum: [UInt32] = [0x6E5BFF, 0x2F86FF, 0x18C8F0, 0x14C99B, 0xCFF26B, 0xFFC23D, 0xFF5A5F, 0xE447C8]
    private static let innerRadius: CGFloat = 118
    private static let outerRadius: CGFloat = 352
    private static let diagonalShortening: CGFloat = 0.86
    private static let rayWidth: CGFloat = 38
    private static let glowWidth: CGFloat = 64
    private static let glowBlur: CGFloat = 22
    private static let tileCornerRadius: CGFloat = 228
    private static let tileFill: UInt32 = 0x050506

    var body: some View {
        Canvas { context, canvasSize in
            // `.mark` shows units 120…904 (784 wide); `.tile` the whole 1024.
            let viewOrigin: CGFloat = style == .mark ? 120 : 0
            let viewSize: CGFloat = style == .mark ? 784 : 1024
            let scale = min(canvasSize.width, canvasSize.height) / viewSize
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x - viewOrigin) * scale, y: (y - viewOrigin) * scale) }

            if style == .tile {
                let tile = Path(roundedRect: CGRect(x: 0, y: 0, width: 1024 * scale, height: 1024 * scale),
                                cornerRadius: Self.tileCornerRadius * scale, style: .circular)
                context.fill(tile, with: .color(Color(hex: Self.tileFill)))
                context.clip(to: tile)
            }
            for index in 0..<8 {
                let angle = (CGFloat(index) * 45 - 90) * .pi / 180
                let outer = index.isMultiple(of: 2) ? Self.outerRadius : Self.outerRadius * Self.diagonalShortening
                var ray = Path()
                ray.move(to: point(512 + cos(angle) * Self.innerRadius, 512 + sin(angle) * Self.innerRadius))
                ray.addLine(to: point(512 + cos(angle) * outer, 512 + sin(angle) * outer))
                let colour = Color(hex: Self.spectrum[index])
                context.drawLayer { glow in
                    glow.addFilter(.blur(radius: Self.glowBlur * scale))
                    glow.opacity = 0.75
                    glow.stroke(ray, with: .color(colour), style: StrokeStyle(lineWidth: Self.glowWidth * scale, lineCap: .round))
                }
                context.stroke(ray, with: .color(colour), style: StrokeStyle(lineWidth: Self.rayWidth * scale, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true) // Decorative; the wordmark carries the label.
    }
}

#Preview("Lightly 2 mark and tile") {
    VStack(spacing: 24) {
        BrandMark(size: 112)
        HStack(alignment: .bottom, spacing: 16) {
            ForEach([120, 60, 44, 29] as [CGFloat], id: \.self) { BrandMark(size: $0, style: .tile) }
        }
    }
    .padding()
}
