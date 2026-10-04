import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Rendering-v2 stage 12, `watermark`: draws the watermark on the canvas, after the border, in
/// preview and export alike.
///
/// Size (owner ruling W1, contract revision 3): the approved screens draw the watermark at a fixed
/// on-screen size, text font 18 pt, signature height 26 pt, logo height 30 pt, each × size/34, in
/// the photo box, on every device. The stage therefore works in displayed points: `pixelsPerPoint`
/// is the photo's pixels per point of the photo as the editor displays it (photo short edge in
/// pixels ÷ displayed short edge in points). The preview uses the current stage layout; Save copy
/// and Share use the layout at the moment of saving, so the copy matches the screen.
///
/// On the photo the watermark's box is anchored at 6/50/94 % of the photo, or at the dragged
/// `offset`; on a border it is centred in the bottom margin, its box bottom 6 % (polaroid) or 1 %
/// (other borders) of the canvas height above the canvas bottom, in #222222 ink on a polaroid.
///
/// The box follows the prototype's `.wm` element (CSS `line-height: 1` inside a 15 px strut):
/// the line box reaches at least 13 CSS px above the baseline and 2 CSS px below it, so an
/// inline SVG (signature, logo) sits 2 px above the box bottom and text keeps its half-leading.
/// One CSS px is one displayed point.
enum WatermarkStage {

    /// Before the editor has measured its stage (tests, headless renders): a photo displayed with
    /// a 289 pt short edge, the median of the approved phone screens (contract revision 2).
    static let fallbackDisplayShortEdgePoints = 289.2

    /// Photo pixels per displayed point, from the photo's short edge in pixels and in points.
    static func pixelsPerPoint(imageShortEdgePixels: Double, displayShortEdgePoints: Double?) -> Double {
        imageShortEdgePixels / max(displayShortEdgePoints ?? fallbackDisplayShortEdgePoints, 1)
    }

    /// The prototype's px sizes at size 34 (`watermarkHTML`): text 18, signature 26, logo 30.
    static let prototypePixels = (text: 18.0, signature: 26.0, logo: 30.0)
    static let anchors = [0.06, 0.5, 0.94]
    static let polaroidInk = "#222222"
    /// The `.wm` strut: 15 px SF at line-height 15 px puts 13 px above the baseline, 2 px below.
    static let strutAbove = 13.0, strutBelow = 2.0
    /// `.wm` text-shadow `0 1px 2px rgba(0,0,0,.35)`, on the photo only (none on a border).
    static let shadowOffset = 1.0, shadowBlur = 2.0, shadowAlpha = 0.35
    /// The prototype draws its drawn signature at 2.4 / 50 of its height, and the sample's view box.
    static let sampleSignatureViewBox = DrawnSignature.Box(x: 0, y: 0, width: 170, height: 50)

    /// What the watermark shows, resolved from the recipe (a missing or changed saved signature
    /// resolves to nothing: the stage then draws nothing, never a substitute).
    enum Content: Equatable, Sendable {
        case drawnSignature(DrawnSignature)
        /// PNG with the paper removed; it keeps its own ink.
        case importedSignature(Data)
        case text(String, EditRecipe.Watermark.Font)
        /// The bundled sample logo (prototype `LOGO`: a ring and the initials "AR").
        case sampleLogo
        /// A logo image the person chose; it keeps its own colours.
        case logoImage(Data)
    }

    /// The bundled logo's asset id in the recipe (`assetRef` kind `bundled`).
    static let sampleLogoID = "logo-sample-ar"

    // MARK: - Geometry

    /// One watermark's box in canvas pixels (origin top-left) and where its content sits in it.
    struct Layout: Equatable {
        /// The `.wm` box.
        var box: CGRect
        /// The content's baseline (text) or bottom edge (signature, logo), canvas y.
        var baseline: Double
        /// One prototype CSS px, in canvas pixels.
        var cssPixel: Double
        var onBorder: Bool
        /// "#RRGGBB" the ink is drawn in (ignored by content that keeps its own ink).
        var ink: String
    }

    /// The content's own extent around its baseline: width, ascent above and descent below.
    struct Extent: Equatable {
        var width: Double
        var above: Double
        var below: Double
    }

    enum Kind { case text, signature, logo }

    static func kind(of content: Content) -> Kind {
        switch content {
        case .drawnSignature, .importedSignature: .signature
        case .text: .text
        case .sampleLogo, .logoImage: .logo
        }
    }

    /// The type's main size at `size`, in photo pixels: the text's font size, or the signature's
    /// or logo's height (18 / 26 / 30 pt × size/34 on screen).
    static func mainSize(_ kind: Kind, size: Double, pixelsPerPoint: Double) -> Double {
        let points: Double
        switch kind {
        case .text: points = prototypePixels.text
        case .signature: points = prototypePixels.signature
        case .logo: points = prototypePixels.logo
        }
        return points * size / 34 * pixelsPerPoint
    }

    /// The anchor point as fractions of the photo: the dragged offset, else the position's anchor.
    static func anchor(_ watermark: EditRecipe.Watermark) -> (x: Double, y: Double) {
        if let offset = watermark.offset { return (offset.x, offset.y) }
        let position = min(max(watermark.position, 0), 8)
        return (anchors[position % 3], anchors[position / 3])
    }

    /// The prototype's `tx`/`ty` rule: below 30 % the box starts at the anchor, above 70 % it ends
    /// there, otherwise it is centred on it (applied to a dragged offset too).
    static func alignmentFraction(_ coordinate: Double) -> Double {
        coordinate < 0.30 ? 0 : coordinate > 0.70 ? 1 : 0.5
    }

    /// Whether the watermark goes on the border: placement border, and a border is set.
    static func isOnBorder(_ watermark: EditRecipe.Watermark, border: EditRecipe.Border.Kind) -> Bool {
        watermark.placement == .border && border != .none
    }

    static func layout(_ watermark: EditRecipe.Watermark, kind: Kind, extent: Extent, canvasSize: CGSize,
                       imageRect: CGRect, border: EditRecipe.Border.Kind, pixelsPerPoint: Double) -> Layout {
        let px = pixelsPerPoint
        let above = max(extent.above, strutAbove * px), below = max(extent.below, strutBelow * px)
        let height = above + below
        let onBorder = isOnBorder(watermark, border: border)
        let x: Double, top: Double
        if onBorder {
            let fromBottom = border == .polaroid ? 0.06 : 0.01
            x = Double(canvasSize.width) / 2 - extent.width / 2
            top = Double(canvasSize.height) * (1 - fromBottom) - height
        } else {
            let a = anchor(watermark)
            let ax = Double(imageRect.minX) + a.x * Double(imageRect.width)
            let ay = Double(imageRect.minY) + a.y * Double(imageRect.height)
            x = ax - alignmentFraction(a.x) * extent.width
            top = ay - alignmentFraction(a.y) * height
        }
        let ink = border == .polaroid && onBorder ? polaroidInk : watermark.colour
        return Layout(box: CGRect(x: x, y: top, width: extent.width, height: height), baseline: top + above,
                      cssPixel: px, onBorder: onBorder, ink: ink)
    }

    /// The content's extent at `size` on a photo with this short edge.
    static func extent(of content: Content, size: Double, pixelsPerPoint: Double) -> Extent {
        let kind = kind(of: content)
        let main = mainSize(kind, size: size, pixelsPerPoint: pixelsPerPoint)
        switch content {
        case .text(let text, let font):
            let ctFont = textFont(font, size: main, cssPixel: pixelsPerPoint, watermarkSize: size)
            let line = textLine(text, font: ctFont, colour: CGColor(gray: 1, alpha: 1))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            // CSS `line-height: 1`: the inline box is one font size tall, the font's ascent and
            // descent centred in it (half-leading).
            let ascent = Double(CTFontGetAscent(ctFont)), descent = Double(CTFontGetDescent(ctFont))
            let above = (main - (ascent + descent)) / 2 + ascent
            return Extent(width: width, above: above, below: main - above)
        case .drawnSignature(let drawn):
            return Extent(width: main * drawn.viewBox.width / drawn.viewBox.height, above: main, below: 0)
        case .importedSignature(let data), .logoImage(let data):
            let aspect = image(from: data).map { Double($0.width) / Double(max($0.height, 1)) } ?? 0
            return Extent(width: main * aspect, above: main, below: 0)
        case .sampleLogo:
            return Extent(width: main, above: main, below: 0)
        }
    }

    // MARK: - Rendering

    /// Draws the watermark onto an RGBA8 canvas in place. `imageRect` is the photo inside the
    /// border, in canvas pixels (origin top-left).
    static func apply(_ watermark: EditRecipe.Watermark, content: Content?, pixels: inout [UInt8],
                      canvasWidth: Int, canvasHeight: Int, imageRect: CGRect, border: EditRecipe.Border.Kind,
                      displayShortEdgePoints: Double?) {
        guard watermark.type != .none, let content, canvasWidth > 0, canvasHeight > 0, watermark.opacity > 0 else { return }
        let shortEdge = Double(min(imageRect.width, imageRect.height))
        guard shortEdge > 0 else { return }
        let ppp = pixelsPerPoint(imageShortEdgePixels: shortEdge, displayShortEdgePoints: displayShortEdgePoints)
        let kind = kind(of: content)
        let extent = extent(of: content, size: watermark.size, pixelsPerPoint: ppp)
        let layout = layout(watermark, kind: kind, extent: extent, canvasSize: CGSize(width: canvasWidth, height: canvasHeight),
                            imageRect: imageRect, border: border, pixelsPerPoint: ppp)
        let main = mainSize(kind, size: watermark.size, pixelsPerPoint: ppp)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8,
                                          bytesPerRow: canvasWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // Top-left origin, like the layout.
            context.translateBy(x: 0, y: CGFloat(canvasHeight))
            context.scaleBy(x: 1, y: -1)
            context.setAlpha(CGFloat(watermark.opacity / 100))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            draw(content, layout: layout, main: main, watermarkSize: watermark.size, in: context)
            context.endTransparencyLayer()
        }
    }

    private static func draw(_ content: Content, layout: Layout, main: Double, watermarkSize: Double, in context: CGContext) {
        let ink = cgColour(layout.ink)
        let left = Double(layout.box.minX), bottom = layout.baseline
        switch content {
        case .text(let text, let font):
            let ctFont = textFont(font, size: main, cssPixel: layout.cssPixel, watermarkSize: watermarkSize)
            withTextShadow(layout, in: context) {
                drawLine(textLine(text, font: ctFont, colour: ink), x: left, baseline: bottom, in: context)
            }
        case .drawnSignature(let drawn):
            drawStrokes(drawn, rect: CGRect(x: left, y: bottom - main, width: layout.box.width, height: main), ink: ink, in: context)
        case .importedSignature(let data), .logoImage(let data):
            guard let image = image(from: data) else { return }
            // CGContext.draw puts the image's first row at the rect's bottom in a flipped context:
            // flip locally so the image stays upright.
            let rect = CGRect(x: left, y: bottom - main, width: layout.box.width, height: main)
            context.saveGState()
            context.translateBy(x: 0, y: rect.maxY + rect.minY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            context.restoreGState()
        case .sampleLogo:
            drawSampleLogo(origin: CGPoint(x: left, y: bottom - main), height: main, ink: ink, shadow: layout, in: context)
        }
    }

    /// The prototype's `LOGO`: in a 64-unit view box, a ring r 27 (stroke 3) and "AR" in Inter
    /// 700, size 22, centred, baseline 40. CSS text-shadow reaches the SVG text on the photo, not
    /// the ring. `context` must be flipped (y down). Also draws the panel's logo chip.
    static func drawSampleLogo(origin: CGPoint, height: Double, ink: CGColor, shadow: Layout?, in context: CGContext) {
        let unit = height / 64
        context.setStrokeColor(ink)
        context.setLineWidth(3 * unit)
        context.strokeEllipse(in: CGRect(x: Double(origin.x) + 5 * unit, y: Double(origin.y) + 5 * unit, width: 54 * unit, height: 54 * unit))
        let cssPixels = shadow.map { 22 * unit / $0.cssPixel } ?? 22 * unit
        let font = WatermarkFonts.logoInitials(size: 22 * unit, cssPixels: cssPixels)
        let line = textLine("AR", font: font, colour: ink)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let drawText = { drawLine(line, x: Double(origin.x) + 32 * unit - width / 2, baseline: Double(origin.y) + 40 * unit, in: context) }
        if let shadow { withTextShadow(shadow, in: context, draw: drawText) } else { drawText() }
    }

    /// A drawn signature (prototype `sigSvg`): round caps and joins, its own stroke proportion.
    private static func drawStrokes(_ drawn: DrawnSignature, rect: CGRect, ink: CGColor, in context: CGContext) {
        context.addPath(drawn.path(origin: rect.origin, height: Double(rect.height)))
        context.setStrokeColor(ink)
        context.setLineWidth(drawn.lineWidth(atHeight: Double(rect.height)))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }

    private static func withTextShadow(_ layout: Layout, in context: CGContext, draw: () -> Void) {
        guard !layout.onBorder else { return draw() }
        context.saveGState()
        // Shadow offsets are in the device space (y up), unaffected by the flip: down is −y.
        context.setShadow(offset: CGSize(width: 0, height: -shadowOffset * layout.cssPixel), blur: shadowBlur * layout.cssPixel,
                          color: CGColor(gray: 0, alpha: shadowAlpha))
        draw()
        context.restoreGState()
    }

    private static func drawLine(_ line: CTLine, x: Double, baseline: Double, in context: CGContext) {
        context.saveGState()
        // The context is flipped (y down); glyphs are drawn upright with a flipped text matrix.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func textFont(_ font: EditRecipe.Watermark.Font, size: Double, cssPixel: Double, watermarkSize: Double) -> CTFont {
        WatermarkFonts.font(font, size: CGFloat(size), cssPixels: CGFloat(prototypePixels.text * watermarkSize / 34))
    }

    private static func textLine(_ text: String, font: CTFont, colour: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func cgColour(_ hex: String) -> CGColor {
        let rgba = BorderStage.rgba(hex)
        return CGColor(srgbRed: CGFloat(rgba.0) / 255, green: CGFloat(rgba.1) / 255, blue: CGFloat(rgba.2) / 255, alpha: 1)
    }
}
