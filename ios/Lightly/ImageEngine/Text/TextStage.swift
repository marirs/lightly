import CoreGraphics
import CoreText
import Foundation

/// Rendering-v2 stage 11, `text` (§7.4, owner amendment 2026-10-11): every layer of `tools.text` drawn into the frame,
/// after crop and effects and before the border, in preview and Save copy alike.
///
/// Every quantity is a fraction of the frame, so the same layout serves the stage (frame pixels) and the editor's
/// selection frame on the photo (displayed points): font size = size / 100 × 0.25 × the frame's short edge; the block's
/// lines are centred on one another, each line as tall as the font's ascent + descent + leading; the block's box is
/// centred on `centre` × the frame size and turned `rotation` degrees clockwise about that centre. Colour at
/// opacity / 100, source-over, no shadow or outline.
enum TextStage {

    /// `size / 100 × 0.25 × short edge`.
    static let shortEdgeFraction = 0.25

    /// One layer laid out in a frame of some size (pixels or points).
    struct Layout {
        let font: CTFont
        let fontSize: Double
        /// One per text line (a newline starts a new line; an empty line keeps its height).
        let lines: [CTLine]
        let lineWidths: [Double]
        let lineHeight: Double
        let ascent: Double
        /// The unrotated block: the widest line × the lines' total height.
        let blockSize: CGSize
        /// The block's centre in the frame.
        let centre: CGPoint
        /// Clockwise, in radians.
        let rotation: Double

        /// True when `point` (frame coordinates) falls on the turned block, grown by `slop` on every side.
        func contains(_ point: CGPoint, slop: Double = 0) -> Bool {
            let local = Self.unrotate(point, about: centre, by: rotation)
            return abs(local.x - centre.x) <= blockSize.width / 2 + slop && abs(local.y - centre.y) <= blockSize.height / 2 + slop
        }

        /// `point` turned back by `angle` (radians clockwise) about `centre`, into the block's own unrotated frame.
        static func unrotate(_ point: CGPoint, about centre: CGPoint, by angle: Double) -> CGPoint {
            let dx = point.x - centre.x, dy = point.y - centre.y
            let c = cos(-angle), s = sin(-angle)
            // y grows downwards, so a clockwise turn by θ maps (x, y) to (x cos θ − y sin θ, x sin θ + y cos θ).
            return CGPoint(x: centre.x + dx * c - dy * s, y: centre.y + dx * s + dy * c)
        }
    }

    static func fontSize(_ layer: EditRecipe.TextLayer, frameSize: CGSize) -> Double {
        layer.size / 100 * shortEdgeFraction * Double(min(frameSize.width, frameSize.height))
    }

    static func layout(_ layer: EditRecipe.TextLayer, frameSize: CGSize) -> Layout {
        let size = max(fontSize(layer, frameSize: frameSize), 0.01)
        let font = TextFonts.font(layer.font, size: CGFloat(size))
        let ascent = Double(CTFontGetAscent(font)), descent = Double(CTFontGetDescent(font)), leading = Double(CTFontGetLeading(font))
        let lineHeight = ascent + descent + leading
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let lines = layer.text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            CTLineCreateWithAttributedString(NSAttributedString(string: String(line), attributes: attributes))
        }
        // The advance width (typographic bounds), as §7.4 measures lines.
        let widths = lines.map { Double(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        let block = CGSize(width: widths.max() ?? 0, height: lineHeight * Double(lines.count))
        return Layout(font: font, fontSize: size, lines: lines, lineWidths: widths, lineHeight: lineHeight, ascent: ascent,
                      blockSize: block,
                      centre: CGPoint(x: layer.centre.x * Double(frameSize.width), y: layer.centre.y * Double(frameSize.height)),
                      rotation: layer.rotation * .pi / 180)
    }

    /// Draws every layer, in order (the last on top), into an RGBA8 sRGB frame.
    static func apply(_ text: EditRecipe.TextTool, pixels: inout [UInt8], width: Int, height: Int) {
        guard !text.layers.isEmpty, width > 0, height > 0 else { return }
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // Top-left origin, like the layout.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setShouldAntialias(true)
            for layer in text.layers where layer.opacity > 0 {
                draw(layer, frameSize: CGSize(width: width, height: height), in: context)
            }
        }
    }

    private static func draw(_ layer: EditRecipe.TextLayer, frameSize: CGSize, in context: CGContext) {
        let layout = layout(layer, frameSize: frameSize)
        let ink = WatermarkStage.cgColour(layer.colour)
        context.saveGState()
        // The whole layer at its opacity (a transparency layer, so overlapping glyphs do not darken each other).
        context.setAlpha(CGFloat(layer.opacity / 100))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.translateBy(x: layout.centre.x, y: layout.centre.y)
        // In this y-down context a positive angle turns clockwise on the photo.
        context.rotate(by: CGFloat(layout.rotation))
        // Glyphs are drawn upright with a flipped text matrix (the context is flipped).
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): layout.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink
        ]
        let lines = layer.text.split(separator: "\n", omittingEmptySubsequences: false)
        let top = -Double(layout.blockSize.height) / 2
        for (index, line) in lines.enumerated() {
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: String(line), attributes: attributes))
            context.textPosition = CGPoint(x: -layout.lineWidths[index] / 2, y: top + Double(index) * layout.lineHeight + layout.ascent)
            CTLineDraw(ctLine, context)
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
