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
        case .solid: let w = border.width / 100; return Insets(side: w, top: w, bottom: w)
        case .frame: let t = (border.width + border.spacing) / 100; return Insets(side: t, top: t, bottom: t)
        case .polaroid: return Insets(side: 0.055, top: 0.055, bottom: 0.24)
        }
    }

    /// RGBA8 frame in, RGBA8 canvas out. Inset pixel sizes are rounded from the frame width.
    static func apply(_ border: EditRecipe.Border, pixels: [UInt8], width: Int, height: Int)
        -> (pixels: [UInt8], width: Int, height: Int) {
        guard border.type != .none, width > 0, height > 0 else { return (pixels, width, height) }
        let insets = insets(border)
        let side = Int((insets.side * Double(width)).rounded())
        let top = Int((insets.top * Double(width)).rounded())
        let bottom = Int((insets.bottom * Double(width)).rounded())
        let canvasWidth = width + 2 * side
        let canvasHeight = height + top + bottom
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
