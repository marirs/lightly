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

    /// Lightly 2 `editPanel`, a 6 pt column: the tabs, the reset row, the tab's controls.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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

    /// Inline crop (owner, 2026-10-11): the frame is on the photo; the panel holds the aspect (chips, the selected one
    /// ink-filled) and how to use the frame. Choosing an aspect is one undo step; Free and Original never lock a ratio.
    private var crop: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChipRow {
                ForEach(EditRecipe.Geometry.Aspect.allCases, id: \.self) { aspect in
                    OptionChip(isOn: geometry.cropAspect == aspect, identifier: "edit.aspect.\(aspect.rawValue)",
                               action: { session.setCropAspect(aspect) }) { Text(Self.aspectLabel(aspect)) }
                }
            }
            L2Note(text: Text("Drag the corners or edges. Drag inside to move. Pinch to resize."))
        }
    }

    private static func aspectLabel(_ aspect: EditRecipe.Geometry.Aspect) -> String {
        switch aspect {
        case .original: "Original"
        case .free: "Free"
        default: aspect.rawValue
        }
    }

    /// Rotate: a 2×2 grid, 8 pt gaps, of 46 pt outlined buttons (16 pt corners) with an 18 pt icon and a 13 pt
    /// semibold label; a flip that is on shows in the accent colour.
    private var rotate: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            rotateButton(.rotl, "Rotate left", "edit.rotateLeft", isOn: false) { session.rotate(quarterTurns: -1) }
            rotateButton(.rotr, "Rotate right", "edit.rotateRight", isOn: false) { session.rotate(quarterTurns: 1) }
            rotateButton(.fliph, "Flip horizontal", "edit.flipHorizontal", isOn: geometry.flipHorizontal) { session.commitEdit { $0.geometry.flipHorizontal.toggle() } }
            rotateButton(.flipv, "Flip vertical", "edit.flipVertical", isOn: geometry.flipVertical) { session.commitEdit { $0.geometry.flipVertical.toggle() } }
        }
    }

    private func rotateButton(_ icon: ApprovedIcon, _ title: String, _ identifier: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        let c = L2(scheme: colorScheme)
        return Button(action: action) {
            HStack(spacing: 8) { ApprovedIconView(icon: icon, size: 18); Text(LocalizedStringKey(title)).l2Text(13, weight: .semibold) }
                .foregroundStyle(isOn ? c(ApprovedColor.selection) : c(ApprovedColor.ink))
                .frame(maxWidth: .infinity, minHeight: 46)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(isOn ? c(ApprovedColor.selection) : c(ApprovedColor.hairline), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
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
        // Owner (2026-10-11): the same tab row as every other sub-menu (was a segmented control).
        L2Tabs(items: [.init(value: EditPanelModel.Group.light, title: Text("Light"), identifier: "edit.group.Light"),
                       .init(value: .colour, title: Text("Colour"), identifier: "edit.group.Colour"),
                       .init(value: .detail, title: Text("Detail"), identifier: "edit.group.Detail")],
               selection: model.group) { model.group = $0 }
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
            L2Notice(icon: .info, text: "Removing…", actions: [("Cancel", "edit.remove.cancel", { session.cancelRemove() })])
        case .failed:
            L2Notice(icon: .warn, bold: "Couldn't remove that area.", text: " Try a smaller stroke. Your other edits are kept.",
                     actions: [("Try again", "edit.remove.retry", { session.retryRemove() })])
        case .idle:
            PanelSlider(label: "Brush size", value: model.brushSize, range: 0...100, identifier: "slider.brushSize",
                        onChange: { model.brushSize = $0.rounded() }, onEnd: { model.brushSize = $0.rounded() })
            HStack(spacing: 10) {
                let canUndo = !model.edit.remove.strokes.isEmpty
                Button("Undo stroke") { session.undoStroke() }
                    .buttonStyle(L2QuietButtonStyle(dimmed: !canUndo))
                    .disabled(!canUndo)
                    .accessibilityIdentifier("edit.remove.undoStroke")
                L2Note(text: Text("Brush over anything you want removed."))
            }
        }
    }
}
