import ImageIO
import PhotosUI
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
    static let bundledImages = ["landscape_01", "sunset_03", "wellexposed_02", "landscape_02", "landscape_03", "sunset_02", "wellexposed_03"]
    /// One tile of Change background › Image.
    enum ImageTile: Hashable {
        case bundled(String)
        case imported
        case choosePhoto
    }

    /// The tiles in grid order (owner amendment 2026-10-11, second): the bundled backgrounds, the imported photo when
    /// there is one, and "+ Choose a photo" last (it used to come first).
    static func imageTiles(hasImportedPhoto: Bool) -> [ImageTile] {
        bundledImages.map(ImageTile.bundled) + (hasImportedPhoto ? [.imported] : []) + [.choosePhoto]
    }

    /// Keep retired assets available to edits that already reference them.
    static let renderableImages = bundledImages + ["backlit_02"]
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

    @State private var selectedBackground: PhotosPickerItem?
    @State private var importingBackground = false
    @State private var importFailed = false

    private var backgroundColour: String {
        if case .colour(let hex) = model.background.replacement { return hex }
        return "#F4F1EC"
    }

    @Environment(\.colorScheme) private var colorScheme

    private var session: EditorSession { model.session }
    /// Subject separation finished and found no subject: Change background has nothing to put a new background behind.
    private var hasNoSubject: Bool { session.subjectState == .noSubject }
    private var focus: EditRecipe.Focus { model.background.focus }

    /// Lightly 2 `backgroundPanel`: the mode switch, then the state's content; Focus & Blur in a 4 pt column, Change
    /// background and Refine edges in 8 pt, notices in 12 pt.
    var body: some View {
        VStack(alignment: .leading, spacing: columnSpacing) {
            // Owner (2026-10-11): the same tab row as every other sub-menu (was a segmented control).
            // Owner (2026-10-11, second): with no subject, Change background is greyed out and Focus & Blur is shown
            // (mockup `backgroundPanel`, screen bg-no-subject); Blur still works by depth.
            L2Tabs(items: [.init(value: BackgroundPanelModel.Mode.focus, title: Text("Focus & Blur"), identifier: "background.mode.focus"),
                           .init(value: .change, title: Text("Change background"), identifier: "background.mode.change",
                                 isDisabled: hasNoSubject)],
                   selection: model.mode == .refine || hasNoSubject ? .focus : model.mode) { model.mode = $0 }
            content
        }
        // A photo found to have no subject while Change background (or Refine edges) was open falls back to Focus &
        // Blur, so the mode, the tab and the content agree.
        .onChange(of: hasNoSubject, initial: true) { _, noSubject in
            if noSubject, model.mode != .focus { model.mode = .focus }
        }
        .task(id: selectedBackground) {
            guard let item = selectedBackground else { return }
            importingBackground = true
            defer { importingBackground = false }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw LightlyError.exportFailed }
                try Task.checkCancellation()
                try await session.importBackground(data)
            } catch is CancellationError { } catch { importFailed = true }
            selectedBackground = nil
        }
        .fullScreenCover(isPresented: $importFailed) {
            L2Alert(title: "Couldn’t open that photo", message: "Choose another photo for the background.",
                    buttons: [("OK", .preferred, "background.importFailed.ok", { importFailed = false })])
                .presentationBackground(.clear)
        }
        .transaction { if importFailed { $0.disablesAnimations = true } }
        // Re-run when the mode changes: switching to Focus & Blur is what starts depth.
        .task(id: model.mode) { session.analyseSubjectIfNeeded(needsDepth: model.mode == .focus) }
    }

    private var columnSpacing: CGFloat {
        guard case .controls = session.backgroundContent(needsDepth: model.mode == .focus) else { return 12 }
        return model.mode == .focus ? 4 : 8
    }

    private var resetRow: some View {
        PanelResetRow(session: session, section: "background",
                      title: model.mode == .focus ? "Focus & Blur" : model.mode == .change ? "Change background" : "Refine edges",
                      adjustment: model.mode == .focus ? "focus" : model.mode == .change ? "change" : "refine")
    }

    @ViewBuilder
    private var content: some View {
        // Only Focus & Blur waits for depth; Change background and Refine edges need the matte alone.
        switch session.backgroundContent(needsDepth: model.mode == .focus) {
        case .finding:
            L2Notice(icon: .info, text: "Finding the subject…",
                     actions: [("Cancel", "background.cancel", { session.cancelSubjectSeparation() })])
        case .estimatingDepth:
            L2Notice(icon: .info, text: "Estimating depth…",
                     actions: [("Cancel", "background.cancel", { session.cancelSubjectSeparation() })])
        case .subjectFailed:
            resetRow
            L2Notice(icon: .warn, bold: "Couldn't separate the subject.", text: " Your other edits are kept.",
                     actions: [("Try again", "background.retry", { session.retrySubjectSeparation() })])
        case .depthFailed:
            resetRow
            L2Notice(icon: .warn, bold: "Couldn't measure depth.", text: " Blur needs it. Change background still works.",
                     actions: [("Try again", "background.retry", { session.retrySubjectSeparation() })])
        case .noSubject:
            L2Notice(icon: .info, bold: "No clear subject found.",
                     text: " Change background needs a person or object in front. You can still blur by tapping where to focus.")
            blurSlider
        case .controls:
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
        let c = L2(scheme: colorScheme)
        PanelTabs(items: [(EditRecipe.Focus.Style.lens, "Lens", false), (.soft, "Soft", false), (.swirl, "Swirl", false), (.motion, "Motion", false)],
                  selected: focus.style, wraps: wraps, identifierPrefix: "background.style") { style in
            session.commitBackground { $0.focus.style = style }
        }
        resetRow
        switch focus.style {
        case .lens:
            // "Bokeh" (92 pt, 13 pt semibold ink2), then four 44×36 shape buttons, 14 pt corners, 8 pt apart.
            HStack(spacing: 8) {
                Text("Bokeh").l2Text(13, weight: .semibold).foregroundStyle(c(ApprovedColor.inkSecondary)).frame(width: 92, alignment: .leading)
                ForEach(Self.bokehOptions, id: \.bokeh) { option in
                    let isOn = focus.bokeh == option.bokeh
                    Button { session.commitBackground { $0.focus.bokeh = option.bokeh } } label: {
                        ApprovedIconView(icon: option.icon, size: 18)
                            .foregroundStyle(isOn ? c(ApprovedColor.onInk) : c(ApprovedColor.inkSecondary))
                            .frame(width: 44, height: 36)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isOn ? c(ApprovedColor.segmentSelected) : .clear))
                            .overlay { if !isOn { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c(ApprovedColor.hairline), lineWidth: 1) } }
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(option.bokeh.rawValue) bokeh"))
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityIdentifier("background.bokeh.\(option.bokeh.rawValue)")
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
        HStack(spacing: 10) {
            Button { model.mode = .refine } label: { L2Label(title: Text("Refine edges"), icon: .brush, iconSize: 16) }
                .buttonStyle(L2QuietButtonStyle(accent: true))
                .accessibilityIdentifier("background.refine")
            L2Note(text: Text("Tap the photo to set focus."))
        }
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
        resetRow
        L2Note(text: Text("Brush over the edge to add to or remove from the subject."))
        L2Segmented(options: [(EditRecipe.RefineStroke.Mode.add, Text("Add"), ApprovedIcon.brush, "background.brush.add"),
                              (.erase, Text("Remove"), .erase, "background.brush.erase")],
                    selection: model.brush) { model.brush = $0 }
        PanelSlider(label: "Brush size", value: model.brushSize, range: 0...100, identifier: "slider.brushSize",
                    onChange: { model.brushSize = $0 }, onEnd: { model.brushSize = $0 })
        HStack {
            Spacer(minLength: 0)
            Button("Done") { model.mode = .focus }
                .buttonStyle(L2QuietButtonStyle())
                .accessibilityIdentifier("background.refine.done")
        }
    }

    // MARK: Change background

    @ViewBuilder
    private var change: some View {
        PanelTabs(items: [(BackgroundPanelModel.Kind.image, "Image", false), (.colour, "Colour", false), (.gradient, "Gradient", false)],
                  selected: model.currentKind, wraps: wraps, identifierPrefix: "background.kind") { model.kind = $0 }
        resetRow
        switch model.currentKind {
        case .image:
            imageGrid
            if case .image(_, _, _, let scale)? = model.background.replacement {
                PanelSlider(label: "Scale", value: scale, range: 100...200, identifier: "slider.scale",
                            onChange: { v in session.previewBackground { Self.setScale(&$0, v.rounded()) } },
                            onEnd: { v in session.commitBackground { Self.setScale(&$0, v.rounded()) } })
                L2Note(text: Text("Drag the photo to position the background."))
            }
        case .colour:
            ColourControl(title: "Background colour", selected: backgroundColour, photo: session.originalImage, identifier: "background.colour",
                          preview: { hex in session.previewBackground { $0.replacement = .colour(hex) } },
                          previewImage: { session.displayedImage }, cancel: session.cancelLookPreview) { hex in
                session.commitBackground { $0.replacement = .colour(hex) }
            }
        case .gradient:
            HStack(spacing: 10) {
                ForEach(BackgroundPanelModel.gradients.indices, id: \.self) { index in
                    let g = BackgroundPanelModel.gradients[index]
                    SwatchButton(fill: Self.swiftGradient(g.angle, g.stops),
                                 isOn: model.background.replacement == .gradient(angle: g.angle, stops: g.stops),
                                 label: "Gradient \(index + 1)", identifier: "background.gradient.\(index)") {
                        session.commitBackground { $0.replacement = .gradient(angle: g.angle, stops: g.stops) }
                    }
                    .padding(-4)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 2)
            if case .gradient(let angle, let stops)? = model.background.replacement {
                ForEach(stops.indices, id: \.self) { index in
                    ColourControl(title: "Colour \(index + 1)", selected: stops[index].colour, photo: session.originalImage, identifier: "background.gradient.colour.\(index)",
                                  preview: { hex in var next = stops; next[index].colour = hex; session.previewBackground { $0.replacement = .gradient(angle: angle, stops: next) } },
                                  previewImage: { session.displayedImage }, cancel: session.cancelLookPreview) { hex in
                        var next = stops; next[index].colour = hex
                        session.commitBackground { $0.replacement = .gradient(angle: angle, stops: next) }
                    }
                }
            }
        }
        if model.background.replacement != nil {
            HStack(spacing: 10) {
                Button("Remove background change") { session.commitBackground { $0.replacement = nil } }
                    .buttonStyle(L2QuietButtonStyle())
                    .accessibilityIdentifier("background.remove")
                Spacer(minLength: 0)
            }
            L2Note(text: Text("Focus & Blur still works on the new background."))
        }
    }

    /// Owner amendment 2026-10-11 (second; mockup `backgroundPanel` kind 'image'): two rows like the preset gallery, of
    /// 60 pt tiles 10 pt apart vertically and 8 pt horizontally, filled column by column and scrolling sideways with the
    /// right edge fading; the bundled backgrounds, then the imported photo, then the dashed (+) tile last.
    private var imageGrid: some View {
        BackgroundImageGrid {
            ForEach(BackgroundPanelModel.imageTiles(hasImportedPhoto: session.importedBackgroundImage != nil), id: \.self) { tile in
                imageTile(tile)
            }
        }
    }

    @ViewBuilder
    private func imageTile(_ tile: BackgroundPanelModel.ImageTile) -> some View {
        switch tile {
        case .bundled(let name):
            BackgroundThumbnail(name: name, isOn: isBundled(name)) {
                session.commitBackground {
                    $0.replacement = .image(.bundled(id: name), x: 50, y: 50, scale: Self.currentScale(model.background))
                }
            }
        case .imported:
            if let image = session.importedBackgroundImage {
                BackgroundThumbnailFrame(isOn: isImported) {
                    Image(image, scale: 1, label: Text("Selected background photo")).resizable().scaledToFill()
                }
                .accessibilityIdentifier("background.image.imported")
            }
        case .choosePhoto:
            PhotosPicker(selection: $selectedBackground, matching: .images) { AddBackgroundButton() }
                .buttonStyle(.plain)
                .disabled(importingBackground)
                .accessibilityLabel("Choose a background photo")
                .accessibilityIdentifier("background.image.add")
        }
    }

    private var isImported: Bool {
        // The imported photo is the one replacement image that is not a bundled background.
        if case .image(let asset, _, _, _)? = model.background.replacement, case .bundled = asset { return false }
        if case .image? = model.background.replacement { return true }
        return false
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

/// The two-row background grid (mockup: `grid-auto-flow: column; grid-template-rows: repeat(2, 60px); gap: 10px 8px;
/// padding: 4px 2px`), scrolling sideways; as `ChipRow`, the right edge fades (88 %) only while tiles are hidden past it.
struct BackgroundImageGrid<Content: View>: View {
    static var tileSide: CGFloat { 60 }
    static var rowGap: CGFloat { 10 }
    static var columnGap: CGFloat { 8 }
    @ViewBuilder let content: () -> Content
    @State private var hidesMore = false
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // LazyHGrid places items column by column (`grid-auto-flow: column`). At most nine tiles, all on screen at
            // phone width, so its laziness never hides one.
            LazyHGrid(rows: [GridItem(.fixed(Self.tileSide), spacing: Self.rowGap), GridItem(.fixed(Self.tileSide), spacing: Self.rowGap)],
                      spacing: Self.columnGap) { content() }
                .padding(.vertical, 4).padding(.horizontal, 2)
                .reportsTrailingEdge(in: "backgroundgrid")
        }
        .frame(height: Self.tileSide * 2 + Self.rowGap + 8)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .modifier(TrailingOverflowReader(space: "backgroundgrid", hidesMore: $hidesMore))
        .mask(LinearGradient(stops: [.init(color: .black, location: hidesMore ? 0.88 : 1), .init(color: hidesMore ? .clear : .black, location: 1)],
                             startPoint: .leading, endPoint: .trailing))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("background.images")
    }
}

/// A background choice (Lightly 2): 60 pt, 16 pt corners; when chosen, a 2 pt sheet-coloured gap and a 2 pt accent ring.
struct BackgroundThumbnailFrame<Content: View>: View {
    let isOn: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let c = L2(scheme: colorScheme)
        content()
            .frame(width: 60, height: 60)
            .clipped()   // a filled image overflows its frame; unclipped, it would take a neighbour's taps
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
            .overlay {
                if isOn {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(c(ApprovedColor.sheet), lineWidth: 2).padding(-1)
                    RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(c(ApprovedColor.selection), lineWidth: 2).padding(-3)
                }
            }
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct BackgroundThumbnail: View {
    let name: String
    let isOn: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            BackgroundThumbnailFrame(isOn: isOn) {
                if let image = BundledBackgrounds.thumbnail(name) {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    ApprovedColor.backgroundSecondary.resolved(colorScheme)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Background image"))
        .accessibilityIdentifier("background.image.\(name)")
    }
}

/// The (+) tile: choose a photo from the library as the background. 60 pt, 16 pt corners, 1.5 pt dashed ink3, 22 pt plus.
struct AddBackgroundButton: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        ApprovedIconView(icon: .plus, size: 22)
            .foregroundStyle(ApprovedColor.inkSecondary.resolved(colorScheme))
            .frame(width: 60, height: 60)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(ApprovedColor.inkTertiary.resolved(colorScheme), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .accessibilityLabel(Text("Choose a photo"))
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
