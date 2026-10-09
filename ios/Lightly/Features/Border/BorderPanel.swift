import SwiftUI

/// UI state of the Border panel (approved `borderPanel`: prototype `ui.sub || s.border.type`).
@MainActor
@Observable
final class BorderPanelModel {
    let session: EditorSession
    /// The Watermark panel's model: "Signature on the margin" is the watermark's placement.
    let watermarkPanel: WatermarkPanelModel
    /// Preferences › Preferred border, read when Border opens.
    let preferredBorder: @MainActor () -> PreferredBorder
    /// The tab shown; nil follows the recipe's border type, like the prototype's `ui.sub || b.type`.
    var shownType: EditRecipe.Border.Kind?

    init(session: EditorSession, watermarkPanel: WatermarkPanelModel, preferredBorder: @escaping @MainActor () -> PreferredBorder = { .none }) {
        self.session = session
        self.watermarkPanel = watermarkPanel
        self.preferredBorder = preferredBorder
    }

    var border: EditRecipe.Border { session.recipe.tools.border }
    var watermark: EditRecipe.Watermark { session.recipe.tools.watermark }
    var selectedType: EditRecipe.Border.Kind { shownType ?? border.type }

    /// Prototype `toolUsed(s, 'border')`.
    var isUsed: Bool { border.type != .none }

    /// Prototype action `borderType`: choosing a tab sets the border type; Polaroid resets its
    /// colour to white.
    func choose(_ type: EditRecipe.Border.Kind) {
        shownType = type
        session.commitBorder { border in
            border.type = type
            if type == .polaroid { border.colour = "#FFFFFF" }
        }
    }

    /// "Opens first in Border" (approved `prefborder`): with no border on the photo, Border opens
    /// on the preferred type's tab. Nothing is applied until the person changes a control there.
    func openOnPreferredType() {
        guard border.type == .none else { return }
        switch preferredBorder() {
        case .none: shownType = nil
        case .solid: shownType = .solid
        case .photoFrame: shownType = .frame
        case .polaroid: shownType = .polaroid
        }
    }

    /// The preferred border's name in the None note (the prototype's `${'None'}` placeholder).
    var preferredBorderName: String {
        switch preferredBorder() {
        case .none: "None"
        case .solid: "Solid"
        case .photoFrame: "Photo Frame"
        case .polaroid: "Polaroid"
        }
    }

    /// A control changed on the shown tab: the border becomes that tab's type in the same step
    /// (the tab can differ from the recipe only when Border opened on the preferred type).
    func commit(_ change: @escaping (inout EditRecipe.Border) -> Void) {
        let type = selectedType
        session.commitBorder { border in
            if border.type != type {
                border.type = type
                if type == .polaroid { border.colour = "#FFFFFF" }
            }
            change(&border)
        }
    }

    func preview(_ change: @escaping (inout EditRecipe.Border) -> Void) {
        let type = selectedType
        session.previewBorder { border in
            border.type = type
            change(&border)
        }
    }

    /// Prototype `polaroidSig`: the toggle shows on when a watermark sits on the margin.
    var signatureOnMargin: Bool { watermark.placement == .border && watermark.type != .none }

    /// Prototype `polaroidSig`: with no watermark set, the saved signature is chosen; then the
    /// watermark flips between the photo and the margin.
    // v3 differs: with no saved signature at all the prototype still sets `type = 'signature'`; a
    // signature watermark needs a saved one (edit recipe `signatureRef`), so the Draw signature
    // sheet opens and the drawing saved there goes on the margin (owner question W7).
    func toggleSignatureOnMargin() {
        if border.type != selectedType { commit { _ in } }
        let flipped: EditRecipe.Watermark.Placement = watermark.placement == .border ? .photo : .border
        if watermark.type == .none {
            guard let saved = watermarkPanel.signatures.drawn ?? watermarkPanel.signatures.imported else {
                watermarkPanel.placesNextSignatureOnBorder = true
                watermarkPanel.openDraw()
                return
            }
            session.commitWatermark { w in
                WatermarkPanelModel.setType(.signature, on: &w)
                w.signature = saved.reference
                w.placement = flipped
            }
        } else {
            session.commitWatermark { $0.placement = flipped }
        }
    }

    static let solidColours = ["#FFFFFF", "#F4F1EC", "#111111", "#3C4A55", "#C9A27E"]
    static let frameColours = ["#111111", "#5A4636", "#C9C2B8", "#FFFFFF"]
    static let matColours = ["#F4F1EC", "#FFFFFF", "#1F2328"]
    static let polaroidColours = ["#FFFFFF", "#F4F1EC", "#111111"]
}

/// The approved Border panel: None, Solid, Photo Frame, Polaroid.
struct BorderPanelView: View {
    @Bindable var model: BorderPanelModel
    let roomy: Bool
    let wraps: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var session: EditorSession { model.session }
    private var border: EditRecipe.Border { model.border }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if roomy { PanelTitle(text: "Border") }
            PanelTabs(items: [(EditRecipe.Border.Kind.none, "None", false), (.solid, "Solid", false),
                              (.frame, "Photo Frame", false), (.polaroid, "Polaroid", false), (.paper, "Paper", false)],
                      selected: model.selectedType, wraps: wraps, identifierPrefix: "border.type") { model.choose($0) }
            PanelResetRow(session: model.session, section: "border", title: "Border")
            switch model.selectedType {
            case .none: none
            case .solid: solid
            case .frame: frame
            case .polaroid: polaroid
            case .paper: paper
            }
        }
    }

    // The prototype's `${'None'}` is a placeholder for the Preferences value (None by default).
    private var none: some View {
        ApprovedNote("No border. Your preferred border in Preferences is \(model.preferredBorderName); it is never added automatically.")
    }

    @ViewBuilder
    private var solid: some View {
        swatches(BorderPanelModel.solidColours, selected: border.colour, identifier: "border.colour") { c in
            model.commit { $0.colour = c }
        }
        slider("Width", \.width, 1...15)
    }

    @ViewBuilder
    private var frame: some View {
        sectionLabel("Frame")
        swatches(BorderPanelModel.frameColours, selected: border.colour, identifier: "border.colour") { c in
            model.commit { $0.colour = c }
        }
        slider("Frame width", \.width, 1...10)
        sectionLabel("Mat")
        swatches(BorderPanelModel.matColours, selected: border.mat, identifier: "border.mat") { c in
            model.commit { $0.mat = c }
        }
        slider("Spacing", \.spacing, 0...12)
    }

    @ViewBuilder
    private var polaroid: some View {
        swatches(BorderPanelModel.polaroidColours, selected: border.colour, identifier: "border.colour") { c in
            model.commit { $0.colour = c }
        }
        ApprovedNote("A wider bottom margin, as on an instant print.")

    }

    /// `.note` with `padding-bottom:0`: a section caption above a swatch row.
    private func sectionLabel(_ text: String) -> some View {
        ApprovedNote(verbatim: text, bottomPadding: 0)
    }

    private func swatches(_ colours: [String], selected: String, identifier: String,
                          choose: @escaping (String) -> Void) -> some View {
        ColourControl(title: identifier == "border.mat" ? "Mat colour" : "Border colour", selected: selected,
                      photo: session.originalImage, identifier: identifier,
                      preview: { hex in model.preview { if identifier == "border.mat" { $0.mat = hex } else { $0.colour = hex } } },
                      previewImage: { session.displayedImage }, cancel: session.cancelLookPreview, choose: choose)
    }

    private var paper: some View {
        VStack(spacing: 0) {
            ChipRow {
                ForEach(EditRecipe.Border.PaperFinish.allCases, id: \.self) { finish in
                    Button { model.commit { $0.paperFinish = finish } } label: {
                        VStack(spacing: 8) {
                            PaperFinishSample(finish: finish).frame(width: 82, height: 56)
                            Text(finish.rawValue.capitalized).approvedText(13)
                        }.padding(5).overlay(RoundedRectangle(cornerRadius: 9).stroke(border.paperFinish == finish ? Color.accentColor : .clear, lineWidth: 2))
                    }.buttonStyle(.plain).accessibilityIdentifier("border.paper." + finish.rawValue)
                }
            }
            ColourControl(title: "Paper colour", selected: border.colour, photo: session.originalImage, identifier: "border.paper.colour",
                          preview: { hex in model.preview { $0.colour = hex } }, previewImage: { session.displayedImage }, cancel: session.cancelLookPreview) { c in model.commit { $0.colour = c } }
            slider("Width", \.width, 1...15)
            slider("Texture", \.texture, 0...100)
        }
    }

    private func slider(_ label: String, _ key: WritableKeyPath<EditRecipe.Border, Double>,
                        _ range: ClosedRange<Double>) -> some View {
        PanelSlider(label: label, value: border[keyPath: key], range: range, identifier: "slider.\(label.lowercased())",
                    onChange: { v in model.preview { $0[keyPath: key] = v.rounded() } },
                    onEnd: { v in model.commit { $0[keyPath: key] = v.rounded() } })
    }
}

private struct PaperFinishSample: View {
    let finish: EditRecipe.Border.PaperFinish
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let amplitude = finish == .clean ? 0.0 : (finish == .deckled ? 1.0 : 3.0)
            path.move(to: CGPoint(x: 4, y: 4))
            for x in stride(from: 4.0, through: size.width-4, by: 1) { path.addLine(to: CGPoint(x: x, y: 4 + amplitude * PaperBorder.noise(x*0.8, 0))) }
            path.addLine(to: CGPoint(x: size.width-4, y: size.height-4))
            for x in stride(from: size.width-4, through: 4.0, by: -1) { path.addLine(to: CGPoint(x: x, y: size.height-4-amplitude*PaperBorder.noise(x*0.8, 17))) }
            path.closeSubpath(); context.fill(path, with: .color(Color(red: 0.91, green: 0.88, blue: 0.82)))
        }.background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}
