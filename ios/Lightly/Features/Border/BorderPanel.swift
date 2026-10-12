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
        // Owner, 2026-10-12: Paper is no longer offered, so a stored Paper preference opens on nothing.
        case .paper: shownType = nil
        }
    }

    /// The preferred border's name in the None note (the prototype's `${'None'}` placeholder).
    var preferredBorderName: String {
        switch preferredBorder() {
        case .none: "None"
        case .solid: "Solid"
        case .photoFrame: "Photo Frame"
        case .polaroid: "Polaroid"
        case .paper: "Paper"
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

    /// Lightly 2 `borderPanel`, a 6 pt column: the tabs, the reset row (with a border), the type's controls. Every
    /// colour is the one colour strip.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Owner, 2026-10-12: Paper is no longer offered (it did not look real); an edit saved with it still
            // renders and still opens on its controls.
            PanelTabs(items: [(EditRecipe.Border.Kind.none, "None", false), (.solid, "Solid", false),
                              (.frame, "Photo Frame", false), (.polaroid, "Polaroid", false)],
                      selected: model.selectedType, wraps: wraps, identifierPrefix: "border.type") { model.choose($0) }
            if model.selectedType != .none {
                PanelResetRow(session: model.session, section: "border", title: "Border")
            }
            switch model.selectedType {
            case .none: EmptyView()
            case .solid: solid
            case .frame: frame
            case .polaroid: polaroid
            case .paper: paper
            }
        }
    }

    @ViewBuilder
    private var solid: some View {
        colour("Border colour", selected: border.colour, identifier: "border.colour", key: \.colour)
        slider("Width", \.width, 1...15)
    }

    @ViewBuilder
    private var frame: some View {
        colour("Frame colour", selected: border.colour, identifier: "border.colour", key: \.colour)
        slider("Frame width", \.width, 1...10)
        colour("Mat colour", selected: border.mat, identifier: "border.mat", key: \.mat)
        slider("Spacing", \.spacing, 0...12)
    }

    @ViewBuilder
    private var polaroid: some View {
        colour("Border colour", selected: border.colour, identifier: "border.colour", key: \.colour)
        L2Note(text: Text("A wider bottom margin, as on an instant print."))
    }

    private func colour(_ title: String, selected: String, identifier: String, key: WritableKeyPath<EditRecipe.Border, String>) -> some View {
        ColourControl(title: title, selected: selected, photo: session.originalImage, identifier: identifier,
                      preview: { hex in model.preview { $0[keyPath: key] = hex } },
                      previewImage: { session.displayedImage }, cancel: session.cancelLookPreview) { hex in
            model.commit { $0[keyPath: key] = hex }
        }
    }

    /// Paper: the finishes (92×64 chip-filled tiles, 14 pt corners, a 64×40 sample; selected with a 2 pt accent ring;
    /// 12.5 pt label, bold ink when selected), 12 pt apart; then the paper colour, Width and Texture.
    @ViewBuilder
    private var paper: some View {
        let c = L2(scheme: colorScheme)
        ChipRow(spacing: 12) {
            ForEach(EditRecipe.Border.PaperFinish.allCases, id: \.self) { finish in
                let isOn = border.paperFinish == finish
                Button { model.commit { $0.paperFinish = finish } } label: {
                    VStack(spacing: 5) {
                        PaperFinishSample(finish: finish)
                            .frame(width: 64, height: 40)
                            .frame(width: 92, height: 64)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c(ApprovedColor.chip)))
                            .overlay { if isOn { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c(ApprovedColor.selection), lineWidth: 2) } }
                        Text(LocalizedStringKey(finish.rawValue.capitalized)).l2Text(12.5, weight: isOn ? .bold : .medium)
                            .foregroundStyle(isOn ? c(ApprovedColor.ink) : c(ApprovedColor.inkSecondary))
                    }
                    .padding(3)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("border.paper." + finish.rawValue)
            }
        }
        colour("Paper colour", selected: border.colour, identifier: "border.paper.colour", key: \.colour)
        slider("Width", \.width, 1...15)
        slider("Texture", \.texture, 0...100)
    }

    private func slider(_ label: String, _ key: WritableKeyPath<EditRecipe.Border, Double>,
                        _ range: ClosedRange<Double>) -> some View {
        PanelSlider(label: label, value: border[keyPath: key], range: range, identifier: "slider.\(label.lowercased())",
                    onChange: { v in model.preview { $0[keyPath: key] = v.rounded() } },
                    onEnd: { v in model.commit { $0[keyPath: key] = v.rounded() } })
    }
}

/// The finish samples, #ECE8DF: Clean (2 pt corners), Deckled and Torn (the mockup's `paperEdge` outlines).
private struct PaperFinishSample: View {
    let finish: EditRecipe.Border.PaperFinish
    static let deckled: [(CGFloat, CGFloat)] = [(0, 3), (6, 0), (14, 2), (24, 0), (35, 3), (47, 0), (58, 2), (70, 0), (82, 3), (92, 0), (100, 2), (98, 14), (100, 30), (97, 47), (100, 63), (98, 80), (100, 97), (90, 100), (78, 97), (66, 100), (52, 98), (40, 100), (27, 97), (15, 100), (4, 98), (0, 100), (2, 82), (0, 64), (3, 46), (0, 30), (2, 14)]
    static let torn: [(CGFloat, CGFloat)] = [(0, 0), (18, 4), (30, 0), (52, 5), (68, 1), (86, 6), (100, 0), (96, 22), (100, 44), (95, 70), (100, 100), (76, 95), (58, 100), (36, 94), (18, 100), (0, 96), (4, 74), (0, 50), (5, 26)]

    var body: some View {
        Canvas { context, size in
            let fill = Color(hex: 0xECE8DF)
            switch finish {
            case .clean:
                context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2), with: .color(fill))
            case .deckled, .torn:
                let points = finish == .deckled ? Self.deckled : Self.torn
                var path = Path()
                for (index, point) in points.enumerated() {
                    let p = CGPoint(x: size.width * point.0 / 100, y: size.height * point.1 / 100)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                path.closeSubpath()
                context.fill(path, with: .color(fill))
            }
        }
        .accessibilityHidden(true)
    }
}
