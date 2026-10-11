import SwiftUI

/// The seven tools of the approved editor (`TOOL_NAMES`), in dock order.
enum EditorTool: String, CaseIterable, Identifiable, Sendable {
    case develop, background, portrait, edit, effects, watermark, border

    var id: String { rawValue }

    var title: String {
        switch self {
        case .develop: "Develop"
        case .background: "Background"
        case .portrait: "Portrait"
        case .edit: "Edit"
        case .effects: "Effects"
        case .watermark: "Watermark"
        case .border: "Border"
        }
    }

    var icon: ApprovedIcon {
        switch self {
        case .develop: .develop
        case .background: .background
        case .portrait: .portrait
        case .edit: .edit
        case .effects: .effects
        case .watermark: .watermark
        case .border: .border
        }
    }

    /// Portrait is contextual: offered only when the photo has a person (`toolsFor`).
    static func available(hasPerson: Bool) -> [EditorTool] {
        allCases.filter { $0 != .portrait || hasPerson }
    }
}

/// How the editor is arranged (Lightly 2 device references in docs/ui/directions/lightly-2-concept/index.html).
struct EditorLayout: Equatable {
    enum Mode: Equatable {
        /// Phones (`mode: 'phone'`): glass top bar over the stage, the fixed 340 pt tool panel, the tool dock.
        case phone
        /// Unfolded foldables, iPhone Duo and other regular-width screens (`mode: 'split'`): the header bar, then the
        /// photo and the tool panel in two equal panes.
        case split
        /// Landscape iPad (`mode: 'tablet'`): the header bar, then the tool panel (360 pt), the photo, "Your edit" (290 pt).
        case tablet
    }

    let mode: Mode
    /// The whole screen, safe areas included.
    let screen: CGSize

    /// `PANEL_HEIGHT`: on phones the tool panel is this tall for every tool and state; its contents scroll.
    static let phonePanelHeight: CGFloat = 340

    static func resolve(screen: CGSize, horizontalSizeClass: UserInterfaceSizeClass?, verticalSizeClass: UserInterfaceSizeClass?) -> EditorLayout {
        guard horizontalSizeClass == .regular else { return EditorLayout(mode: .phone, screen: screen) }
        // iPad landscape (both size classes regular, wider than tall, room for three columns) has its own layout.
        let isTablet = verticalSizeClass == .regular && screen.width > screen.height && screen.width >= 1_100
        return EditorLayout(mode: isTablet ? .tablet : .split, screen: screen)
    }
}

// MARK: - Top bar

/// Phone top bar (iOS): a glass capsule with Close, Undo and Redo on the leading side (3 pt padding, 2 pt gaps); on the
/// trailing side, 6 pt apart, the glass hold-to-Compare button, Save and the lime ⋮ More. 12 pt from the screen edges.
struct EditorTopBar: View {
    let session: EditorSession
    let onClose: () -> Void
    let onSave: () -> Void
    let onMore: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let c = L2(scheme: colorScheme)
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                L2IconButton(icon: .close, label: Text("Close"), identifier: "editor.close", action: onClose)
                L2IconButton(icon: .undo, label: Text("Undo"), isEnabled: session.canUndo, identifier: "editor.undo", action: session.undo)
                L2IconButton(icon: .redo, label: Text("Redo"), isEnabled: session.canRedo, identifier: "editor.redo", action: session.redo)
            }
            .padding(3)
            .background(Capsule().fill(c(ApprovedColor.glass)))
            .overlay(Capsule().strokeBorder(c(ApprovedColor.glassLine), lineWidth: 1))
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                CompareButton(session: session, glass: true)
                L2SaveButton(action: onSave)
                L2MoreButton(action: onMore)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52, alignment: .top)
    }
}

/// The header bar of two-pane screens and landscape iPad (`header()`): 60 pt (72 pt on iPad), 24 pt corners, surface,
/// hairline; the app-icon tile, Close, the tools (the selected one named, on an ink fill; on iPad every tool named; an
/// orange dot on tools holding edits), then Undo, Redo, Compare, Save and ⋮ More.
struct EditorHeaderBar: View {
    let session: EditorSession
    let tools: [EditorTool]
    let selected: EditorTool
    let used: Set<EditorTool>
    let namesEveryTool: Bool
    let onSelect: (EditorTool) -> Void
    let onClose: () -> Void
    let onSave: () -> Void
    let onMore: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let c = L2(scheme: colorScheme)
        HStack(spacing: 6) {
            BrandMark(size: 44, style: .tile).accessibilityLabel(Text("Lightly"))
            L2IconButton(icon: .close, label: Text("Close"), identifier: "editor.close", action: onClose)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tools) { tool in
                        let isOn = tool == selected, named = isOn || namesEveryTool
                        Button { onSelect(tool) } label: {
                            HStack(spacing: 8) {
                                ApprovedIconView(icon: tool.icon, size: 20)
                                if named { Text(tool.title).l2Text(14, weight: .semibold).lineLimit(1).fixedSize() }
                            }
                            .foregroundStyle(isOn ? c(ApprovedColor.onInk) : c(ApprovedColor.inkSecondary))
                            .padding(.horizontal, named ? 14 : 0)
                            .frame(width: named ? nil : 44, height: 44)
                            .background(Capsule().fill(isOn ? c(ApprovedColor.segmentSelected) : .clear))
                            .overlay(alignment: .topTrailing) {
                                if used.contains(tool) { Circle().fill(c(ApprovedColor.edited)).frame(width: 5, height: 5).padding(7) }
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(UndimmedButtonStyle())
                        .accessibilityLabel(Text(tool.title))
                        .accessibilityValue(Text(used.contains(tool) ? "Edited" : ""))
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                        .accessibilityIdentifier("tool.\(tool.rawValue)")
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .padding(.leading, 4)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                L2IconButton(icon: .undo, label: Text("Undo"), isEnabled: session.canUndo, identifier: "editor.undo", action: session.undo)
                L2IconButton(icon: .redo, label: Text("Redo"), isEnabled: session.canRedo, identifier: "editor.redo", action: session.redo)
                CompareButton(session: session, glass: false)
                L2SaveButton(action: onSave)
                L2MoreButton(action: onMore)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: namesEveryTool ? 72 : 60)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(c(ApprovedColor.surface)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(c(ApprovedColor.hairline), lineWidth: 1))
    }
}

/// Draws the label exactly as given: no pressed or disabled dimming beyond the label's own colours.
struct UndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Compare: shows the original while pressed. A 44 pt circle (glass on phones), ink-filled while showing the original
/// (`iconBtn('compare', …, { glass, on })`). For VoiceOver and Switch Control the same button is a toggle.
struct CompareButton: View {
    let session: EditorSession
    var glass = false
    @State private var isPressing = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let c = L2(scheme: colorScheme)
        let on = session.isShowingOriginal
        ApprovedIconView(icon: .compare, size: 20)
            .foregroundStyle(on ? c(ApprovedColor.onInk) : glass ? c(ApprovedColor.glassInk) : c(ApprovedColor.ink))
            .frame(width: 44, height: 44)
            .background(Circle().fill(on ? c(ApprovedColor.segmentSelected) : glass ? c(ApprovedColor.glass) : .clear))
            .overlay { if glass && !on { Circle().strokeBorder(c(ApprovedColor.glassLine), lineWidth: 1) } }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressing else { return }
                    isPressing = true
                    session.beginCompare()
                }
                .onEnded { _ in
                    isPressing = false
                    session.endCompare()
                })
            .accessibilityElement()
            .accessibilityLabel(Text("Hold to compare with the original"))
            .accessibilityValue(Text(on ? "Showing the original" : "Showing your edit"))
            .accessibilityAddTraits([.isButton, .isToggle])
            .accessibilityAction { session.toggleCompare() }
            .accessibilityIdentifier("editor.compare")
    }
}

// MARK: - Photo stage

/// The photo stage (`photo()` in the Lightly 2 mockup): the photo contain-fitted inside a 12 pt (sides) / 8 pt
/// (top and bottom) inset, never cropped, with 18 pt corners (3 pt with a border). The stage itself is transparent:
/// its container provides the colour (--bg on phones, --stage in panes). While comparing, the original carries the
/// "Original" badge.
struct PhotoStage<Overlay: View, Marks: View>: View {
    let image: CGImage
    var showsOriginalBadge = false
    /// `.pic` with a border: `box-shadow:0 0 0 1px rgba(0,0,0,.12)`, a 1 pt ring just outside the
    /// canvas so a white border stays visible on the stage.
    var outlinesCanvas = false
    var marksCoverCanvas = false
    var cropWorkspace = false
    /// Inline crop (owner, 2026-10-11): the applied crop rectangle (fractions of the shown, uncropped frame). The photo
    /// glides and zooms so this area fills the stage (24 pt clear of its edges), the dimmed rest around it; nil leaves
    /// the photo fitted as usual. A drag in progress keeps the zoom of the applied crop until the finger lifts.
    var cropFocus: EditRecipe.Rect?
    var allowsInspection = false
    var allowsDoubleTapZoom = true
    var onInspectionBegan: () -> Void = {}
    var photoChrome = AnyView(EmptyView())
    /// The photo inside the canvas, as fractions (prototype `.imgbox` inside `.frame`): marks are
    /// laid over this box, not over the border.
    var imageBox = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Reports the displayed photo's size in points (the image box of the fitted canvas).
    var onPhotoSize: ((CGSize) -> Void)?
    @ViewBuilder var overlay: () -> Overlay
    /// Marks laid over the fitted photo itself (prototype `marks` inside `.imgbox`).
    @ViewBuilder var marks: () -> Marks

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let fitted = Self.fittedSize(image: CGSize(width: image.width, height: image.height),
                                         in: CGSize(width: max(1, geometry.size.width - 24), height: max(1, geometry.size.height - 16)))
            ZStack {
                InspectionViewport(enabled: allowsInspection, doubleTapEnabled: allowsDoubleTapZoom, contentSize: fitted, viewportSize: geometry.size, onInspectionBegan: onInspectionBegan) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                    .clipShape(RoundedRectangle(cornerRadius: outlinesCanvas ? 3 : 18, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if showsOriginalBadge {
                            Text("Original")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.55)))
                                .padding(12)
                                .accessibilityIdentifier("editor.originalBadge")
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(Text(showsOriginalBadge ? "Photo, original" : "Photo"))
                    .accessibilityIdentifier("editor.photo")
                    .overlay {
                        // `.imgbox` is `overflow:hidden`: marks are clipped to the photo.
                        GeometryReader { canvas in
                            let box = marksCoverCanvas ? CGRect(x: 0, y: 0, width: 1, height: 1) : imageBox
                            marks()
                                .frame(width: canvas.size.width * box.width, height: canvas.size.height * box.height)
                                .clipped()
                                .offset(x: canvas.size.width * box.minX, y: canvas.size.height * box.minY)
                        }
                    }
                    .modifier(CropFocusTransform(focus: cropFocus, fitted: fitted, viewport: geometry.size))
                }
                photoChrome
                    .frame(width: fitted.width * imageBox.width, height: fitted.height * imageBox.height)
                    .offset(x: fitted.width * (imageBox.midX - 0.5), y: fitted.height * (imageBox.midY - 0.5))
                overlay()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onChange(of: CGSize(width: fitted.width * imageBox.width, height: fitted.height * imageBox.height), initial: true) { _, size in
                onPhotoSize?(size)
            }
        }
        // The crop workspace is #141414 in both themes (`cropWorkspace`).
        .background(cropWorkspace ? Color(hex: 0x141414) : Color.clear)
        .clipped()
    }

    /// `width: min(100cqw, 100cqh · r)`: the largest size of the photo's aspect ratio that fits.
    static func fittedSize(image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let ratio = image.width / image.height
        let width = min(box.width, box.height * ratio)
        return CGSize(width: width, height: width / ratio)
    }
}

/// Inline crop: scales and moves the fitted photo (and its marks, so gestures stay in photo coordinates) so the applied
/// crop fills the stage 24 pt clear of its edges, with a smooth glide whenever the applied crop changes. A full-frame
/// crop, or none, leaves the photo as fitted.
private struct CropFocusTransform: ViewModifier {
    let focus: EditRecipe.Rect?
    let fitted: CGSize
    let viewport: CGSize

    func body(content: Content) -> some View {
        let (scale, offset) = placement()
        content
            .scaleEffect(scale)
            .offset(offset)
            .animation(.smooth(duration: 0.35), value: focus)
    }

    private func placement() -> (CGFloat, CGSize) {
        guard let focus, fitted.width > 0, fitted.height > 0 else { return (1, .zero) }
        let cropWidth = max(1, focus.width * fitted.width), cropHeight = max(1, focus.height * fitted.height)
        let scale = min(6, max(1, min((viewport.width - 48) / cropWidth, (viewport.height - 48) / cropHeight)))
        let centreX = (focus.x + focus.width / 2 - 0.5) * fitted.width
        let centreY = (focus.y + focus.height / 2 - 0.5) * fitted.height
        return (scale, CGSize(width: -centreX * scale, height: -centreY * scale))
    }
}

extension PhotoStage where Overlay == EmptyView, Marks == EmptyView {
    init(image: CGImage, showsOriginalBadge: Bool = false) {
        self.init(image: image, showsOriginalBadge: showsOriginalBadge, overlay: { EmptyView() }, marks: { EmptyView() })
    }
}

extension PhotoStage where Marks == EmptyView {
    init(image: CGImage, showsOriginalBadge: Bool = false, @ViewBuilder overlay: @escaping () -> Overlay) {
        self.init(image: image, showsOriginalBadge: showsOriginalBadge, overlay: overlay, marks: { EmptyView() })
    }
}

/// `progressCard`: at least 190 pt wide, 16/18 padding, 20 pt corners, rgba(14,15,17,.82); a 24 pt lime spinner, the
/// label (14 pt semibold, #F2F3F0; an optional 12 pt sub-line at 75 %), an optional 150×4 lime bar on 20 % white, and
/// an optional Cancel (34 pt capsule, 12 % white, 13 pt semibold), 10 pt apart.
struct ProgressBox<Extra: View>: View {
    let title: String
    var subtitle: String?
    var barFraction: CGFloat?
    /// Kept for call sites; the card is as wide as its content (at least 190 pt).
    var maximumWidth: CGFloat?
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(spacing: 10) {
            RingSpinner()
            VStack(spacing: 2) {
                Text(LocalizedStringKey(title)).font(.system(size: 14, weight: .semibold))
                if let subtitle { Text(LocalizedStringKey(subtitle)).font(.system(size: 12, weight: .medium)).opacity(0.75) }
            }
            .fixedSize(horizontal: false, vertical: true)
            if let barFraction {
                Capsule().fill(.white.opacity(0.2)).frame(width: 150, height: 4)
                    .overlay(alignment: .leading) { Capsule().fill(Color(hex: 0xCFF26B)).frame(width: 150 * barFraction) }
            }
            extra()
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(Color(hex: 0xF2F3F0))
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(minWidth: 190)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: 0x0E0F11, opacity: 0.82)))
        .accessibilityElement(children: .contain)
    }
}

/// The progress card's Cancel: 34 pt capsule, 14 pt padding, 12 % white, 13 pt semibold.
struct ProgressCancelButton: View {
    let identifier: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("Cancel").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0xF2F3F0))
                .padding(.horizontal, 14).frame(height: 34)
                .background(Capsule().fill(.white.opacity(0.12)))
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// The 24 pt spinner: a 3 pt lime ring with its right quarter open, turning.
struct RingSpinner: View {
    @State private var angle: Double = 0
    var body: some View {
        Circle().inset(by: 1.5).trim(from: 0, to: 0.75)
            .stroke(Color(hex: 0xCFF26B), style: StrokeStyle(lineWidth: 3))
            .rotationEffect(.degrees(-45 + angle))
            .frame(width: 24, height: 24)
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { angle = 360 } }
            .accessibilityHidden(true)
    }
}

// MARK: - Tool navigation

/// The phone tool dock (`phoneDock`): 62 pt plus the bottom inset, a hairline above, the tools in equal slots
/// (6 pt top, 4 pt side padding). iOS: 22 pt icon (accent when selected), 9.5 pt semibold label (ink when selected,
/// ink3 otherwise), then a 4 pt dot slot, orange on tools holding edits. Android: the selected icon sits on a 46×30
/// lime pill (`android` style).
struct ToolNavigation: View {
    let tools: [EditorTool]
    let selected: EditorTool
    let used: Set<EditorTool>
    var androidStyle = false
    let onSelect: (EditorTool) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let c = L2(scheme: colorScheme)
        HStack(spacing: 0) {
            ForEach(tools) { tool in
                let isOn = tool == selected
                Button { onSelect(tool) } label: {
                    VStack(spacing: 3) {
                        ApprovedIconView(icon: tool.icon, size: 22)
                            .foregroundStyle(isOn ? c(ApprovedColor.selection) : c(ApprovedColor.inkTertiary))
                        Text(tool.title).l2Text(9.5, weight: .semibold).lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(isOn ? c(ApprovedColor.ink) : c(ApprovedColor.inkTertiary))
                        Circle().fill(used.contains(tool) ? c(ApprovedColor.edited) : .clear).frame(width: 4, height: 4)
                    }
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .top)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(tool.title))
                .accessibilityValue(Text(used.contains(tool) ? "Edited" : ""))
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("tool.\(tool.rawValue)")
            }
        }
        .padding(.horizontal, 4).padding(.top, 6)
        .frame(height: 62, alignment: .top)
        .overlay(alignment: .top) { Rectangle().fill(c(ApprovedColor.hairline)).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tools"))
    }
}

/// "Your edit" (landscape iPad, right column): every tool with its state and an orange dot when it holds an edit; the
/// selected tool's row on a chip fill (14 pt corners), the others divided by hairlines; then the reassurance line.
struct EditSummaryPanel: View {
    let rows: [(tool: EditorTool, value: String, edited: Bool)]
    let selected: EditorTool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let c = L2(scheme: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            Text("Your edit").l2Heading(17).foregroundStyle(c(ApprovedColor.ink)).padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(rows, id: \.tool) { row in
                let isOn = row.tool == selected
                HStack(spacing: 10) {
                    ApprovedIconView(icon: row.tool.icon, size: 18).foregroundStyle(c(ApprovedColor.inkSecondary))
                    Text(row.tool.title).l2Text(14, weight: .semibold).foregroundStyle(c(ApprovedColor.ink))
                    Spacer(minLength: 8)
                    Text(LocalizedStringKey(row.value)).l2Text(12).foregroundStyle(c(ApprovedColor.inkSecondary))
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: 130, alignment: .trailing)
                    Circle().fill(row.edited ? c(ApprovedColor.edited) : .clear).frame(width: 6, height: 6)
                }
                .frame(minHeight: 50)
                .padding(.horizontal, isOn ? 10 : 0)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isOn ? c(ApprovedColor.chip) : .clear))
                .padding(.horizontal, isOn ? -10 : 0)
                .padding(.vertical, isOn ? 2 : 0)
                .overlay(alignment: .bottom) { if !isOn { Rectangle().fill(c(ApprovedColor.hairline)).frame(height: 1) } }
                .accessibilityElement(children: .combine)
            }
            Text("Edits stay on this device. Save writes a new photo; the original is unchanged.")
                .l2Text(12, lineHeight: 1.4).foregroundStyle(c(ApprovedColor.inkTertiary))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
    }
}

struct ApprovedVerticalHairline: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Rectangle().fill(ApprovedColor.hairline.resolved(colorScheme)).frame(width: 1).accessibilityHidden(true)
    }
}

/// A panel body that is as tall as its content up to `maximumHeight`, then scrolls
/// (`.panelbody { max-height; overflow-y: auto }`).
struct CappedScrollView<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content()
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: CappedScrollHeightKey.self, value: proxy.size.height)
                })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(contentHeight, 1), maximumHeight))
        .onPreferenceChange(CappedScrollHeightKey.self) { contentHeight = $0 }
    }
}

private struct CappedScrollHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// CSS shrink-to-fit width: the content's own (single-line) width, at least `minimum`, at most
/// `maximum` (wrapping beyond it). An absolutely positioned box with `min-width` behaves so.
struct ShrinkToFitWidth: ViewModifier {
    let minimum: CGFloat
    let maximum: CGFloat?
    func body(content: Content) -> some View {
        ShrinkToFitLayout(minimum: minimum, maximum: maximum) { content }
    }
}

private struct ShrinkToFitLayout: Layout {
    let minimum: CGFloat
    let maximum: CGFloat?

    private func width(_ subview: LayoutSubview) -> CGFloat {
        let natural = subview.sizeThatFits(.unspecified).width
        return max(minimum, min(natural, maximum ?? .infinity))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let w = width(subview)
        return CGSize(width: w, height: subview.sizeThatFits(ProposedViewSize(width: w, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        // `.progress { min-width: 200px; text-align: center }`: content narrower than the box is
        // centred in it, not left at its leading edge.
        subview.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
                      proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}


/// Inspection is view state only. Two fingers navigate so one-finger editing gestures keep their
/// original coordinate system. Updating the rendered image never resets the viewport.
private struct InspectionViewport<Content: View>: UIViewRepresentable {
    let enabled: Bool
    let doubleTapEnabled: Bool
    let contentSize: CGSize
    let viewportSize: CGSize
    var onInspectionBegan: () -> Void
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(content()) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.backgroundColor = .clear
        scroll.delaysContentTouches = false
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = enabled ? 6 : 1
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.bouncesZoom = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.panGestureRecognizer.addTarget(context.coordinator, action: #selector(Coordinator.navigationBegan(_:)))
        scroll.pinchGestureRecognizer?.addTarget(context.coordinator, action: #selector(Coordinator.navigationBegan(_:)))
        scroll.accessibilityIdentifier = "editor.inspection"
        let host = context.coordinator.host
        host.view.backgroundColor = .clear
        scroll.addSubview(host.view)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        tap.isEnabled = enabled && doubleTapEnabled
        scroll.addGestureRecognizer(tap)
        context.coordinator.doubleTapRecognizer = tap
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let c = context.coordinator
        c.host.rootView = content()
        c.onInspectionBegan = onInspectionBegan
        scroll.maximumZoomScale = enabled ? 6 : 1
        scroll.panGestureRecognizer.isEnabled = enabled
        c.doubleTapRecognizer?.isEnabled = enabled && doubleTapEnabled
        // Resizing the panel must not reset zoom. Geometry remains the unzoomed fitted photo.
        if c.contentSize != contentSize || c.viewportSize != viewportSize {
            let scale = scroll.zoomScale
            let centre = CGPoint(x: (scroll.contentOffset.x + c.viewportSize.width / 2) / max(c.contentSize.width * scale, 1),
                                 y: (scroll.contentOffset.y + c.viewportSize.height / 2) / max(c.contentSize.height * scale, 1))
            let wasLaidOut = c.contentSize != .zero
            c.contentSize = contentSize
            c.viewportSize = viewportSize
            c.host.view.bounds = CGRect(origin: .zero, size: contentSize)
            c.host.view.center = CGPoint(x: contentSize.width * scale / 2, y: contentSize.height * scale / 2)
            scroll.contentSize = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
            c.centre(scroll)
            if wasLaidOut {
                let x = centre.x * scroll.contentSize.width - viewportSize.width / 2
                let y = centre.y * scroll.contentSize.height - viewportSize.height / 2
                scroll.contentOffset = CGPoint(
                    x: min(max(x, -scroll.contentInset.left), max(-scroll.contentInset.left, scroll.contentSize.width - viewportSize.width + scroll.contentInset.right)),
                    y: min(max(y, -scroll.contentInset.top), max(-scroll.contentInset.top, scroll.contentSize.height - viewportSize.height + scroll.contentInset.bottom)))
            } else { scroll.contentOffset = CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top) }
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let host: UIHostingController<Content>
        var contentSize = CGSize.zero
        var viewportSize = CGSize.zero
        var onInspectionBegan: () -> Void = {}
        weak var doubleTapRecognizer: UITapGestureRecognizer?
        init(_ content: Content) { host = UIHostingController(rootView: content) }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }
        func centre(_ scroll: UIScrollView) {
            let x = max(0, (viewportSize.width - contentSize.width * scroll.zoomScale) / 2)
            let y = max(0, (viewportSize.height - contentSize.height * scroll.zoomScale) / 2)
            scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
            scroll.accessibilityValue = String(format: "%.1f times", scroll.zoomScale)
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { centre(scrollView) }
        @objc func navigationBegan(_ recognizer: UIGestureRecognizer) {
            if recognizer.state == .began { onInspectionBegan() }
        }
        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scroll = recognizer.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 { scroll.setZoomScale(1, animated: true) }
            else {
                let point = recognizer.location(in: host.view)
                let size = CGSize(width: viewportSize.width / 2.5, height: viewportSize.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
