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

    /// The delivery slice that builds the tool (docs/v1/implementation-checklist.md).
    var slice: Int {
        switch self {
        case .develop: 2
        case .background, .portrait: 3
        case .edit, .effects: 4
        case .watermark, .border: 5
        }
    }

    /// Portrait is contextual: offered only when the photo has a person (`toolsFor`).
    static func available(hasPerson: Bool) -> [EditorTool] {
        allCases.filter { $0 != .portrait || hasPerson }
    }
}

/// How the editor is arranged (`layoutFor` in docs/ui/app/data.js).
struct EditorLayout: Equatable {
    enum Mode: Equatable {
        /// Phones: controls under the photo, tools in a scrolling dock.
        case below
        /// Tablet portrait: centred controls under a large photo, tools in a centred dock.
        case wide
        /// Tablet landscape: a side panel and a tool rail beside the photo.
        case side
    }

    let mode: Mode
    /// The whole screen, safe areas included (`L.w`, `L.h`).
    let screen: CGSize
    /// 13-inch tablets (`big`): a wider panel and content column.
    let isLarge: Bool

    var panelWidth: CGFloat { isLarge ? 400 : 360 }
    var contentWidth: CGFloat { isLarge ? 640 : 600 }

    /// `below`: the panel never takes more than 34 % of the height (it scrolls); `wide`: 30 %.
    var panelMaximumHeight: CGFloat { (screen.height * (mode == .wide ? 0.3 : 0.34)).rounded() }

    static func resolve(screen: CGSize, horizontalSizeClass: UserInterfaceSizeClass?, verticalSizeClass: UserInterfaceSizeClass?) -> EditorLayout {
        let isTablet = horizontalSizeClass == .regular && verticalSizeClass == .regular
        guard isTablet else { return EditorLayout(mode: .below, screen: screen, isLarge: false) }
        // The 13-inch iPad's short side is 1032 pt, the 11-inch's 834 pt.
        let isLarge = min(screen.width, screen.height) >= 1_000
        return EditorLayout(mode: screen.width > screen.height ? .side : .wide, screen: screen, isLarge: isLarge)
    }
}

// MARK: - Top bar

/// `.topbar`: Close, Undo, Redo, hold-to-Compare; Save copy and ⋮ More at the end.
struct EditorTopBar: View {
    let session: EditorSession
    let onClose: () -> Void
    let onSave: () -> Void
    let onMore: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            barButton(.close, label: "Close", identifier: "editor.close", enabled: true, action: onClose)
            barButton(.undo, label: "Undo", identifier: "editor.undo", enabled: session.canUndo, action: session.undo)
            barButton(.redo, label: "Redo", identifier: "editor.redo", enabled: session.canRedo, action: session.redo)
            CompareButton(session: session)
            Spacer(minLength: 0)
            Button(action: onSave) {
                Text("Save copy")
                    .approvedText(15, weight: .semibold)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(ApprovedColor.background.resolved(colorScheme))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ApprovedColor.ink.resolved(colorScheme)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("editor.saveCopy")
            barButton(.more, label: "More", identifier: "editor.more", enabled: true, action: onMore)
        }
        .padding(.horizontal, 6)
        .frame(height: 48)
    }

    private func barButton(_ icon: ApprovedIcon, label: String, identifier: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ApprovedIconView(icon: icon, size: 22)
                .foregroundStyle((enabled ? ApprovedColor.ink : ApprovedColor.inkTertiary).resolved(colorScheme))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        // `.ib[disabled]` is ink3 at full opacity; the plain style would dim it further.
        .buttonStyle(UndimmedButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }
}

/// Draws the label exactly as given: no pressed or disabled dimming beyond the label's own colours.
struct UndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Compare: shows the original while pressed (`pointerdown` / `pointerup`). For VoiceOver and
/// Switch Control the same button is a toggle (activate to show the original, again to return).
struct CompareButton: View {
    let session: EditorSession
    @State private var isPressing = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ApprovedIconView(icon: .compare, size: 22)
            .foregroundStyle((session.isShowingOriginal ? ApprovedColor.selection : ApprovedColor.ink).resolved(colorScheme))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
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
            .accessibilityValue(Text(session.isShowingOriginal ? "Showing the original" : "Showing your edit"))
            .accessibilityAddTraits([.isButton, .isToggle])
            .accessibilityAction { session.toggleCompare() }
            .accessibilityIdentifier("editor.compare")
    }
}

// MARK: - Photo stage

/// `.stage`: the canvas colour with the photo contain-fitted, never cropped. While comparing, the
/// original carries the "Original" badge (`.badge`).
struct PhotoStage<Overlay: View>: View {
    let image: CGImage
    var showsOriginalBadge = false
    @ViewBuilder var overlay: () -> Overlay

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let fitted = Self.fittedSize(image: CGSize(width: image.width, height: image.height), in: geometry.size)
            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                    .overlay(alignment: .topLeading) {
                        if showsOriginalBadge {
                            Text("Original")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.55)))
                                .padding(10)
                                .accessibilityIdentifier("editor.originalBadge")
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(Text(showsOriginalBadge ? "Photo, original" : "Photo"))
                    .accessibilityIdentifier("editor.photo")
                overlay()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(ApprovedColor.canvas.resolved(colorScheme))
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

extension PhotoStage where Overlay == EmptyView {
    init(image: CGImage, showsOriginalBadge: Bool = false) {
        self.init(image: image, showsOriginalBadge: showsOriginalBadge, overlay: { EmptyView() })
    }
}

/// `.progress`: the dark rounded box with a spinner, a label and a bar.
///
/// Over the photo the box is absolutely positioned at `left: 50%`, so CSS shrink-to-fit gives it
/// at most half the stage's width (it is 200 pt minimum): on a phone the subtitle wraps there.
/// Over the saving scrim it is in normal flow and takes its natural width.
struct ProgressBox<Extra: View>: View {
    let title: String
    var subtitle: String?
    let barFraction: CGFloat
    /// Half the stage width over the photo; nil in normal flow.
    var maximumWidth: CGFloat?
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(spacing: 0) {
            RingSpinner().padding(.bottom, 8)
            Text(title).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            if let subtitle { Text(subtitle).font(.system(size: 13)).opacity(0.75).fixedSize(horizontal: false, vertical: true) }
            Capsule().fill(.white.opacity(0.25)).frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in Capsule().fill(.white).frame(width: proxy.size.width * barFraction) }
                }
                .padding(.top, 10)
            extra()
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .modifier(ShrinkToFitWidth(minimum: 200, maximum: maximumWidth.map { max(200, $0) }))
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 20 / 255, green: 20 / 255, blue: 22 / 255).opacity(0.72)))
        .accessibilityElement(children: .contain)
    }
}

/// `.spinner`: a 22 pt ring, 2.5 pt, 35 % white with a white top quarter. The prototype draws it
/// still; here it turns, as a spinner does, and every frame looks like the approved one.
struct RingSpinner: View {
    @State private var angle: Double = 0
    var body: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2.5)
            Circle().inset(by: 1.25).trim(from: 0.625, to: 0.875).stroke(.white, lineWidth: 2.5)
        }
        .frame(width: 22, height: 22)
        .rotationEffect(.degrees(angle))
        .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { angle = 360 } }
        .accessibilityHidden(true)
    }
}

// MARK: - Tool navigation

/// `.dock` (phones and tablet portrait) or `.rail` (tablet landscape). Every approved tool is
/// shown; Portrait only when the photo has a person. A dot marks tools that hold edits.
struct ToolNavigation: View {
    enum Kind { case dockScrolls, dockFits, rail }

    let kind: Kind
    let tools: [EditorTool]
    let selected: EditorTool
    let used: Set<EditorTool>
    let onSelect: (EditorTool) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch kind {
        case .rail:
            VStack(spacing: 2) {
                ForEach(tools) { toolButton($0, minHeight: 62) }
            }
            .frame(width: 84)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) { ApprovedVerticalHairline() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Tools"))
        case .dockFits:
            HStack(spacing: 6) {
                ForEach(tools) { toolButton($0, minHeight: 56) }
            }
            .padding(.horizontal, 4).padding(.top, 3)  // border-top 1 + padding-top 2
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) { ApprovedHairline() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Tools"))
        case .dockScrolls:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tools) { toolButton($0, minHeight: 56) }
                }
                .padding(.horizontal, 4).padding(.top, 3)  // border-top 1 + padding-top 2
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            // `.dock.scrolls`: mask-image: linear-gradient(90deg, #000 86%, transparent).
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .overlay(alignment: .top) { ApprovedHairline() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Tools"))
        }
    }

    private func toolButton(_ tool: EditorTool, minHeight: CGFloat) -> some View {
        let isOn = tool == selected
        let isUsed = used.contains(tool)
        return Button { onSelect(tool) } label: {
            VStack(spacing: 3) {
                ApprovedIconView(icon: tool.icon, size: 22)
                    .foregroundStyle((isOn ? ApprovedColor.selection : ApprovedColor.inkTertiary).resolved(colorScheme))
                Text(tool.title)
                    .approvedText(11, weight: .medium)
                    .lineLimit(1)
                    .fixedSize()
                if isUsed {
                    Circle()
                        .fill((isOn ? ApprovedColor.selection : ApprovedColor.inkTertiary).resolved(colorScheme))
                        .frame(width: 4, height: 4)
                        .padding(.top, 1)
                }
            }
            .foregroundStyle((isOn ? ApprovedColor.ink : ApprovedColor.inkTertiary).resolved(colorScheme))
            .frame(width: kind == .rail ? 84 : 76)
            .frame(minHeight: minHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(tool.title))
        .accessibilityValue(Text(isUsed ? "Edited" : ""))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("tool.\(tool.rawValue)")
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
        subview.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
