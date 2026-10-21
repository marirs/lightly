import SwiftUI

/// A saved signature drawn at a height (prototype `sigSvg(h, colour, imported)`): a drawn one in
/// the current foreground colour (or `ink`), an imported one in its own ink.
struct SignatureGlyph: View {
    let signature: SavedSignature
    let height: CGFloat
    /// nil: the foreground style (CSS `currentColor`).
    var ink: Color?

    var body: some View {
        switch signature.kind {
        case .drawn:
            if let drawn = signature.drawn { DrawnSignatureShape(drawn: drawn, height: height, ink: ink) }
        case .imported:
            if let image = WatermarkStage.image(from: signature.data) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: height * CGFloat(image.width) / CGFloat(max(image.height, 1)), height: height)
            }
        }
    }
}

/// A drawn signature's strokes at `height` (round caps and joins, its own stroke proportion).
struct DrawnSignatureShape: View {
    let drawn: DrawnSignature
    let height: CGFloat
    var ink: Color?

    var body: some View {
        let path = Path(drawn.path(origin: .zero, height: Double(height)))
        let style = StrokeStyle(lineWidth: CGFloat(drawn.lineWidth(atHeight: Double(height))), lineCap: .round, lineJoin: .round)
        Group {
            if let ink { path.stroke(ink, style: style) } else { path.stroke(style: style) }
        }
        .frame(width: height * CGFloat(drawn.aspectRatio), height: height, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

// MARK: - Draw signature (approved `sigDraw`)

/// The drawing being made on the pad: strokes in pad points.
@MainActor
@Observable
final class SignaturePadModel {
    var strokes: [[DrawnSignature.Point]] = []
    /// The prototype's pad sample is drawn at 70 pt with the 2.4 / 50 stroke: 3.36 pt.
    static let penWidth = 70 * DrawnSignature.strokeWidthPerHeight

    var isEmpty: Bool { strokes.allSatisfy(\.isEmpty) }

    /// True while a finger is down: the points go to the last stroke.
    private var isDrawing = false

    func clear() { strokes = []; isDrawing = false }

    func continueStroke(at location: CGPoint) {
        let point = DrawnSignature.Point(x: Double(location.x), y: Double(location.y))
        if isDrawing { strokes[strokes.count - 1].append(point) } else { strokes.append([point]); isDrawing = true }
    }

    func endStroke() { isDrawing = false }

    var signature: DrawnSignature? { DrawnSignature.fromPad(strokes: strokes, penWidth: Self.penWidth) }

    #if DEBUG
    /// Design captures of `wm-sig-draw`: the prototype's sample at `left:24px;bottom:34px`, 70 pt
    /// tall, on a pad of `padHeight` (outer size, border included).
    func debugFillWithPrototypeSample(padHeight: Double) {
        let sample = DrawnSignature.prototypeSample
        let scale = 70 / sample.viewBox.height
        // `position:absolute` is measured from the pad's padding box (inside its 1 px border), and the
        // inline SVG sits 2 px above its div's bottom (the line box's strut).
        let top = padHeight - 1 - 34 - 2 - 70
        strokes = sample.strokes.map { $0.map { DrawnSignature.Point(x: 1 + 24 + $0.x * scale, y: top + $0.y * scale) } }
    }
    #endif
}

/// `sigDraw` (Lightly 2): sheetHead (Cancel · Draw signature · Save); the pad (180 pt, 18 pt corners, --bg, 1.5 pt
/// dashed ink3 border, a hairline baseline 20 pt in and 40 pt up), 4/16 pt margins; then Clear and the note, 6/16 pt.
struct DrawSignatureSheetContent: View {
    @Bindable var pad: SignaturePadModel
    let onCancel: () -> Void
    let onSave: (DrawnSignature) -> Void

    @Environment(\.colorScheme) private var colorScheme
    static let padHeight: CGFloat = 180

    var body: some View {
        VStack(spacing: 0) {
            L2SheetHeader(title: Text("Draw signature"),
                          leading: { L2TextButton(title: "Cancel", identifier: "sheet.cancel", action: onCancel) },
                          trailing: { L2TextButton(title: "Save", isBold: true, identifier: "signature.draw.save") {
                              if let signature = pad.signature { onSave(signature) } } })
            padView
            HStack(spacing: 10) {
                Button("Clear", action: pad.clear)
                    .buttonStyle(L2QuietButtonStyle())
                    .accessibilityIdentifier("signature.draw.clear")
                Spacer(minLength: 0)
                L2Note("Saved for reuse. It keeps its own look.").fixedSize()
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
        }
    }

    private var padView: some View {
        let c = L2(scheme: colorScheme)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(c(ApprovedColor.background))
            Rectangle().fill(c(ApprovedColor.hairline)).frame(height: 1)
                .padding(.horizontal, 20)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 40)
            Canvas { context, _ in
                // Pad points are drawn 1:1 (a unit view box at height 1).
                let drawing = DrawnSignature(strokes: pad.strokes, viewBox: .init(x: 0, y: 0, width: 1, height: 1),
                                             strokeWidth: SignaturePadModel.penWidth)
                context.stroke(Path(drawing.path(origin: .zero, height: 1)),
                               with: .color(c(ApprovedColor.ink)),
                               style: StrokeStyle(lineWidth: SignaturePadModel.penWidth, lineCap: .round, lineJoin: .round))
            }
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(c(ApprovedColor.inkTertiary), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        .frame(height: Self.padHeight)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in pad.continueStroke(at: value.location) }
            .onEnded { _ in pad.endStroke() })
        .padding(.horizontal, 16).padding(.vertical, 4)
        .accessibilityElement()
        .accessibilityLabel(Text("Signature pad"))
        .accessibilityHint(Text("Draw your signature with one finger."))
        .accessibilityIdentifier("signature.pad")
    }
}

// MARK: - Import signature

/// `sigImport` (Lightly 2): sheetHead (Cancel · Import signature · Use); the signature on #F7F4EE (170 pt, 18 pt
/// corners) with the 1.5 pt dashed accent selection inset 14 pt; the note (8/16 pt).
struct ImportSignatureSheetContent: View {
    /// The signature to use: PNG with the paper removed, or the photo as it is when no ink was found.
    let extracted: Data
    let onCancel: () -> Void
    let onUse: (Data) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let c = L2(scheme: colorScheme)
        VStack(spacing: 0) {
            L2SheetHeader(title: Text("Import signature"),
                          leading: { L2TextButton(title: "Cancel", identifier: "sheet.cancel", action: onCancel) },
                          trailing: { L2TextButton(title: "Use", isBold: true, identifier: "signature.import.use") { onUse(extracted) } })
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: 0xF7F4EE))
                if let image = WatermarkStage.image(from: extracted) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: 150, maxHeight: 70)
                        .accessibilityLabel(Text("Imported signature"))
                }
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(c(ApprovedColor.selection), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .padding(14)
            }
            .frame(height: 170)
            .padding(.horizontal, 16).padding(.vertical, 4)
            L2Note("The paper is removed. The ink keeps its original colour and texture.")
                .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}
