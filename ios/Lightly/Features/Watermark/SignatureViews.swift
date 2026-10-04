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

    func clear() { strokes = [] }

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

/// `sigDraw`: Cancel · "Draw signature" · Save; the dashed pad with its baseline; Clear and the note.
struct DrawSignatureSheetContent: View {
    @Bindable var pad: SignaturePadModel
    let onCancel: () -> Void
    let onSave: (DrawnSignature) -> Void

    @Environment(\.colorScheme) private var colorScheme
    static let padHeight: CGFloat = 180

    var body: some View {
        VStack(spacing: 0) {
            SheetHead(title: "Draw signature", trailing: "Save", trailingIdentifier: "signature.draw.save", onCancel: onCancel) {
                if let signature = pad.signature { onSave(signature) }
            }
            padView
            // `display:flex;padding:0 10px`: Clear, then the note, stretched to the row height.
            HStack(alignment: .top, spacing: 0) {
                Button("Clear", action: pad.clear)
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("signature.draw.clear")
                Spacer(minLength: 0)
                Text("Saved for reuse. It keeps its own look.")
                    .approvedText(13)
                    .foregroundStyle(ApprovedColor.inkTertiary.resolved(colorScheme))
                    .padding(.horizontal, 18).padding(.vertical, 6)
            }
            .padding(.horizontal, 10)
        }
    }

    /// `.sigpad`: 180 pt, 1 pt dashed ink-3 border, radius 12, background colour; `.line` 20 pt in
    /// from each side, 40 pt above the bottom.
    private var padView: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(ApprovedColor.background.resolved(colorScheme))
            Rectangle().fill(ApprovedColor.hairline.resolved(colorScheme)).frame(height: 1)
                .padding(.horizontal, 20)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 40)
            Canvas { context, _ in
                // Pad points are drawn 1:1 (a unit view box at height 1).
                let drawing = DrawnSignature(strokes: pad.strokes, viewBox: .init(x: 0, y: 0, width: 1, height: 1),
                                             strokeWidth: SignaturePadModel.penWidth)
                context.stroke(Path(drawing.path(origin: .zero, height: 1)),
                               with: .color(ApprovedColor.ink.resolved(colorScheme)),
                               style: StrokeStyle(lineWidth: SignaturePadModel.penWidth, lineCap: .round, lineJoin: .round))
            }
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(ApprovedColor.inkTertiary.resolved(colorScheme), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .frame(height: Self.padHeight)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in pad.continueStroke(at: value.location) }
            .onEnded { _ in pad.endStroke() })
        .padding(.horizontal, 18).padding(.vertical, 12)
        .accessibilityElement()
        .accessibilityLabel(Text("Signature pad"))
        .accessibilityHint(Text("Draw your signature with one finger."))
        .accessibilityIdentifier("signature.pad")
    }

}

// MARK: - Import signature (approved `sigImport`)

/// `sigImport`: Cancel · "Import signature" · Use; the signature on paper colour with the dashed
/// selection; the note.
struct ImportSignatureSheetContent: View {
    /// The signature to use: PNG with the paper removed, or the photo as it is when no ink was found.
    let extracted: Data
    let onCancel: () -> Void
    let onUse: (Data) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            SheetHead(title: "Import signature", trailing: "Use", trailingIdentifier: "signature.import.use", onCancel: onCancel) {
                onUse(extracted)
            }
            // `margin:10px 18px;height:170px;border-radius:12px;background:#F7F4EE`, the signature
            // 70 pt tall centred, the dashed selection inset 14 pt (1.5 px, drawn 1 px as rendered).
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(red: 0xF7 / 255, green: 0xF4 / 255, blue: 0xEE / 255))
                if let image = WatermarkStage.image(from: extracted) {
                    // 70 pt tall as the prototype's sample; a wide photo is fitted inside the selection.
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: 70 * CGFloat(image.width) / CGFloat(max(image.height, 1)), maxHeight: 70)
                        .padding(.horizontal, 15)
                        .accessibilityLabel(Text("Imported signature"))
                }
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(ApprovedColor.selection.resolved(colorScheme), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .padding(14)
            }
            .frame(height: 170)
            .padding(.horizontal, 18).padding(.vertical, 10)
            ApprovedNote("The paper is removed. The ink keeps its original colour and texture.")
        }
    }
}

/// `.sheethead`: Cancel, the centred title in the remaining width, the trailing action.
struct SheetHead: View {
    let title: String
    let trailing: String
    let trailingIdentifier: String
    let onCancel: () -> Void
    let onTrailing: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            Button("Cancel", action: onCancel)
                .buttonStyle(SheetHeadQuietButtonStyle())
                .accessibilityIdentifier("sheet.cancel")
            Text(title)
                .approvedText(17, weight: .semibold)
                .foregroundStyle(ApprovedColor.ink.resolved(colorScheme))
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Button(trailing, action: onTrailing)
                .buttonStyle(SheetHeadQuietButtonStyle())
                .accessibilityIdentifier(trailingIdentifier)
        }
        .padding(.leading, 18).padding(.trailing, 8)
        .frame(minHeight: 44)
    }
}

/// `.btn.quiet` outside a sheet head: selection colour, 600 weight, 12 pt padding, 44 pt tall.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .approvedText(15, weight: .semibold)
            .foregroundStyle(ApprovedColor.selection.resolved(colorScheme))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
