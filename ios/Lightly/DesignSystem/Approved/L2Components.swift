import SwiftUI

// Lightly 2 controls, copied from the approved mockup's component functions
// (docs/ui/directions/lightly-2-concept/index.html: iconBtn, moreBtn, primary, lineBtn, quietBtn, linkBtn, saveBtn,
// chips, seg, tabs, slider, note, notice, toggle, toggleRow, resetRow, colourStrip, listRow, card, groupLabel).
// Sizes are the mockup's CSS px, used as points. Text is the system font, as the approved screens render it.

// MARK: - Text

/// Mockup text: the system font at `size` (CSS px), scaled with the person's text size, natural line height
/// (the mockup sets no line-height except where `lineSpacing` is given).
struct L2TextStyle: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    var tracking: CGFloat = 0
    /// CSS `line-height` as a multiple of the size (e.g. 1.4 for notes); nil = normal.
    var lineHeight: CGFloat?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let scaled = ApprovedType.scaledSize(size, for: dynamicTypeSize)
        let natural = ApprovedType.uiFont(size: scaled, weight: weight).lineHeight
        let extra = lineHeight.map { max(0, scaled * $0 - natural) } ?? 0
        content
            .font(.system(size: scaled, weight: weight))
            .tracking(tracking)
            .lineSpacing(extra)
    }
}

extension View {
    func l2Text(_ size: CGFloat, weight: Font.Weight = .regular, tracking: CGFloat = 0, lineHeight: CGFloat? = nil) -> some View {
        modifier(L2TextStyle(size: size, weight: weight, tracking: tracking, lineHeight: lineHeight))
    }
    /// `HEAD`: the heading face (renders as the system font, weight 600).
    func l2Heading(_ size: CGFloat, tracking: CGFloat = 0) -> some View {
        l2Text(size, weight: .semibold, tracking: tracking)
    }
}

/// Resolves a token for the current scheme.
struct L2 {
    let scheme: ColorScheme
    func callAsFunction(_ token: ApprovedColor.Token) -> Color { token.resolved(scheme) }
}

// MARK: - Buttons

/// `iconBtn`: a 44 pt circle; plain (transparent, ink), `glass` (glass fill, glass line) or `on` (ink fill).
struct L2IconButton: View {
    let icon: ApprovedIcon
    let label: Text
    var glass = false
    var isOn = false
    var isEnabled = true
    var size: CGFloat = 44
    var identifier: String?
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = L2(scheme: scheme)
        Button(action: action) {
            ApprovedIconView(icon: icon, size: 20)
                .foregroundStyle(isOn ? c(ApprovedColor.onInk) : glass ? c(ApprovedColor.glassInk) : c(ApprovedColor.ink))
                .frame(width: size, height: size)
                .background(Circle().fill(isOn ? c(ApprovedColor.segmentSelected) : glass ? c(ApprovedColor.glass) : .clear))
                .overlay { if glass && !isOn { Circle().strokeBorder(c(ApprovedColor.glassLine), lineWidth: 1) } }
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.38)
        }
        .buttonStyle(UndimmedButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// `moreBtn`: ⋮ on a lime 44 pt circle with the 1 pt lime rim.
struct L2MoreButton: View {
    var size: CGFloat = 44
    var identifier = "editor.more"
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = L2(scheme: scheme)
        Button(action: action) {
            ApprovedIconView(icon: .more, size: 20)
                .foregroundStyle(c(ApprovedColor.onAccent))
                .frame(width: size, height: size)
                .background(Circle().fill(c(ApprovedColor.accent)))
                .overlay(Circle().strokeBorder(c(ApprovedColor.accentEdge), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(UndimmedButtonStyle())
        .accessibilityLabel(Text("More"))
        .accessibilityIdentifier(identifier)
    }
}

/// `saveBtn`: "Save", 44 pt lime capsule, 16 pt padding, 14 pt bold, 1 pt rim.
struct L2SaveButton: View {
    var height: CGFloat = 44
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = L2(scheme: scheme)
        Button(action: action) {
            Text("Save")
                .l2Text(14, weight: .bold)
                .lineLimit(1).fixedSize()
                .foregroundStyle(c(ApprovedColor.onAccent))
                .padding(.horizontal, 16)
                .frame(height: height)
                .background(Capsule().fill(c(ApprovedColor.accent)))
                .overlay(Capsule().strokeBorder(c(ApprovedColor.accentEdge), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(UndimmedButtonStyle())
        .accessibilityIdentifier("editor.saveCopy")
    }
}

/// `primary` (lime, rim) and `lineBtn` (outlined): full-width capsules, 15 pt, icon 20 pt, 10 pt gap.
struct L2WideButtonStyle: ButtonStyle {
    enum Kind { case primary, line }
    let kind: Kind
    var height: CGFloat = 52
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let c = L2(scheme: scheme)
        configuration.label
            .l2Text(15, weight: kind == .primary ? .bold : .semibold)
            .labelStyle(L2IconLabelStyle(spacing: 10, iconSize: 20))
            .foregroundStyle(kind == .primary ? c(ApprovedColor.onAccent) : c(ApprovedColor.ink))
            .frame(maxWidth: .infinity, minHeight: height)
            .background(Capsule().fill(kind == .primary ? c(ApprovedColor.accent) : .clear))
            .overlay(Capsule().strokeBorder(kind == .primary ? c(ApprovedColor.accentEdge) : c(ApprovedColor.hairline), lineWidth: 1))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// `quietBtn`: a chip-filled capsule, 38 pt (or `height`), 14 pt padding, 13 pt semibold; `accent` colours the text.
struct L2QuietButtonStyle: ButtonStyle {
    var height: CGFloat = 38
    var accent = false
    var dimmed = false
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let c = L2(scheme: scheme)
        configuration.label
            .l2Text(13, weight: .semibold)
            .labelStyle(L2IconLabelStyle(spacing: 6, iconSize: 16))
            .lineLimit(1).fixedSize()
            .foregroundStyle(accent ? c(ApprovedColor.selection) : c(ApprovedColor.ink))
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(Capsule().fill(c(ApprovedColor.chip)))
            .contentShape(Capsule())
            .opacity(dimmed ? 0.4 : (configuration.isPressed ? 0.7 : 1))
    }
}

/// `linkBtn`: accent text, 13 pt bold, optional 15 pt icon, 34 pt tall.
struct L2LinkButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .l2Text(13, weight: .bold)
            .labelStyle(L2IconLabelStyle(spacing: 5, iconSize: 15))
            .lineLimit(1).fixedSize()
            .foregroundStyle(L2(scheme: scheme)(ApprovedColor.selection))
            .padding(.horizontal, 2)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A `Label` whose icon is an `ApprovedIcon` (via `L2Label`) laid out as the mockup's inline-flex buttons.
struct L2IconLabelStyle: LabelStyle {
    var spacing: CGFloat
    var iconSize: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) { configuration.icon; configuration.title }
    }
}

/// A label with an `ApprovedIcon` (the mockup's `${ic(name, size)}Title`).
struct L2Label: View {
    let title: Text
    var icon: ApprovedIcon?
    var iconSize: CGFloat = 16
    /// The icon follows the title (`linkBtn('More colours', 'chevron')`).
    var iconTrailing = false
    var body: some View {
        HStack(spacing: iconSize >= 20 ? 10 : (iconSize >= 16 ? 6 : 5)) {
            if let icon, !iconTrailing { ApprovedIconView(icon: icon, size: iconSize) }
            title
            if let icon, iconTrailing { ApprovedIconView(icon: icon, size: iconSize) }
        }
    }
}

// MARK: - Selection controls

/// `chips`: 38 pt capsules, 13 pt padding, 13 pt semibold; selected = ink fill, on-ink text; others outlined, ink2.
struct L2Chip: View {
    let title: Text
    let isOn: Bool
    var icon: ApprovedIcon?
    var showsEditedDot = false
    var identifier: String?
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = L2(scheme: scheme)
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { ApprovedIconView(icon: icon, size: 18) }
                title.l2Text(13, weight: .semibold).lineLimit(1).fixedSize()
                if showsEditedDot { Circle().fill(c(ApprovedColor.edited)).frame(width: 5, height: 5) }
            }
            .foregroundStyle(isOn ? c(ApprovedColor.onInk) : c(ApprovedColor.inkSecondary))
            .padding(.horizontal, 13)
            .frame(height: 38)
            .background(Capsule().fill(isOn ? c(ApprovedColor.segmentSelected) : .clear))
            .overlay { if !isOn { Capsule().strokeBorder(c(ApprovedColor.hairline), lineWidth: 1) } }
            .contentShape(Capsule())
        }
        .buttonStyle(UndimmedButtonStyle())
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// `seg`: 4 pt padding on a chip-filled 22 pt capsule, 4 pt gaps; 36 pt segments; selected = ink fill, on-ink text, bold.
struct L2Segmented<Value: Hashable>: View {
    let options: [(value: Value, label: Text, icon: ApprovedIcon?, identifier: String)]
    let selection: Value
    var accessibilityLabel: Text = Text("")
    let onSelect: (Value) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = L2(scheme: scheme)
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isOn = option.value == selection
                Button { onSelect(option.value) } label: {
                    HStack(spacing: 6) {
                        if let icon = option.icon { ApprovedIconView(icon: icon, size: 16) }
                        option.label.l2Text(14, weight: isOn ? .bold : .semibold).lineLimit(1)
                    }
                    .foregroundStyle(isOn ? c(ApprovedColor.onInk) : c(ApprovedColor.inkSecondary))
                    .frame(maxWidth: .infinity).frame(height: 36)
                    .background(Capsule().fill(isOn ? c(ApprovedColor.segmentSelected) : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(UndimmedButtonStyle())
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier(option.identifier)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(c(ApprovedColor.chip)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// `tabs`: a scrolling row, 20 pt gaps, 14.5 pt; selected bold ink (with the 2 pt orange underline in Develop),
/// others medium ink3; a 5 pt orange dot on tabs holding an edit; the right edge fades (88 %).
struct L2Tabs<Value: Hashable>: View {
    struct Item { let value: Value; let title: Text; var icon: ApprovedIcon?; var dot = false; let identifier: String }
    let items: [Item]
    let selection: Value
    var underline = false
    let onSelect: (Value) -> Void
    @Environment(\.colorScheme) private var scheme
    /// True while some tabs are hidden past the trailing edge: only then does the end fade (owner amendment
    /// 2026-10-10: a fade on tabs that all fit read as "there is more to scroll").
    @State private var hidesMore = false

    var body: some View {
        let c = L2(scheme: scheme)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(items.indices, id: \.self) { index in
                        let item = items[index]
                        let isOn = item.value == selection
                        Button { onSelect(item.value) } label: {
                            HStack(spacing: 5) {
                                if let icon = item.icon { ApprovedIconView(icon: icon, size: 14) }
                                item.title.l2Text(14.5, weight: isOn ? .bold : .medium).lineLimit(1).fixedSize()
                                if item.dot { Circle().fill(c(ApprovedColor.edited)).frame(width: 5, height: 5) }
                            }
                            .foregroundStyle(isOn ? c(ApprovedColor.ink) : c(ApprovedColor.inkTertiary))
                            .padding(.top, 8).padding(.bottom, 7)
                            .overlay(alignment: .bottom) {
                                if isOn && underline { Rectangle().fill(c(ApprovedColor.browse)).frame(height: 2) }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(UndimmedButtonStyle())
                        .id(index)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                        .accessibilityValue(Text(item.dot ? "Edited" : ""))
                        .accessibilityIdentifier(item.identifier)
                    }
                }
                .reportsTrailingEdge(in: "l2tabs")
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .modifier(TrailingOverflowReader(space: "l2tabs", hidesMore: $hidesMore))
            .mask(LinearGradient(stops: [.init(color: .black, location: hidesMore ? 0.88 : 1), .init(color: hidesMore ? .clear : .black, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            // `scrolled()`: the item before the selected one sits at the leading edge.
            .onChange(of: selection, initial: true) { _, value in
                guard let at = items.firstIndex(where: { $0.value == value }) else { return }
                proxy.scrollTo(max(0, at - 1), anchor: .leading)
            }
        }
    }
}

/// The trailing edge of a horizontal scroll view's content, in the scroll view's own coordinate space.
private struct TrailingContentEdge: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// On a horizontal scroll view's content: reports where the content ends (as the scroll view moves it).
    func reportsTrailingEdge(in space: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: TrailingContentEdge.self, value: proxy.frame(in: .named(space)).maxX)
        })
    }
}

/// On the horizontal scroll view: `hidesMore` is true while its content runs past the trailing edge. Layout
/// preferences report the first layout too (iOS 17 has no scroll-geometry reader, and that reader skips it).
struct TrailingOverflowReader: ViewModifier {
    let space: String
    @Binding var hidesMore: Bool
    @State private var contentEdge: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: space)
            .background(GeometryReader { proxy in
                Color.clear.onAppear { viewportWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in viewportWidth = width }
            })
            .onPreferenceChange(TrailingContentEdge.self) { edge in contentEdge = edge }
            .onChange(of: contentEdge > viewportWidth + 1, initial: true) { _, more in hidesMore = more }
            .onChange(of: viewportWidth) { _, width in hidesMore = contentEdge > width + 1 }
    }
}

// MARK: - Slider

/// `slider`: label (92 pt, 13 pt semibold ink2), 3 pt track (`--off`), accent fill (from the centre for bipolar
/// ranges, with a 2×12 centre mark), a 22 pt knob with a soft shadow, the value (34 pt, 13 pt bold, "+" when positive).
struct L2Slider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var isEnabled = true
    let onChange: (Double) -> Void
    let onEnd: (Double) -> Void
    @State private var tracking: Double?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = L2(scheme: scheme)
        let v = tracking ?? value
        let span = range.upperBound - range.lowerBound
        let fraction = span > 0 ? (v - range.lowerBound) / span : 0
        let bipolar = range.lowerBound < 0
        HStack(spacing: 12) {
            Text(LocalizedStringKey(label)).l2Text(13, weight: .semibold).foregroundStyle(c(ApprovedColor.inkSecondary))
                .lineLimit(1).frame(width: 92, alignment: .leading)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(c(ApprovedColor.track)).frame(height: 3)
                    if bipolar {
                        RoundedRectangle(cornerRadius: 1).fill(c(ApprovedColor.inkTertiary)).frame(width: 2, height: 12)
                            .offset(x: width / 2 - 1)
                        let from = min(0.5, fraction), to = max(0.5, fraction)
                        Capsule().fill(c(ApprovedColor.selection)).frame(width: width * (to - from), height: 3).offset(x: width * from)
                    } else {
                        Capsule().fill(c(ApprovedColor.selection)).frame(width: width * fraction, height: 3)
                    }
                    Circle().fill(c(ApprovedColor.knob)).frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: width * fraction - 11)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        let next = (range.lowerBound + min(max(gesture.location.x / max(width, 1), 0), 1) * span).rounded()
                        if tracking != next { tracking = next; onChange(next) }
                    }
                    .onEnded { gesture in
                        guard isEnabled else { return }
                        onEnd((range.lowerBound + min(max(gesture.location.x / max(width, 1), 0), 1) * span).rounded())
                        tracking = nil
                    })
            }
            .frame(height: 22)
            Text(verbatim: (bipolar && v > 0 ? "+" : "") + "\(Int(v.rounded()))")
                .l2Text(13, weight: .bold).monospacedDigit()
                .foregroundStyle(c(ApprovedColor.ink))
                .frame(width: 34, alignment: .trailing)
        }
        .frame(minHeight: 38)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(label)))
        .accessibilityValue(Text("\(Int(v.rounded()))"))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            onEnd(min(max(v + (direction == .increment ? 5 : -5), range.lowerBound), range.upperBound))
        }
        .accessibilityIdentifier("slider.\(label.lowercased())")
    }
}

// MARK: - Text blocks

/// `note`: 12.5 pt ink2, line height 1.4.
struct L2Note: View {
    let text: Text
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        text.l2Text(12.5, lineHeight: 1.4).foregroundStyle(L2(scheme: scheme)(ApprovedColor.inkSecondary))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `notice`: 18 pt icon (accent, or danger for warnings), 13 pt text with a bold lead, quiet actions; 12/14 padding,
/// 18 pt corners, card fill, hairline border.
struct L2Notice: View {
    let icon: ApprovedIcon
    var bold: String?
    let text: String
    var actions: [(title: String, identifier: String, action: () -> Void)] = []
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = L2(scheme: scheme)
        HStack(alignment: .top, spacing: 10) {
            ApprovedIconView(icon: icon, size: 18)
                .foregroundStyle(icon == .warn ? c(ApprovedColor.danger) : c(ApprovedColor.selection))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 10) {
                (Text(LocalizedStringKey(bold ?? "")).fontWeight(.bold) + Text(LocalizedStringKey(text)))
                    .l2Text(13, lineHeight: 1.4)
                    .foregroundStyle(c(ApprovedColor.ink))
                    .fixedSize(horizontal: false, vertical: true)
                if !actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(actions.indices, id: \.self) { index in
                            Button(LocalizedStringKey(actions[index].title), action: actions[index].action)
                                .buttonStyle(L2QuietButtonStyle())
                                .accessibilityIdentifier(actions[index].identifier)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(c(ApprovedColor.backgroundSecondary)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(c(ApprovedColor.hairline), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel.notice")
    }
}

/// `resetRow`: the section title (14 pt bold) and, when there is something to reset, "Reset" (linkBtn with the reset icon).
struct L2ResetRow: View {
    let title: String
    let canReset: Bool
    var identifier = "panel.reset"
    let onReset: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack {
            Text(LocalizedStringKey(title)).l2Text(14, weight: .bold).foregroundStyle(L2(scheme: scheme)(ApprovedColor.ink))
            Spacer(minLength: 8)
            if canReset {
                Button(action: onReset) { L2Label(title: Text("Reset"), icon: .reset, iconSize: 15) }
                    .buttonStyle(L2LinkButtonStyle())
                    .accessibilityLabel(Text("Reset \(title.lowercased())"))
                    .accessibilityIdentifier(identifier)
            }
        }
        .frame(minHeight: 34)
    }
}

// MARK: - Switch

/// `toggle`: a 50×30 track (accent when on, `--off` when off) with a 26 pt knob.
struct L2SwitchStyle: ToggleStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let c = L2(scheme: scheme)
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                Capsule()
                    .fill(configuration.isOn ? c(ApprovedColor.accent) : c(ApprovedColor.track))
                    .frame(width: 50, height: 30)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(c(ApprovedColor.knob)).frame(width: 26, height: 26)
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1).padding(2)
                    }
                    .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: configuration.isOn)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// `toggleRow`'s label: 14 pt semibold title, 12 pt ink2 sub-line.
struct L2ToggleLabel: View {
    let title: String
    var subtitle: String?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let c = L2(scheme: scheme)
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title)).l2Text(14, weight: .semibold).foregroundStyle(c(ApprovedColor.ink))
            if let subtitle {
                Text(LocalizedStringKey(subtitle)).l2Text(12).foregroundStyle(c(ApprovedColor.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Lists and cards

/// `card`: 22 pt corners, surface fill, hairline border.
struct L2Card<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets()
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let c = L2(scheme: scheme)
        VStack(spacing: 0) { content() }
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(c(ApprovedColor.surface)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(c(ApprovedColor.hairline), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// `listRow`: 54 pt minimum, 8/16 padding, 12 pt gap; 15 pt semibold title, 12 pt ink2 sub-line; trailing ink3;
/// a hairline above every row but the first.
struct L2ListRow<Trailing: View>: View {
    let title: Text
    var subtitle: Text?
    var isFirst = false
    var titleColour: ApprovedColor.Token = ApprovedColor.ink
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = L2(scheme: scheme)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                title.l2Text(15, weight: .semibold).foregroundStyle(c(titleColour))
                if let subtitle { subtitle.l2Text(12).foregroundStyle(c(ApprovedColor.inkSecondary)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) { trailing() }
                .l2Text(14)
                .foregroundStyle(c(ApprovedColor.inkTertiary))
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(minHeight: 54)
        .overlay(alignment: .top) { if !isFirst { Rectangle().fill(c(ApprovedColor.hairline)).frame(height: 1) } }
        .contentShape(Rectangle())
    }
}

/// `groupLabel`: 11 pt bold, 0.8 pt tracking, ink2, upper case, 6 pt side and 7 pt bottom padding.
struct L2GroupLabel: View {
    let text: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Text(LocalizedStringKey(text)).textCase(.uppercase)
            .l2Text(11, weight: .bold, tracking: 0.8)
            .foregroundStyle(L2(scheme: scheme)(ApprovedColor.inkSecondary))
            .padding(.horizontal, 6).padding(.bottom, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Action sheet and alert

/// `actionSheet` (iOS): over the scrim, a card (18 pt corners, sheet fill) with the title (13 pt semibold ink2, 14 pt
/// padding) and the options (54 pt rows, hairline above each, 17 pt danger), then a separate 56 pt Cancel card
/// (17 pt bold accent), 8 pt apart. Phones: 8 pt from the sides, at the bottom; wider screens: 320 pt, centred.
struct L2ActionSheet: View {
    let title: String
    let options: [(title: String, identifier: String, action: () -> Void)]
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let c = L2(scheme: scheme)
        let wide = sizeClass == .regular
        ZStack(alignment: wide ? .center : .bottom) {
            ApprovedColor.scrim(scheme).ignoresSafeArea().onTapGesture(perform: onCancel).accessibilityHidden(true)
            VStack(spacing: 8) {
                VStack(spacing: 0) {
                    Text(LocalizedStringKey(title)).l2Text(13, weight: .semibold).foregroundStyle(c(ApprovedColor.inkSecondary))
                        .padding(14).frame(maxWidth: .infinity)
                    ForEach(options.indices, id: \.self) { index in
                        Button(action: options[index].action) {
                            Text(LocalizedStringKey(options[index].title)).l2Text(17).foregroundStyle(c(ApprovedColor.danger))
                                .frame(maxWidth: .infinity, minHeight: 54).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .top) { Rectangle().fill(c(ApprovedColor.hairline)).frame(height: 1) }
                        .accessibilityIdentifier(options[index].identifier)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(c(ApprovedColor.sheet)))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button(action: onCancel) {
                    Text("Cancel").l2Text(17, weight: .bold).foregroundStyle(c(ApprovedColor.selection))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(c(ApprovedColor.sheet)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("actionsheet.cancel")
            }
            .frame(maxWidth: wide ? 320 : .infinity)
            .padding(.horizontal, wide ? 0 : 8)
            .accessibilityAddTraits(.isModal)
        }
        .accessibilityAction(.escape, onCancel)
    }
}

/// `dialog` (iOS): over the scrim, a 290 pt card (22 pt corners, sheet fill, hairline, shadow 0 24 60 at 40 %): the
/// title (16 pt bold) and message (13 pt ink2, line height 1.4) centred with 20/18/16 padding and 6 pt between, then
/// one 48 pt button per row, hairline above: 16 pt; the preferred one bold accent, destructive ones danger, others ink.
struct L2Alert: View {
    enum Role { case preferred, destructive, normal }
    let title: String
    var message: String?
    let buttons: [(title: String, role: Role, identifier: String, action: () -> Void)]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = L2(scheme: scheme)
        ZStack {
            ApprovedColor.scrim(scheme).ignoresSafeArea().accessibilityHidden(true)
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text(LocalizedStringKey(title)).l2Text(16, weight: .bold).foregroundStyle(c(ApprovedColor.ink))
                        .accessibilityAddTraits(.isHeader)
                    if let message {
                        Text(LocalizedStringKey(message)).l2Text(13, lineHeight: 1.4).foregroundStyle(c(ApprovedColor.inkSecondary))
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 16)
                ForEach(buttons.indices, id: \.self) { index in
                    let button = buttons[index]
                    Button(action: button.action) {
                        Text(LocalizedStringKey(button.title))
                            .l2Text(16, weight: button.role == .preferred ? .bold : .medium)
                            .foregroundStyle(button.role == .destructive ? c(ApprovedColor.danger)
                                             : button.role == .preferred ? c(ApprovedColor.selection) : c(ApprovedColor.ink))
                            .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .top) { Rectangle().fill(c(ApprovedColor.hairline)).frame(height: 1) }
                    .accessibilityIdentifier(button.identifier)
                }
            }
            .frame(width: 290)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(c(ApprovedColor.sheet)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(c(ApprovedColor.hairline), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 30, y: 24)
            .accessibilityAddTraits(.isModal)
            .accessibilityElement(children: .contain)
        }
    }
}
