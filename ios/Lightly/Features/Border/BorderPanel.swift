import SwiftUI

/// UI state of the Border panel (approved `borderPanel`: prototype `ui.sub || s.border.type`).
@MainActor
@Observable
final class BorderPanelModel {
    let session: EditorSession
    /// The tab shown; nil follows the recipe's border type, like the prototype's `ui.sub || b.type`.
    var shownType: EditRecipe.Border.Kind?

    init(session: EditorSession) { self.session = session }

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

    /// Prototype `polaroidSig`: the toggle shows on when a watermark sits on the margin.
    var signatureOnMargin: Bool { watermark.placement == .border && watermark.type != .none }

    /// Prototype `polaroidSig` flips the watermark between the photo and the margin, choosing the
    /// signature when no watermark is set.
    // DEFERRED(slice 5, Watermark): choosing the signature needs the saved-signature store, which
    // the Watermark slice builds. Until then only the placement flips; with no watermark set the
    // toggle stays off, because a signature watermark without a saved signature is not a valid recipe.
    func toggleSignatureOnMargin() {
        session.commitWatermark { watermark in
            watermark.placement = watermark.placement == .border ? .photo : .border
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
                              (.frame, "Photo Frame", false), (.polaroid, "Polaroid", false)],
                      selected: model.selectedType, wraps: wraps, identifierPrefix: "border.type") { model.choose($0) }
            switch model.selectedType {
            case .none: none
            case .solid: solid
            case .frame: frame
            case .polaroid: polaroid
            }
        }
    }

    // The prototype hard-codes "None" here (`${'None'}`): the preferred border is never applied
    // automatically, so the note always names the Preferences value without reading it.
    private var none: some View {
        ApprovedNote(text: Text("No border. Your preferred border in Preferences is None; it is never added automatically."))
    }

    @ViewBuilder
    private var solid: some View {
        swatches(BorderPanelModel.solidColours, selected: border.colour, identifier: "border.colour") { c in
            session.commitBorder { $0.colour = c }
        }
        slider("Width", \.width, 1...15)
    }

    @ViewBuilder
    private var frame: some View {
        sectionLabel("Frame")
        swatches(BorderPanelModel.frameColours, selected: border.colour, identifier: "border.colour") { c in
            session.commitBorder { $0.colour = c }
        }
        slider("Frame width", \.width, 1...10)
        sectionLabel("Mat")
        swatches(BorderPanelModel.matColours, selected: border.mat, identifier: "border.mat") { c in
            session.commitBorder { $0.mat = c }
        }
        slider("Spacing", \.spacing, 0...12)
    }

    @ViewBuilder
    private var polaroid: some View {
        swatches(BorderPanelModel.polaroidColours, selected: border.colour, identifier: "border.colour") { c in
            session.commitBorder { $0.colour = c }
        }
        ApprovedNote(text: Text("A wider bottom margin, as on an instant print."))
        // `.listrow` with `border:0;width:100%`, the switch at the trailing edge.
        Toggle(isOn: Binding(get: { model.signatureOnMargin }, set: { _ in model.toggleSignatureOnMargin() })) {
            Text("Signature on the margin").approvedText(15).foregroundStyle(ApprovedColor.ink.resolved(colorScheme))
        }
        .toggleStyle(ApprovedSwitchToggleStyle())
        .padding(.horizontal, ApprovedMetrics.rowHorizontalPadding)
        .frame(minHeight: 44)
        .accessibilityIdentifier("border.polaroid.signature")
    }

    /// `.note` with `padding-bottom:0`: a section caption above a swatch row.
    private func sectionLabel(_ text: String) -> some View {
        ApprovedNote(text: Text(text), bottomPadding: 0)
    }

    private func swatches(_ colours: [String], selected: String, identifier: String,
                          choose: @escaping (String) -> Void) -> some View {
        ChipRow {
            ForEach(colours, id: \.self) { hex in
                SwatchButton(fill: Color(hex: UInt32(hex.dropFirst(), radix: 16) ?? 0), isOn: selected == hex,
                             label: "Colour", identifier: "\(identifier).\(hex.dropFirst())") { choose(hex) }
            }
        }
    }

    private func slider(_ label: String, _ key: WritableKeyPath<EditRecipe.Border, Double>,
                        _ range: ClosedRange<Double>) -> some View {
        PanelSlider(label: label, value: border[keyPath: key], range: range, identifier: "slider.\(label.lowercased())",
                    onChange: { v in session.previewBorder { $0[keyPath: key] = v.rounded() } },
                    onEnd: { v in session.commitBorder { $0[keyPath: key] = v.rounded() } })
    }
}
