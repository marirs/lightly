import SwiftUI

/// UI state of the Edit panel (approved `editPanel`: prototype `ui.sub`, `ui.group`, the brush
/// size). Everything that changes the photo goes through the session as a recipe edit.
@MainActor
@Observable
final class EditPanelModel {
    enum Sub: String, CaseIterable { case crop, rotate, straighten, perspective, adjust, remove }
    enum Group: String, CaseIterable { case light, colour, detail }

    let session: EditorSession
    var sub: Sub = .crop
    var cropPreview = false
    var group: Group = .light
    /// Remove › "Brush size" 0…100 (prototype 35).
    var brushSize: Double = 35

    init(session: EditorSession) { self.session = session }

    var edit: EditRecipe.Edit { session.recipe.tools.edit }
    var brushRadius: Double { RemoveEngine.radius(forBrushSize: brushSize) }

    /// Prototype `ASPECTS` in order, with their chip labels.
    static let aspects: [(aspect: EditRecipe.Geometry.Aspect, label: String)] = [
        (.original, "Original"), (.free, "Free"), (.square, "1:1"), (.fourFive, "4:5"), (.threeTwo, "3:2"),
        (.sixteenNine, "16:9"), (.nineSixteen, "9:16")
    ]

    /// Prototype `toolUsed(s, 'edit')`, exactly: a crop aspect other than Original, a turn, a
    /// horizontal flip, a straighten angle, any Adjust slider or a Remove stroke (the one being
    /// removed or failed counts, as the prototype adds the stroke before removing it).
    // OWNER QUESTION (recorded in docs/v1/slice4-ios.md): the approved rule leaves out Flip
    // vertical and Perspective, so those edits alone show no dot. Implemented as approved.
    var isUsed: Bool {
        let g = edit.geometry, a = edit.adjust
        let adjust = [a.exposure, a.contrast, a.highlights, a.shadows, a.temp, a.tint, a.saturation, a.vibrance,
                      a.sharpness, a.clarity, a.noise].contains { $0 != 0 }
        return g.cropAspect != .original || g.quarterTurns != 0 || g.flipHorizontal || g.straighten != 0 || adjust
            || !edit.remove.strokes.isEmpty || session.pendingRemoveStroke != nil
    }
}

/// The approved Edit panel.
struct EditPanelView: View {
    @Bindable var model: EditPanelModel
    let roomy: Bool
    let wraps: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var session: EditorSession { model.session }
    private var geometry: EditRecipe.Geometry { model.edit.geometry }
    private var adjust: EditRecipe.Adjust { model.edit.adjust }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if roomy { PanelTitle(text: "Edit") }
            PanelTabs(items: [(EditPanelModel.Sub.crop, "Crop", false), (.rotate, "Rotate", false), (.straighten, "Straighten", false),
                              (.perspective, "Perspective", false), (.adjust, "Adjust", false), (.remove, "Remove", false)],
                      selected: model.sub, wraps: wraps, identifierPrefix: "edit.sub") { model.sub = $0 }
            PanelResetRow(session: model.session, section: "edit", title: model.sub.rawValue.capitalized, adjustment: model.sub.rawValue)
            switch model.sub {
            case .crop: crop
            case .rotate: rotate
            case .straighten: straighten
            case .perspective: perspective
            case .adjust: adjustControls
            case .remove: remove
            }
        }
    }

    // MARK: Crop, Rotate, Straighten, Perspective

    @ViewBuilder
    private var crop: some View {
        HStack {
            Text(model.cropPreview ? "Cropped preview" : "Drag corners or edges to crop.")
                .approvedText(15)
            Spacer()
            Button(model.cropPreview ? "Adjust crop" : "Done") { model.cropPreview.toggle() }
                .buttonStyle(ApprovedSmallQuietButtonStyle())
                .accessibilityIdentifier("edit.crop.done")
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
    }

    private var rotate: some View {
        ChipRow {
            OptionChip(isOn: false, identifier: "edit.rotateLeft", action: { session.rotate(quarterTurns: -1) }) {
                ApprovedIconView(icon: .rotl, size: 18); Text("Rotate left").approvedText(15)
            }
            OptionChip(isOn: false, identifier: "edit.rotateRight", action: { session.rotate(quarterTurns: 1) }) {
                ApprovedIconView(icon: .rotr, size: 18); Text("Rotate right").approvedText(15)
            }
            OptionChip(isOn: false, identifier: "edit.flipHorizontal", action: { session.commitEdit { $0.geometry.flipHorizontal.toggle() } }) {
                ApprovedIconView(icon: .fliph, size: 18); Text("Flip horizontal").approvedText(15)
            }
            OptionChip(isOn: false, identifier: "edit.flipVertical", action: { session.commitEdit { $0.geometry.flipVertical.toggle() } }) {
                ApprovedIconView(icon: .flipv, size: 18); Text("Flip vertical").approvedText(15)
            }
        }
    }

    @ViewBuilder
    private var straighten: some View {
        PanelSlider(label: "Angle", value: geometry.straighten, range: -45...45, identifier: "slider.angle",
                    onChange: { v in session.previewEdit { $0.geometry.straighten = v.rounded() } },
                    onEnd: { v in session.commitEdit { $0.geometry.straighten = v.rounded() } })
        ApprovedNote("The photo is zoomed slightly so no empty corners show.")
    }

    @ViewBuilder
    private var perspective: some View {
        PanelSlider(label: "Vertical", value: geometry.perspectiveVertical, range: -100...100, identifier: "slider.vertical",
                    onChange: { v in session.previewEdit { $0.geometry.perspectiveVertical = v.rounded() } },
                    onEnd: { v in session.commitEdit { $0.geometry.perspectiveVertical = v.rounded() } })
        PanelSlider(label: "Horizontal", value: geometry.perspectiveHorizontal, range: -100...100, identifier: "slider.horizontal",
                    onChange: { v in session.previewEdit { $0.geometry.perspectiveHorizontal = v.rounded() } },
                    onEnd: { v in session.commitEdit { $0.geometry.perspectiveHorizontal = v.rounded() } })
    }

    // MARK: Adjust

    @ViewBuilder
    private var adjustControls: some View {
        PanelTabs(items: [(EditPanelModel.Group.light, "Light", false), (.colour, "Colour", false), (.detail, "Detail", false)],
                  selected: model.group, wraps: wraps, identifierPrefix: "edit.group") { model.group = $0 }
        switch model.group {
        case .light:
            slider("Exposure", \.exposure, -100...100)
            slider("Contrast", \.contrast, -100...100)
            slider("Highlights", \.highlights, -100...100)
            slider("Shadows", \.shadows, -100...100)
        case .colour:
            slider("Temperature", \.temp, -100...100)
            slider("Tint", \.tint, -100...100)
            slider("Saturation", \.saturation, -100...100)
            slider("Vibrance", \.vibrance, -100...100)
        case .detail:
            slider("Sharpness", \.sharpness, 0...100)
            slider("Clarity", \.clarity, -100...100)
            slider("Noise reduction", \.noise, 0...100)
        }
    }

    private func slider(_ label: String, _ key: WritableKeyPath<EditRecipe.Adjust, Double>, _ range: ClosedRange<Double>) -> some View {
        PanelSlider(label: label, value: adjust[keyPath: key], range: range,
                    identifier: "slider.\(label.lowercased().replacingOccurrences(of: " ", with: ""))",
                    onChange: { v in session.previewEdit { $0.adjust[keyPath: key] = v.rounded() } },
                    onEnd: { v in session.commitEdit { $0.adjust[keyPath: key] = v.rounded() } })
    }

    // MARK: Remove

    @ViewBuilder
    private var remove: some View {
        switch session.removeState {
        case .removing:
            DevelopNotice(icon: .info, bold: nil, text: "Removing…",
                          actions: [("Cancel", "edit.remove.cancel", { session.cancelRemove() })])
        case .failed:
            DevelopNotice(icon: .warn, bold: "Couldn't remove that area.", text: " Try a smaller stroke. Your other edits are kept.",
                          actions: [("Try again", "edit.remove.retry", { session.retryRemove() })])
        case .idle:
            PanelSlider(label: "Brush size", value: model.brushSize, range: 0...100, identifier: "slider.brushSize",
                        onChange: { model.brushSize = $0.rounded() }, onEnd: { model.brushSize = $0.rounded() })
            HStack(spacing: 0) {
                let canUndo = !model.edit.remove.strokes.isEmpty
                Button("Undo stroke") { session.undoStroke() }
                    .buttonStyle(ApprovedSmallQuietButtonStyle())
                    .disabled(!canUndo)
                    .opacity(canUndo ? 1 : 0.4)
                    .accessibilityIdentifier("edit.remove.undoStroke")
                ApprovedParagraph(text: String(localized: "Brush over anything you want removed."), pointSize: 13,
                                  colour: ApprovedColor.inkTertiary.resolved(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ApprovedMetrics.rowHorizontalPadding).padding(.vertical, 6)
            }
            .padding(.horizontal, 6)
        }
    }
}
