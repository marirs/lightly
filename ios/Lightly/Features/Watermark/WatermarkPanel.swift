import PhotosUI
import SwiftUI

/// UI state of the Watermark panel (approved `watermarkPanel`: prototype `ui.sub || s.wm.type`).
@MainActor
@Observable
final class WatermarkPanelModel {
    let session: EditorSession
    let signatures: SignatureStore
    /// The tab shown; nil follows the recipe's type (`ui.sub || w.type`). The Signature tab can be
    /// shown while no signature is saved yet (the recipe cannot hold a signature watermark without
    /// one), until one is drawn or imported.
    var shownType: EditRecipe.Watermark.Kind?

    enum Sheet: Equatable {
        case draw
        /// The import sheet, with the signature to use (paper removed, or the photo as it is).
        case importSignature(Data)
    }

    var sheet: Sheet?
    let pad = SignaturePadModel()
    var isPickingSignaturePhoto = false
    var isPickingLogo = false
    /// "Signature on the margin" was switched on with no saved signature: the drawing saved next
    /// goes on the margin.
    var placesNextSignatureOnBorder = false

    /// The last text and logo used in this session, so switching tabs and back keeps them (the
    /// recipe holds only the part matching its type).
    @ObservationIgnored private var lastText = EditRecipe.Watermark.Text(text: WatermarkPanelModel.defaultText, font: .allura)
    @ObservationIgnored private var lastLogo: EditRecipe.AssetRef = .bundled(id: WatermarkStage.sampleLogoID)

    // Owner question W10: the prototype has no message for an import with nothing to use; these
    // reuse the approved toast and the wording of "This photo can’t be opened".
    static let blankImportMessage = "No signature found in that photo"
    static let unreadableImportMessage = "That photo can’t be opened"

    /// The prototype's sample text (`newSession`: `text:'A. Rivera'`); owner question W5.
    static let defaultText = "A. Rivera"
    static let colours = ["#FFFFFF", "#111111", "#C9A27E", "#8A8A8F"]
    static let positionNames = ["Top left", "Top", "Top right", "Left", "Centre", "Right", "Bottom left", "Bottom", "Bottom right"]

    init(session: EditorSession, signatures: SignatureStore) {
        self.session = session
        self.signatures = signatures
    }

    var watermark: EditRecipe.Watermark { session.recipe.tools.watermark }
    var border: EditRecipe.Border { session.recipe.tools.border }
    var selectedType: EditRecipe.Watermark.Kind { shownType ?? watermark.type }
    /// Prototype `toolUsed(s, 'watermark')`.
    var isUsed: Bool { watermark.type != .none }
    var hasBorder: Bool { border.type != .none }
    var isOnBorder: Bool { watermark.placement == .border && hasBorder }

    /// The chosen saved signature's kind (`w.sig`); drawn when none is chosen yet.
    var signatureKind: SignatureKind { watermark.signature?.kind ?? .drawn }

    // MARK: - Type (prototype `wmType`)

    func choose(_ type: EditRecipe.Watermark.Kind) {
        shownType = type
        switch type {
        case .none:
            session.commitWatermark { Self.setType(.none, on: &$0) }
        case .signature:
            if watermark.type == .signature { return }
            guard let saved = signatures.drawn ?? signatures.imported else { return }
            session.commitWatermark { w in Self.setType(.signature, on: &w); w.signature = saved.reference }
        case .text:
            let text = watermark.text ?? lastText
            session.commitWatermark { w in Self.setType(.text, on: &w); w.text = text }
        case .logo:
            let logo = watermark.logo ?? lastLogo
            session.commitWatermark { w in Self.setType(.logo, on: &w); w.logo = logo }
        }
    }

    /// The reader rule: exactly the part matching `type` is set.
    static func setType(_ type: EditRecipe.Watermark.Kind, on watermark: inout EditRecipe.Watermark) {
        watermark.type = type
        if type != .signature { watermark.signature = nil }
        if type != .text { watermark.text = nil }
        if type != .logo { watermark.logo = nil }
    }

    // MARK: - Signature

    func chooseSignature(_ kind: SignatureKind) {
        guard let saved = signatures.signature(of: kind) else { return }
        session.commitWatermark { w in Self.setType(.signature, on: &w); w.signature = saved.reference }
    }

    func clearSignature() {
        session.commitWatermark { Self.setType(.none, on: &$0) }
    }

    func deleteDrawnSignature() {
        if watermark.type == .signature && watermark.signature?.kind == .drawn { clearSignature() }
        signatures.delete(.drawn)
    }

    func openDraw() {
        pad.clear()
        sheet = .draw
    }

    /// `saveSig`: the drawing becomes the saved drawn signature and the watermark uses it (one
    /// undo step), with the toast "Signature saved for reuse".
    func saveDrawn(_ drawing: DrawnSignature) {
        let saved = signatures.saveDrawn(drawing)
        useSignature(saved)
        sheet = nil
        session.showStageToast("Signature saved for reuse")
    }

    /// `saveSigImported`: the extracted signature becomes the saved imported one, and is used.
    func useImported(_ png: Data) {
        let saved = signatures.saveImported(png: png)
        useSignature(saved)
        sheet = nil
    }

    private func useSignature(_ saved: SavedSignature) {
        shownType = .signature
        let toBorder = placesNextSignatureOnBorder && hasBorder
        placesNextSignatureOnBorder = false
        session.commitWatermark { w in
            Self.setType(.signature, on: &w)
            w.signature = saved.reference
            if toBorder { w.placement = .border }
        }
    }

    /// A photo was chosen for Import: the paper is removed off the main actor, then the sheet shows.
    func importSignature(from item: PhotosPickerItem) {
        Task { [weak self] in
            let data = try? await item.loadTransferable(type: Data.self)
            let result = await Task.detached(priority: .userInitiated) { () -> SignatureInkExtractor.ImportResult in
                SignatureInkExtractor.importSignature(from: data.flatMap(Self.uprightImage))
            }.value
            guard let self else { return }
            switch result {
            case .inkFound(let png), .asIs(let png): sheet = .importSignature(png)
            // Never silent, never an empty rectangle.
            case .blank: session.showStageToast(Self.blankImportMessage)
            case .unreadable: session.showStageToast(Self.unreadableImportMessage)
            }
        }
    }

    // MARK: - Logo

    /// Replace logo: the chosen image (its own colours) becomes the logo, stored by digest.
    func replaceLogo(with item: PhotosPickerItem) {
        Task { [weak self] in
            let data = try? await item.loadTransferable(type: Data.self)
            let png = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let data, let image = Self.uprightImage(data) else { return nil }
                return SignatureInkExtractor.logoPNG(from: image)
            }.value
            guard let self, let png else { return }
            let digest = signatures.saveLogo(png: png)
            lastLogo = .file(sha256: digest)
            session.commitWatermark { w in Self.setType(.logo, on: &w); w.logo = .file(sha256: digest) }
        }
    }

    nonisolated static func uprightImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 2_400]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Text

    func setText(_ value: String) {
        let trimmed = String(value.prefix(80))
        guard !trimmed.trimmingCharacters(in: .whitespaces).isEmpty, var text = watermark.text else { return }
        text.text = trimmed
        lastText = text
        session.commitWatermark { $0.text = text }
    }

    func chooseFont(_ font: EditRecipe.Watermark.Font) {
        guard var text = watermark.text else { return }
        text.font = font
        lastText = text
        session.commitWatermark { $0.text = text }
    }

    // MARK: - Placement, position, size, opacity, colour

    func setPlacement(_ placement: EditRecipe.Watermark.Placement) {
        session.commitWatermark { $0.placement = placement }
    }

    /// The Position row cycles the nine anchors (`set:wm.pos=(pos+1)%9`); a dragged position is
    /// replaced by the anchor, since the offset would otherwise override it.
    func cyclePosition() {
        session.commitWatermark { w in
            w.position = (w.position + 1) % 9
            w.offset = nil
        }
    }

    func setColour(_ hex: String) {
        session.commitWatermark { $0.colour = hex }
    }

    /// Dragging the watermark on the photo: its anchor follows the finger (photo fractions,
    /// clamped to the photo). Preview while dragging, one undo step at the end.
    func canvasAnchor(size: CGSize) -> (x: Double, y: Double) {
        guard let content = session.watermarkContent(for: watermark) else { return (0.5, 0.5) }
        let box = session.displayedImageBox
        let rect = CGRect(x: box.minX * size.width, y: box.minY * size.height,
                          width: box.width * size.width, height: box.height * size.height)
        let extent = WatermarkStage.extent(of: content, size: watermark.size, pixelsPerPoint: 1)
        let layout = WatermarkStage.layout(watermark, kind: WatermarkStage.kind(of: content), extent: extent,
            canvasSize: size, imageRect: rect, border: border.type, pixelsPerPoint: 1)
        return (layout.box.midX / max(size.width, 1), layout.box.midY / max(size.height, 1))
    }

    func dragAnchor(from start: (x: Double, y: Double), by translation: CGSize, imageSize: CGSize, final: Bool) {
        let x = min(max(start.x + Double(translation.width / max(imageSize.width, 1)), 0), 1)
        let y = min(max(start.y + Double(translation.height / max(imageSize.height, 1)), 0), 1)
        if final { session.commitWatermark { $0.placement = .canvas; $0.offset = .init(x: x, y: y) } } else { session.previewWatermark { $0.placement = .canvas; $0.offset = .init(x: x, y: y) } }
    }
}

/// The approved Watermark panel: None, Signature, Text, Logo.
struct WatermarkPanelView: View {
    @Bindable var model: WatermarkPanelModel
    let roomy: Bool
    let wraps: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmsDeleteDrawing = false
    @State private var signaturePhoto: PhotosPickerItem?
    @State private var logoPhoto: PhotosPickerItem?
    @State private var editedText = ""
    @FocusState private var isEditingText: Bool

    private var session: EditorSession { model.session }
    private var watermark: EditRecipe.Watermark { model.watermark }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if roomy { PanelTitle(text: "Watermark") }
            PanelTabs(items: [(EditRecipe.Watermark.Kind.none, "None", false), (.signature, "Signature", false),
                              (.text, "Text", false), (.logo, "Logo", false)],
                      selected: model.selectedType, wraps: wraps, identifierPrefix: "watermark.type") { model.choose($0) }
            PanelResetRow(session: model.session, section: "watermark", title: "Watermark")
            switch model.selectedType {
            case .none: ApprovedNote("No watermark. Choose Signature, Text or Logo to add one.")
            case .signature: signature
            case .text: text
            case .logo: logo
            }
        }
        .photosPicker(isPresented: $model.isPickingSignaturePhoto, selection: $signaturePhoto, matching: .images)
        .photosPicker(isPresented: $model.isPickingLogo, selection: $logoPhoto, matching: .images)
        .onChange(of: signaturePhoto) { _, item in
            guard let item else { return }
            signaturePhoto = nil
            model.importSignature(from: item)
        }
        .onChange(of: logoPhoto) { _, item in
            guard let item else { return }
            logoPhoto = nil
            model.replaceLogo(with: item)
        }
    }

    // MARK: Signature

    @ViewBuilder
    private var signature: some View {
        let chosen = watermark.type == .signature ? watermark.signature?.kind : nil
        ChipRow {
            if let drawn = model.signatures.drawn {
                OptionChip(isOn: chosen == .drawn, identifier: "watermark.signature.drawn", minWidth: 120,
                           action: { model.chooseSignature(.drawn) }) { SignatureGlyph(signature: drawn, height: 26) }
                    .accessibilityLabel(Text("Drawn signature"))
                Menu {
                    Button("Draw replacement", action: model.openDraw)
                    Button("Delete saved signature", role: .destructive) { confirmsDeleteDrawing = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 18))
                        .foregroundStyle(ApprovedColor.inkSecondary.resolved(colorScheme))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Manage saved signature")
                .accessibilityIdentifier("watermark.signature.manage")
                .confirmationDialog("Delete saved signature?", isPresented: $confirmsDeleteDrawing, titleVisibility: .visible) {
                    Button("Delete signature", role: .destructive, action: model.deleteDrawnSignature)
                } message: { Text("This removes the saved drawing and its signature from this photo.") }
            }
            if let imported = model.signatures.imported {
                OptionChip(isOn: chosen == .imported, identifier: "watermark.signature.imported", minWidth: 120,
                           action: { model.chooseSignature(.imported) }) { SignatureGlyph(signature: imported, height: 26) }
                    .accessibilityLabel(Text("Imported signature"))
            }
            if chosen != nil {
                Button("Clear", action: model.clearSignature)
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityLabel("Clear signature from photo")
                    .accessibilityIdentifier("watermark.signature.clear")
            }
            OptionChip(isOn: false, identifier: "watermark.signature.draw", action: model.openDraw) {
                ApprovedIconView(icon: .plus, size: 18); Text("Draw").approvedText(15)
            }
            OptionChip(isOn: false, identifier: "watermark.signature.import", action: { model.isPickingSignaturePhoto = true }) {
                ApprovedIconView(icon: .photo, size: 18); Text("Import").approvedText(15)
            }
        }
        ApprovedNote(verbatim: String(localized: "Saved signatures keep their own look. ")
            + (model.signatureKind == .drawn ? String(localized: "You can change the ink colour of a drawn signature.")
                                             : String(localized: "An imported signature keeps its own ink.")))
        commonControls(colours: model.signatureKind == .drawn)
    }

    // MARK: Text

    @ViewBuilder
    private var text: some View {
        let current = watermark.text ?? .init(text: WatermarkPanelModel.defaultText, font: .allura)
        // `.listrow` with `border:0`: "Text" in ink-2, the text itself at the end in ink. The value
        // is editable in place.
        HStack(spacing: 12) {
            Text("Text").approvedText(15).foregroundStyle(ApprovedColor.inkSecondary.resolved(colorScheme))
            TextField("", text: $editedText)
                .focused($isEditingText)
                .multilineTextAlignment(.trailing)
                .approvedText(15)
                .foregroundStyle(ApprovedColor.ink.resolved(colorScheme))
                .submitLabel(.done)
                .onSubmit { model.setText(editedText) }
                .onChange(of: isEditingText) { _, editing in if !editing { model.setText(editedText) } }
                .accessibilityLabel(Text("Watermark text"))
                .accessibilityIdentifier("watermark.text.value")
        }
        .padding(.horizontal, ApprovedMetrics.rowHorizontalPadding)
        .frame(maxWidth: .infinity, minHeight: ApprovedMetrics.rowMinimumHeight)
        .onAppear { editedText = current.text }
        .onChange(of: current.text) { _, value in if !isEditingText { editedText = value } }
        ChipRow {
            ForEach(EditRecipe.Watermark.Font.allCases, id: \.self) { font in
                FontOption(text: current.text, font: font, isOn: current.font == font) { model.chooseFont(font) }
            }
        }
        commonControls(colours: true)
    }

    // MARK: Logo

    @ViewBuilder
    private var logo: some View {
        ChipRow {
            // `span.opt.on`: the current logo, not a button.
            HStack(spacing: 6) {
                LogoGlyph(logo: watermark.logo ?? .bundled(id: WatermarkStage.sampleLogoID), store: model.signatures, height: 26,
                          ink: UIColor(ApprovedColor.selection.resolved(colorScheme)).cgColor)
            }
                .frame(minWidth: 18, minHeight: 44)
                .padding(.horizontal, 13)
                .background(RoundedRectangle(cornerRadius: 10).fill(selectionSoft))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ApprovedColor.selection.resolved(colorScheme), lineWidth: 1))
                .accessibilityElement()
                .accessibilityLabel(Text("Current logo"))
                .accessibilityIdentifier("watermark.logo.current")
            OptionChip(isOn: false, identifier: "watermark.logo.replace", action: { model.isPickingLogo = true }) {
                ApprovedIconView(icon: .photo, size: 18); Text("Replace logo").approvedText(15)
            }
        }
        commonControls(colours: false)
    }

    private var selectionSoft: Color {
        colorScheme == .dark ? Color(red: 122 / 255, green: 162 / 255, blue: 1).opacity(0.14) : Color(red: 34 / 255, green: 87 / 255, blue: 210 / 255).opacity(0.08)
    }

    // MARK: Shared: placement, position, size, opacity, colour

    @ViewBuilder
    private func commonControls(colours: Bool) -> some View {
        PanelSlider(label: "Size", value: watermark.size, range: 10...80, identifier: "slider.size",
                    onChange: { v in session.previewWatermark { $0.size = v.rounded() } },
                    onEnd: { v in session.commitWatermark { $0.size = v.rounded() } })
        PanelSlider(label: "Opacity", value: watermark.opacity, range: 0...100, identifier: "slider.opacity",
                    onChange: { v in session.previewWatermark { $0.opacity = v.rounded() } },
                    onEnd: { v in session.commitWatermark { $0.opacity = v.rounded() } })
        if colours {
            ColourControl(title: "Colour", selected: watermark.colour, photo: model.session.originalImage,
                          identifier: "watermark.colour", preview: { hex in session.previewWatermark { $0.colour = hex } },
                          previewImage: { session.displayedImage }, cancel: session.cancelLookPreview, choose: model.setColour)

        }
    }
}

/// `.fontopt`: the text in the font at 20 pt over the font's name (Inter 500, 10.5 pt, ink-3);
/// min 100 × 60, radius 10, selected in the selection colour on its soft fill.
struct FontOption: View {
    let text: String
    let font: EditRecipe.Watermark.Font
    let isOn: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(text)
                    .font(Font(WatermarkFonts.font(font, size: 20, cssPixels: 20)))
                    .foregroundStyle(ApprovedColor.ink.resolved(colorScheme))
                    .lineLimit(1)
                Text(font.rawValue)
                    .approvedText(10.5, weight: .medium)
                    .foregroundStyle(ApprovedColor.inkTertiary.resolved(colorScheme))
            }
            .padding(.horizontal, 11).padding(.vertical, 5)
            .frame(minWidth: 100, minHeight: 60)
            .background(RoundedRectangle(cornerRadius: 10).fill(isOn ? selectionSoft : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((isOn ? ApprovedColor.selection : ApprovedColor.hairline).resolved(colorScheme), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(font.rawValue))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("watermark.font.\(font.rawValue)")
    }

    private var selectionSoft: Color {
        colorScheme == .dark ? Color(red: 122 / 255, green: 162 / 255, blue: 1).opacity(0.14) : Color(red: 34 / 255, green: 87 / 255, blue: 210 / 255).opacity(0.08)
    }
}

/// The logo at a height: the bundled sample (prototype `LOGO`: ring and "AR", in the foreground
/// colour) or a chosen image in its own colours.
struct LogoGlyph: View {
    let logo: EditRecipe.AssetRef
    let store: SignatureStore
    let height: CGFloat
    /// The sample logo's ink (CSS `currentColor` of its chip).
    let ink: CGColor

    var body: some View {
        switch logo {
        case .file(let digest):
            if let data = store.logo(sha256: digest), let image = WatermarkStage.image(from: data) {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    .frame(width: height * CGFloat(image.width) / CGFloat(max(image.height, 1)), height: height)
            }
        default:
            // Drawn exactly as the watermark stage draws it (ring r 27, "AR" on baseline 40 of 64).
            Canvas { context, size in
                context.withCGContext { cg in
                    WatermarkStage.drawSampleLogo(origin: .zero, height: Double(size.height), ink: ink, shadow: nil, in: cg)
                }
            }
            .frame(width: height, height: height)
            .accessibilityHidden(true)
        }
    }
}
