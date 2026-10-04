import ImageIO
import SwiftUI

/// UI state of the Background panel (approved `backgroundPanel`, prototype `ui.sub`, `ui.bgKind`,
/// `ui.brush`). Everything that changes the photo goes through the session as a recipe edit.
@MainActor
@Observable
final class BackgroundPanelModel {
    enum Mode: Equatable { case focus, change, refine }
    enum Kind: String, CaseIterable { case image, colour, gradient }

    let session: EditorSession
    var mode: Mode = .focus
    /// nil follows the applied replacement (image by default).
    var kind: Kind?
    var brush: EditRecipe.RefineStroke.Mode = .add
    /// "Brush size" 0…100 (prototype default 40): radius 0.5 %…6 % of the long edge.
    var brushSize: Double = 40

    init(session: EditorSession) { self.session = session }

    var background: EditRecipe.Background { session.recipe.tools.background }

    var currentKind: Kind {
        if let kind { return kind }
        switch background.replacement {
        case .colour?: return .colour
        case .gradient?: return .gradient
        default: return .image
        }
    }

    var brushRadius: Double { 0.005 + 0.055 * brushSize / 100 }

    /// The approved bundled backgrounds (prototype `BACKGROUNDS`).
    static let bundledImages = ["landscape_01", "sunset_03", "wellexposed_02", "backlit_02"]
    /// Prototype `SWATCHES`.
    static let swatches = ["#F4F1EC", "#D9D4CC", "#9AA3A8", "#3C4A55", "#1F2328", "#C9A27E", "#8A5A44", "#4E6B5A"]
    /// Prototype `GRADIENTS` as recipe gradients.
    static let gradients: [(angle: Double, stops: [EditRecipe.GradientStop])] = [
        (160, [.init(colour: "#F6D5B8", position: 0), .init(colour: "#9EB7D6", position: 1)]),
        (180, [.init(colour: "#20242C", position: 0), .init(colour: "#5B6476", position: 1)]),
        (140, [.init(colour: "#E9E4DA", position: 0), .init(colour: "#BFC8C2", position: 1)]),
        (170, [.init(colour: "#F0B7A4", position: 0), .init(colour: "#6E5A86", position: 1)])
    ]
}

/// The approved Background panel.
struct BackgroundPanelView: View {
    @Bindable var model: BackgroundPanelModel
    let roomy: Bool
    let wraps: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var session: EditorSession { model.session }
    private var focus: EditRecipe.Focus { model.background.focus }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if roomy { PanelTitle(text: "Background") }
            ApprovedSegmentedControl(
                accessibilityLabel: Text("Background"),
                options: [(BackgroundPanelModel.Mode.focus, Text("Focus & Blur"), "background.mode.focus"),
                          (.change, Text("Change background"), "background.mode.change")],
                selection: Binding(get: { model.mode == .refine ? .focus : model.mode }, set: { model.mode = $0 }))
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 4)
            content
        }
        .task { session.analyseSubjectIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch session.subjectState {
        case .notStarted, .separating:
            DevelopNotice(icon: .info, bold: nil, text: "Finding the subject…",
                          actions: [("Cancel", "background.cancel", { session.cancelSubjectSeparation() })])
        case .failed:
            DevelopNotice(icon: .warn, bold: "Couldn't separate the subject.", text: " Your other edits are kept.",
                          actions: [("Try again", "background.retry", { session.retrySubjectSeparation() })])
        case .noSubject:
            DevelopNotice(icon: .info, bold: "No clear subject found.",
                          text: " Change background needs a person or object in front. You can still blur by tapping where to focus.", actions: [])
            blurSlider
        case .ready:
            switch model.mode {
            case .refine: refine
            case .change: change
            case .focus: focusControls
            }
        }
    }

    // MARK: Focus & Blur

    private var blurSlider: some View {
        PanelSlider(label: "Blur", value: focus.blur, range: 0...100, identifier: "slider.blur",
                    onChange: { v in session.previewBackground { $0.focus.blur = v.rounded() } },
                    onEnd: { v in session.commitBackground { $0.focus.blur = v.rounded() } })
    }

    @ViewBuilder
    private var focusControls: some View {
        PanelTabs(items: [(EditRecipe.Focus.Style.lens, "Lens", false), (.soft, "Soft", false), (.swirl, "Swirl", false), (.motion, "Motion", false)],
                  selected: focus.style, wraps: wraps, identifierPrefix: "background.style") { style in
            session.commitBackground { $0.focus.style = style }
        }
        switch focus.style {
        case .lens:
            ChipRow {
                Text("Bokeh").approvedText(15).foregroundStyle(ApprovedColor.inkSecondary.resolved(colorScheme)).frame(minWidth: 72, alignment: .leading)
                ForEach(Self.bokehOptions, id: \.bokeh) { option in
                    OptionChip(isOn: focus.bokeh == option.bokeh, identifier: "background.bokeh.\(option.bokeh.rawValue)",
                               action: { session.commitBackground { $0.focus.bokeh = option.bokeh } }) {
                        ApprovedIconView(icon: option.icon, size: 18)
                    }
                    .accessibilityLabel(Text("\(option.bokeh.rawValue) bokeh"))
                }
            }
        case .soft: styleSlider("Glow")
        case .swirl: styleSlider("Swirl")
        case .motion:
            PanelSlider(label: "Direction", value: focus.styleAmount * 3.6 - 180, range: -180...180, identifier: "slider.direction",
                        onChange: { v in session.previewBackground { $0.focus.styleAmount = ((v + 180) / 3.6).rounded() } },
                        onEnd: { v in session.commitBackground { $0.focus.styleAmount = ((v + 180) / 3.6).rounded() } })
        }
        blurSlider
        PanelSlider(label: "Focus depth", value: focus.depthOfField, range: 0...100, identifier: "slider.focusDepth",
                    onChange: { v in session.previewBackground { $0.focus.depthOfField = v.rounded() } },
                    onEnd: { v in session.commitBackground { $0.focus.depthOfField = v.rounded() } })
        HStack(spacing: 0) {
            Button { model.mode = .refine } label: {
                HStack(spacing: 8) { ApprovedIconView(icon: .brush, size: 17); Text("Refine edges") }
            }
            .buttonStyle(ApprovedSmallQuietButtonStyle())
            .accessibilityIdentifier("background.refine")
            Text("Tap the photo to set focus.").approvedText(13).foregroundStyle(ApprovedColor.inkTertiary.resolved(colorScheme))
                .padding(.horizontal, 8)
        }
        .padding(.horizontal, 6)
    }

    /// Prototype bokeh options: round, hex, heart, star.
    static let bokehOptions: [(bokeh: EditRecipe.Focus.Bokeh, icon: ApprovedIcon)] = [
        (.round, .circle), (.hex, .hex), (.heart, .heart), (.star, .starShape)
    ]

    private func styleSlider(_ label: String) -> some View {
        PanelSlider(label: label, value: focus.styleAmount, range: 0...100, identifier: "slider.\(label.lowercased())",
                    onChange: { v in session.previewBackground { $0.focus.styleAmount = v.rounded() } },
                    onEnd: { v in session.commitBackground { $0.focus.styleAmount = v.rounded() } })
    }

    // MARK: Refine edges

    @ViewBuilder
    private var refine: some View {
        ApprovedNote(text: Text("Brush over the edge to add to or remove from the subject."))
        IconSegmentedControl(options: [(EditRecipe.RefineStroke.Mode.add, ApprovedIcon.brush, "Add", "background.brush.add"),
                                       (.erase, .erase, "Remove", "background.brush.erase")],
                             selection: $model.brush)
            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 4)
        PanelSlider(label: "Brush size", value: model.brushSize, range: 0...100, identifier: "slider.brushSize",
                    onChange: { model.brushSize = $0 }, onEnd: { model.brushSize = $0 })
        HStack {
            Spacer(minLength: 0)
            Button("Done") { model.mode = .focus }
                .buttonStyle(ApprovedButtonStyle(kind: .quiet))
                .accessibilityIdentifier("background.refine.done")
        }
        .padding(.horizontal, 10)
    }

    // MARK: Change background

    @ViewBuilder
    private var change: some View {
        PanelTabs(items: [(BackgroundPanelModel.Kind.image, "Image", false), (.colour, "Colour", false), (.gradient, "Gradient", false)],
                  selected: model.currentKind, wraps: wraps, identifierPrefix: "background.kind") { model.kind = $0 }
        switch model.currentKind {
        case .image:
            ChipRow {
                ForEach(BackgroundPanelModel.bundledImages, id: \.self) { name in
                    BackgroundThumbnail(name: name, isOn: isBundled(name)) {
                        session.commitBackground {
                            $0.replacement = .image(.bundled(id: name), x: 50, y: 50, scale: Self.currentScale(model.background))
                        }
                    }
                }
                AddBackgroundButton()
            }
        case .colour:
            ChipRow {
                ForEach(BackgroundPanelModel.swatches, id: \.self) { hex in
                    SwatchButton(fill: Color(hex: UInt32(hex.dropFirst(), radix: 16) ?? 0), isOn: model.background.replacement == .colour(hex),
                                 label: "Colour \(hex)", identifier: "background.colour.\(hex)",
                                 colourName: SwatchButton<Color>.name(ofHex: hex)) {
                        session.commitBackground { $0.replacement = .colour(hex) }
                    }
                }
            }
        case .gradient:
            ChipRow {
                ForEach(BackgroundPanelModel.gradients.indices, id: \.self) { index in
                    let g = BackgroundPanelModel.gradients[index]
                    SwatchButton(fill: Self.swiftGradient(g.angle, g.stops), width: 52, cornerRadius: 10,
                                 isOn: model.background.replacement == .gradient(angle: g.angle, stops: g.stops),
                                 label: "Gradient", identifier: "background.gradient.\(index)") {
                        session.commitBackground { $0.replacement = .gradient(angle: g.angle, stops: g.stops) }
                    }
                }
            }
        }
        if model.currentKind == .image, case .image(_, _, _, let scale)? = model.background.replacement {
            PanelSlider(label: "Scale", value: scale, range: 100...200, identifier: "slider.scale",
                        onChange: { v in session.previewBackground { Self.setScale(&$0, v.rounded()) } },
                        onEnd: { v in session.commitBackground { Self.setScale(&$0, v.rounded()) } })
            ApprovedNote(text: Text("Drag the photo to position the background."))
        }
        if model.background.replacement != nil {
            HStack(spacing: 0) {
                Button("Remove background change") { session.commitBackground { $0.replacement = nil } }
                    .buttonStyle(ApprovedSmallQuietButtonStyle())
                    .accessibilityIdentifier("background.remove")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            ApprovedNote(text: Text("Focus & Blur still works on the new background."))
        }
    }

    private func isBundled(_ name: String) -> Bool {
        if case .image(.bundled(let id), _, _, _)? = model.background.replacement { return id == name }
        return false
    }

    static func currentScale(_ background: EditRecipe.Background) -> Double {
        if case .image(_, _, _, let scale)? = background.replacement { return scale }
        return 100
    }

    static func setScale(_ background: inout EditRecipe.Background, _ scale: Double) {
        if case .image(let asset, let x, let y, _)? = background.replacement { background.replacement = .image(asset, x: x, y: y, scale: scale) }
    }

    /// The CSS angle as a SwiftUI gradient (0° = to top, clockwise).
    static func swiftGradient(_ angle: Double, _ stops: [EditRecipe.GradientStop]) -> LinearGradient {
        let radians = angle * .pi / 180
        let dx = sin(radians) / 2, dy = -cos(radians) / 2
        return LinearGradient(stops: stops.map { .init(color: Color(hex: UInt32($0.colour.dropFirst(), radix: 16) ?? 0), location: $0.position) },
                              startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy), endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
    }
}

/// `.thumbopt`: a 64 pt background thumbnail, a 2 pt selection border when chosen.
struct BackgroundThumbnail: View {
    let name: String
    let isOn: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Group {
                if let image = BundledBackgrounds.thumbnail(name) {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    ApprovedColor.backgroundSecondary.resolved(colorScheme)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isOn ? ApprovedColor.selection.resolved(colorScheme) : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Background image"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("background.image.\(name)")
    }
}

/// `.thumbopt.add`: choose a photo from the library as the background.
struct AddBackgroundButton: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        // DEFERRED(slice 3 follow-up): "Choose a photo" opens the system picker; the prototype's
        // control is a no-op too (`data-act="noop"`).
        Button {} label: {
            ApprovedIconView(icon: .plus, size: 22)
                .foregroundStyle(ApprovedColor.inkSecondary.resolved(colorScheme))
                .frame(width: 64, height: 64)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ApprovedColor.inkTertiary.resolved(colorScheme), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Choose a photo"))
        .accessibilityIdentifier("background.image.add")
    }
}

/// The approved bundled background images (`docs/ui/assets/photos`, Unsplash License), copied by
/// project.yml.
enum BundledBackgrounds {
    static func image(_ name: String) -> CGImage? { load(name) }
    static func thumbnail(_ name: String) -> CGImage? { load("\(name)_thumb") ?? load(name) }

    private static func load(_ name: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// `.seg` whose segments carry an approved icon before the label (`icon(…, 16)&nbsp;Label`).
struct IconSegmentedControl<Value: Hashable>: View {
    let options: [(value: Value, icon: ApprovedIcon, label: String, identifier: String)]
    @Binding var selection: Value
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index], isOn = option.value == selection
                Button { selection = option.value } label: {
                    // `.seg > *` is a grid: the icon and the "&nbsp;Label" text are its two rows.
                    VStack(spacing: 0) { ApprovedIconView(icon: option.icon, size: 16); Text("\u{00A0}" + option.label) }
                        .approvedText(14, weight: .medium)
                        .foregroundStyle((isOn ? ApprovedColor.ink : ApprovedColor.inkSecondary).resolved(colorScheme))
                        .frame(maxWidth: .infinity, minHeight: ApprovedMetrics.minimumTarget)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(ApprovedColor.segmentSelected.resolved(colorScheme))
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier(option.identifier)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ApprovedColor.backgroundSecondary.resolved(colorScheme)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(ApprovedColor.hairline.resolved(colorScheme), lineWidth: 1))
    }
}
