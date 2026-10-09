import CoreGraphics
import Foundation

/// Rendering-v2 stage 11, `border`: places the finished frame on a larger canvas.
///
/// Insets are fractions of the frame's width (rendering-v2.md §7, prototype `borderInsets`):
/// - solid: `width/100` on every side, in `colour`;
/// - frame: `(width + spacing)/100` on every side; the outer `width/100` band is `colour`
///   and the inner `spacing/100` band is the `mat`;
/// - polaroid: side and top 0.055, bottom 0.24, in `colour`;
/// - none: the frame is returned unchanged.
/// Preview and export run this same function, so the saved copy matches what was on screen.
enum BorderStage {

    struct Insets: Equatable {
        let side: Double
        let top: Double
        let bottom: Double
    }

    static func insets(_ border: EditRecipe.Border) -> Insets {
        switch border.type {
        case .none: return Insets(side: 0, top: 0, bottom: 0)
        case .solid, .paper: let w = border.width / 100; return Insets(side: w, top: w, bottom: w)
        case .frame: let t = (border.width + border.spacing) / 100; return Insets(side: t, top: t, bottom: t)
        case .polaroid: return Insets(side: 0.055, top: 0.055, bottom: 0.24)
        }
    }

    /// Inset pixel sizes for a frame, rounded from the frame width, and the canvas they make.
    struct Placement: Equatable {
        let side: Int, top: Int, bottom: Int
        let frameWidth: Int, frameHeight: Int
        var canvasWidth: Int { frameWidth + 2 * side }
        var canvasHeight: Int { frameHeight + top + bottom }
        /// The photo inside the canvas, in canvas pixels (origin top-left).
        var imageRect: CGRect { CGRect(x: side, y: top, width: frameWidth, height: frameHeight) }
    }

    static func placement(_ border: EditRecipe.Border, frameWidth: Int, frameHeight: Int) -> Placement {
        let insets = insets(border)
        return Placement(side: Int((insets.side * Double(frameWidth)).rounded()), top: Int((insets.top * Double(frameWidth)).rounded()),
                         bottom: Int((insets.bottom * Double(frameWidth)).rounded()), frameWidth: frameWidth, frameHeight: frameHeight)
    }

    /// The photo's box inside a canvas this border produced, as fractions of the canvas (the
    /// prototype's `.imgbox` inside `.frame`): marks and touches sit on it. Recovers the exact
    /// frame width the canvas was made from (the insets are rounded from it).
    static func imageBox(_ border: EditRecipe.Border, canvasWidth: Int, canvasHeight: Int) -> CGRect {
        guard border.type != .none, canvasWidth > 0, canvasHeight > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let insets = insets(border)
        let estimate = Int((Double(canvasWidth) / (1 + 2 * insets.side)).rounded())
        let frameWidth = (estimate - 2...estimate + 2).first { placement(border, frameWidth: $0, frameHeight: 0).canvasWidth == canvasWidth } ?? estimate
        let probe = placement(border, frameWidth: frameWidth, frameHeight: 0)
        let frameHeight = max(canvasHeight - probe.top - probe.bottom, 1)
        let rect = placement(border, frameWidth: frameWidth, frameHeight: frameHeight).imageRect
        return CGRect(x: rect.minX / CGFloat(canvasWidth), y: rect.minY / CGFloat(canvasHeight),
                      width: rect.width / CGFloat(canvasWidth), height: rect.height / CGFloat(canvasHeight))
    }

    /// RGBA8 frame in, RGBA8 canvas out. Inset pixel sizes are rounded from the frame width.
    static func apply(_ border: EditRecipe.Border, pixels: [UInt8], width: Int, height: Int)
        -> (pixels: [UInt8], width: Int, height: Int) {
        guard border.type != .none, width > 0, height > 0 else { return (pixels, width, height) }
        let placement = placement(border, frameWidth: width, frameHeight: height)
        let side = placement.side, top = placement.top
        let canvasWidth = placement.canvasWidth
        let canvasHeight = placement.canvasHeight
        let outer = rgba(border.colour)
        var canvas = [UInt8](repeating: 0, count: canvasWidth * canvasHeight * 4)
        fill(&canvas, canvasWidth: canvasWidth, x0: 0, y0: 0, x1: canvasWidth, y1: canvasHeight, colour: outer)
        if border.type == .frame {
            // The mat sits inside the frame band and around the photo.
            let band = Int((border.width / 100 * Double(width)).rounded())
            fill(&canvas, canvasWidth: canvasWidth, x0: band, y0: band,
                 x1: canvasWidth - band, y1: canvasHeight - band, colour: rgba(border.mat))
        }
        let rowBytes = width * 4
        for y in 0..<height {
            let source = y * rowBytes
            let destination = ((y + top) * canvasWidth + side) * 4
            canvas.replaceSubrange(destination..<(destination + rowBytes), with: pixels[source..<(source + rowBytes)])
        }
        if border.type == .paper { PaperBorder.paint(border, placement: placement, pixels: &canvas) }
        return (canvas, canvasWidth, canvasHeight)
    }

    private static func fill(_ canvas: inout [UInt8], canvasWidth: Int, x0: Int, y0: Int, x1: Int, y1: Int,
                             colour: (UInt8, UInt8, UInt8, UInt8)) {
        guard x1 > x0, y1 > y0 else { return }
        for y in y0..<y1 {
            var i = (y * canvasWidth + x0) * 4
            for _ in x0..<x1 {
                canvas[i] = colour.0; canvas[i + 1] = colour.1; canvas[i + 2] = colour.2; canvas[i + 3] = colour.3
                i += 4
            }
        }
    }

    /// "#RRGGBB" → opaque RGBA8. The recipe schema guarantees the format; anything else is black.
    static func rgba(_ hex: String) -> (UInt8, UInt8, UInt8, UInt8) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF), 255)
    }
}
