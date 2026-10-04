import SwiftUI

/// Controls of the approved design (`docs/ui/app/styles.css`): flat buttons, list rows, the
/// segmented control and the switch. Sizes are the prototype's; every target is at least 44 pt.
enum ApprovedMetrics {
    static let minimumTarget: CGFloat = 44
    /// `.listrow`.
    static let rowMinimumHeight: CGFloat = 52
    static let rowHorizontalPadding: CGFloat = 18
    /// `.page .head`, `.topbar`.
    static let headerHeight: CGFloat = 48
    static let headerHorizontalPadding: CGFloat = 6
}

// MARK: - Buttons

/// `.btn` with `.primary`, `.line` or `.quiet`.
struct ApprovedButtonStyle: ButtonStyle {
    enum Kind { case primary, line, quiet }

    let kind: Kind
    /// Welcome's larger buttons (`.welcome .actions .btn`: 52 pt, 16 pt text, radius 12).
    var isLarge = false
    var fillsWidth = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = isLarge ? 12 : 10
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .approvedText(isLarge ? 16 : 15, weight: .semibold)
            .multilineTextAlignment(.center)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .quiet ? 12 : 18)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: isLarge ? 52 : ApprovedMetrics.minimumTarget)
            .background {
                if kind == .primary { shape.fill(ApprovedColor.ink.resolved(colorScheme)) }
            }
            .overlay {
                if kind == .line { shape.strokeBorder(ApprovedColor.hairline.resolved(colorScheme), lineWidth: 1) }
            }
            .contentShape(shape)
            // Native press feedback; the prototype has no pressed state to match.
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.4))
    }

    private var foreground: Color {
        switch kind {
        case .primary: ApprovedColor.background.resolved(colorScheme)
        case .line: ApprovedColor.ink.resolved(colorScheme)
        case .quiet: ApprovedColor.selection.resolved(colorScheme)
        }
    }
}

/// A 44 pt square icon button (`.ib`).
struct ApprovedIconButton: View {
    let icon: ApprovedIcon
    /// The drawn icon; the target stays 44 pt.
    var iconSize: CGFloat = 22
    let accessibilityLabel: Text
    var identifier: String?
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            ApprovedIconView(icon: icon, size: iconSize)
                .foregroundStyle(ApprovedColor.ink.resolved(colorScheme))
                .frame(width: ApprovedMetrics.minimumTarget, height: ApprovedMetrics.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier ?? "")
    }
}

// MARK: - Page structure

/// `.page .head`: a 44 pt leading button and the title centred on the whole width.
struct ApprovedPageHeader: View {
    enum Leading { case close, back }

    let title: Text
    let leading: Leading
    /// Identifies the page for UI tests. On the title, not the page container: an identifier on
    /// a container is pushed down onto children and replaces their own (the Back button's).
    var titleIdentifier: String?
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ApprovedIconButton(
                icon: leading == .close ? .close : .back,
                accessibilityLabel: leading == .close ? Text("common.close", bundle: .main) : Text("common.back", bundle: .main),
                identifier: leading == .close ? "page.close" : "page.back",
                action: action
            )
            title
                .approvedText(17, weight: .semibold)
                .foregroundStyle(ApprovedColor.ink.resolved(colorScheme))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(titleIdentifier ?? "")
            // Balances the leading button so the title is centred on the page (CSS margin-right 44).
            Color.clear.frame(width: ApprovedMetrics.minimumTarget, height: 1)
        }
        .padding(.horizontal, ApprovedMetrics.headerHorizontalPadding)
        .frame(minHeight: ApprovedMetrics.headerHeight)
    }
}

/// `.group`: an uppercase section label.
struct ApprovedGroupLabel: View {
    let text: Text
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        text
            .textCase(.uppercase)
            .approvedText(12.5, trackingEm: 0.04)
            .foregroundStyle(ApprovedColor.inkTertiary.resolved(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ApprovedMetrics.rowHorizontalPadding)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// `.note`: secondary explanatory text, with the reference's line breaks (`ApprovedParagraph`).
struct ApprovedNote: View {
    let text: String
    var topPadding: CGFloat = 6
    /// `.note` pads 6 below; captions above a swatch row use `padding-bottom:0`.
    var bottomPadding: CGFloat = 6
    @Environment(\.colorScheme) private var colorScheme

    /// `text` is a key or English source string in Localizable.xcstrings, as `Text("…")` was.
    init(_ text: String.LocalizationValue, topPadding: CGFloat = 6, bottomPadding: CGFloat = 6) {
        self.init(verbatim: String(localized: text), topPadding: topPadding, bottomPadding: bottomPadding)
    }

    /// Already-localised text, for notes put together from several strings.
    init(verbatim text: String, topPadding: CGFloat = 6, bottomPadding: CGFloat = 6) {
        self.text = text
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
    }

    var body: some View {
        ApprovedParagraph(text: text, pointSize: 13, colour: ApprovedColor.inkTertiary.resolved(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ApprovedMetrics.rowHorizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
    }
}

/// `.listrow`: label, optional sub-line, trailing content, a hairline below.
struct ApprovedListRow<Trailing: View>: View {
    let title: Text
    var subtitle: Text?
    var titleColor: ApprovedColor.Token = ApprovedColor.ink
    var verticalPadding: CGFloat = 0
    @ViewBuilder let trailing: () -> Trailing

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                title
                    .approvedText(15)
                    .foregroundStyle(titleColor.resolved(colorScheme))
                if let subtitle {
                    subtitle
                        .approvedText(13)
                        .foregroundStyle(ApprovedColor.inkTertiary.resolved(colorScheme))
                }
            }
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing()
                .foregroundStyle(ApprovedColor.inkTertiary.resolved(colorScheme))
        }
        .padding(.horizontal, ApprovedMetrics.rowHorizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(maxWidth: .infinity, minHeight: ApprovedMetrics.rowMinimumHeight, alignment: .leading)
        .overlay(alignment: .bottom) { ApprovedHairline() }
        .contentShape(Rectangle())
    }
}

extension ApprovedListRow where Trailing == ApprovedChevron {
    /// A navigation row: the trailing chevron.
    init(title: Text, subtitle: Text? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { ApprovedChevron() })
    }
}

struct ApprovedChevron: View {
    var body: some View { ApprovedIconView(icon: .chevron, size: 18) }
}

struct ApprovedHairline: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Rectangle()
            .fill(ApprovedColor.hairline.resolved(colorScheme))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Switch

/// `.toggle`: a 46×28 track with a 22 pt knob, selection colour when on. Keeps the native
/// toggle's accessibility (switch trait, value, double-tap to change).
struct ApprovedSwitchToggleStyle: ToggleStyle {
    @Environment(\.colorScheme) private var colorScheme
    /// Reduce Motion: the knob moves without sliding.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 0)
                Capsule()
                    .fill((configuration.isOn ? ApprovedColor.selection : ApprovedColor.track).resolved(colorScheme))
                    .frame(width: 46, height: 28)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 22, height: 22)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                            .padding(3)
                    }
                    .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: configuration.isOn)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

// MARK: - Segmented control

/// `.seg`: equal segments on the secondary background; the selected one raised.
struct ApprovedSegmentedControl<Value: Hashable>: View {
    let accessibilityLabel: Text
    let options: [(value: Value, label: Text, identifier: String)]
    @Binding var selection: Value

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    option.label
                        .approvedText(14, weight: .medium)
                        .foregroundStyle((isSelected ? ApprovedColor.ink : ApprovedColor.inkSecondary).resolved(colorScheme))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: ApprovedMetrics.minimumTarget)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(ApprovedColor.segmentSelected.resolved(colorScheme))
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier(option.identifier)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ApprovedColor.backgroundSecondary.resolved(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(ApprovedColor.hairline.resolved(colorScheme), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Scrolling screens

/// Content that fills the screen when it fits and scrolls when it does not (large text), so
/// flexible spacers can push content apart without ever clipping it.
struct FillingScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                // The ideal height replaces the scroll view's unspecified height proposal, so the
                // content is offered the full screen and its spacers fill it; taller content
                // keeps its own height and scrolls.
                content()
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, idealHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
