import SwiftUI

/// How the Develop panel lays out its categories (approved `developPanel`).
enum DevelopPanelStyle: Equatable {
    /// Phones: one scrolling row of category tabs beside Auto.
    case tabs
    /// Tablet portrait (`.wrapped`): the tabs wrap onto several rows beside Auto.
    case wrappedTabs
    /// Tablet landscape side panel (`roomy`): the "Develop" title, Auto, then a category list.
    case list
}

/// The approved Develop panel: Auto, categories with counts and the applied-category dot, the
/// notices, the name row (star, name, position, Amount), the context line and the ruler — or the
/// Amount slider with Done.
struct DevelopPanelView: View {
    @Bindable var model: DevelopPanelModel
    let style: DevelopPanelStyle

    @Environment(\.colorScheme) private var colorScheme

    private func c(_ token: ApprovedColor.Token) -> Color { token.resolved(colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if style == .list {
                Text("Develop")
                    .approvedText(13, weight: .semibold)
                    .foregroundStyle(c(ApprovedColor.inkSecondary))
                    .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            header
            if style == .list { categoryList }
            notice
            nameRow
            contextLine
            if model.isAmountOpen, model.namedPreset != nil {
                amountRow
            } else {
                StopRuler(model: model)
            }
        }
    }

    // MARK: Auto and categories

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch style {
            case .tabs:
                CategoryTabStrip(model: model)
            case .wrappedTabs:
                FlowLayout(spacing: 20) {
                    ForEach(model.categoryItems) { item in categoryTab(item) }
                }
                .padding(.leading, 14).padding(.trailing, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .list:
                EmptyView()
            }
        }
        .frame(minHeight: 44)
    }

    func categoryTab(_ item: DevelopPanelModel.CategoryItem) -> some View {
        CategoryTab(model: model, item: item)
    }

    /// The side panel's `.catlist`.
    private var categoryList: some View {
        VStack(spacing: 0) {
            ForEach(model.categoryItems) { item in
                let isOn = item.id == model.currentCategoryID
                Button {
                    model.selectCategory(item.id)
                } label: {
                    HStack(spacing: 0) {
                        if item.isFavourites { ApprovedIconView(icon: .star, size: 15) }
                        Text(item.name).approvedText(15, weight: isOn ? .semibold : .regular)
                            .overlay(alignment: .bottom) { BrowsedUnderline(isOn: isOn).offset(y: 6) }
                        if item.holdsAppliedPreset { AppliedDot().padding(.leading, 6) }
                        Spacer(minLength: 8)
                    }
                    .foregroundStyle(isOn ? c(ApprovedColor.ink) : c(ApprovedColor.inkSecondary))
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(isOn ? RoundedRectangle(cornerRadius: 8).fill(c(ApprovedColor.backgroundSecondary)) : nil)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.name))
                .accessibilityValue(Text(item.holdsAppliedPreset ? "Contains the applied preset" : ""))
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("develop.category.\(item.id)")
            }
        }
        .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 4)
    }

    // MARK: Notices

    @ViewBuilder
    private var notice: some View {
        if model.isFavouritesFullNoticeShown {
            DevelopNotice(icon: .star, bold: "Favourites holds five presets.", text: " Remove one in Preferences, or replace one now.",
                          actions: [("Replace…", "develop.favourites.replace", { model.isReplaceSheetShown = true }),
                                    ("Not now", "develop.favourites.notNow", { model.dismissFavouritesFullNotice() })])
        } else if model.session.autoState == .failed {
            DevelopNotice(icon: .warn, bold: "Automatic correction didn't finish.", text: " Your photo is unchanged and presets still work.",
                          actions: [("Retry", "develop.auto.retry", { model.session.retryAuto() }),
                                    ("Continue with original", "develop.auto.original", { model.session.continueWithOriginal() })])
        }
        // Unavailable Auto: no standing notice (owner amendment 2026-10-05); tapping Auto explains it (EditorSession.toggleAuto).
    }

    // MARK: Name row

    private var nameRow: some View {
        let preset = model.namedPreset
        return HStack(spacing: 4) {
            Button { model.toggleStar() } label: {
                ApprovedIconView(icon: .star, size: 20, filled: model.isPresetAtStopFavourite)
                    .foregroundStyle(model.isPresetAtStopFavourite ? c(ApprovedColor.selection) : c(ApprovedColor.inkTertiary))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(preset == nil ? 0 : 1)
            .disabled(preset == nil)
            .accessibilityHidden(preset == nil)
            .accessibilityLabel(Text("Favourite"))
            .accessibilityAddTraits(model.isPresetAtStopFavourite ? .isSelected : [])
            .accessibilityIdentifier("develop.star")

            // The reference's line breaks (M4): SwiftUI `Text` pushed "Winter" down so the name did not end on one
            // word ("Landscape 15 - / Winter Wonderland" where the approved screen has "Landscape 15 - Winter /
            // Wonderland"); ApprovedParagraph breaks at the last word that fits, as the notes do (858a06f).
            ApprovedParagraph(text: model.displayedName, pointSize: 17, weight: .semibold, colour: c(ApprovedColor.ink),
                              trackingEm: -0.01, naturalLineHeight: true, identifier: "develop.name")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(model.positionText)
                .approvedText(13)
                .monospacedDigit()
                .foregroundStyle(c(ApprovedColor.inkTertiary))
                .fixedSize()
                .accessibilityIdentifier("develop.position")

            Button { model.openAmount() } label: {
                Text(model.amountButtonTitle)
                    .approvedText(14, weight: .medium)
                    .foregroundStyle(c(ApprovedColor.selection))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(preset == nil ? 0 : 1)
            .disabled(preset == nil)
            .accessibilityHidden(preset == nil)
            .accessibilityIdentifier("develop.amount")
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.top, 2)
        .frame(minHeight: 44)
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var contextLine: some View {
        Text(model.contextLine ?? "")
            .approvedText(12.5)
            .foregroundStyle(c(ApprovedColor.inkTertiary))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            .accessibilityHidden(model.contextLine == nil)
            .accessibilityIdentifier("develop.context")
    }

    // MARK: Amount

    private var amountRow: some View {
        // The prototype's row is `display:flex` around the `.sl` grid, which is not stretched: its
        // `minmax(90px, 1fr)` track resolves to 90 pt, and Done follows straight after the value.
        HStack(spacing: 0) {
            ApprovedSlider(label: "Amount", value: model.amountValue, range: 0...100, fixedTrackWidth: 90,
                           onChange: { model.amountChanged($0) }, onEnd: { model.amountEnded($0) })
                .fixedSize(horizontal: true, vertical: false)
            Button("Done") { model.closeAmount() }
                .buttonStyle(ApprovedSmallQuietButtonStyle())
                .accessibilityIdentifier("develop.amount.done")
            Spacer(minLength: 0)
        }
    }
}

/// `.notice`: icon, text with an optional bold lead, and quiet small actions.
struct DevelopNotice: View {
    let icon: ApprovedIcon
    let bold: String?
    let text: String
    let actions: [(title: String, identifier: String, action: () -> Void)]

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ApprovedIconView(icon: icon, size: 18)
                .foregroundStyle(ApprovedColor.inkSecondary.resolved(colorScheme))
            VStack(alignment: .leading, spacing: 0) {
                (Text(bold ?? "").fontWeight(.semibold).foregroundColor(ApprovedColor.ink.resolved(colorScheme))
                    + Text(text).foregroundColor(ApprovedColor.inkSecondary.resolved(colorScheme)))
                    .approvedText(13.5)
                    .fixedSize(horizontal: false, vertical: true)
                if !actions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(actions.indices, id: \.self) { index in
                            Button(actions[index].title, action: actions[index].action)
                                .buttonStyle(ApprovedSmallQuietButtonStyle())
                                .accessibilityIdentifier(actions[index].identifier)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.leading, -12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(ApprovedColor.backgroundSecondary.resolved(colorScheme)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ApprovedColor.hairline.resolved(colorScheme), lineWidth: 1))
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("develop.notice")
    }
}

/// `.btn.quiet.small`: 44 pt high, 12 pt padding, 14.5 pt semibold in the selection colour.
struct ApprovedSmallQuietButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .approvedText(14.5, weight: .semibold)
            .foregroundStyle(ApprovedColor.selection.resolved(colorScheme))
            // One line at the approved sizes; at accessibility sizes the title wraps instead of running off the panel
            // ("Remove background change" at AX5, A11 2026-10-07).
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// `.sl`: label, track (3 pt, ink fill, 18 pt knob) and the value, in a 44 pt row.
struct ApprovedSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    /// A fixed track width (the Amount row); nil stretches the track (`minmax(90px, 1fr)`).
    var fixedTrackWidth: CGFloat?
    let onChange: (Double) -> Void
    let onEnd: (Double) -> Void

    @State private var trackingValue: Double?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let value = trackingValue ?? self.value
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        HStack(spacing: 12) {
            Text(label).approvedText(15).foregroundStyle(ApprovedColor.ink.resolved(colorScheme)).lineLimit(1).fixedSize()
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(ApprovedColor.track.resolved(colorScheme)).frame(height: 3)
                    Capsule().fill(ApprovedColor.ink.resolved(colorScheme)).frame(width: width * fraction, height: 3)
                    Circle()
                        .fill(colorScheme == .dark ? ApprovedColor.ink.resolved(colorScheme) : ApprovedColor.background.resolved(colorScheme))
                        // `.trk b` border: 1 pt as rendered (the approved references floor CSS border widths (Chromium computes 1.5px as 1px, 2.5px as 2px)).
                        .overlay(Circle().strokeBorder(ApprovedColor.ink.resolved(colorScheme), lineWidth: 1))
                        .frame(width: 18, height: 18)
                        .offset(x: width * fraction - 9)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle().inset(by: -20))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let next = range.lowerBound + min(max(Double(gesture.location.x / max(width, 1)), 0), 1) * (range.upperBound - range.lowerBound)
                        let previous = trackingValue
                        trackingValue = next
                        if previous?.rounded() != next.rounded() { onChange(next.rounded()) }
                    }
                    .onEnded { gesture in
                        onEnd(ApprovedSlider.value(at: gesture.location.x, width: width, range: range))
                        trackingValue = nil
                    })
            }
            .frame(minWidth: 90, idealWidth: fixedTrackWidth ?? 90, maxWidth: fixedTrackWidth ?? .infinity)
            Text("\(Int(value.rounded()))")
                .approvedText(13).monospacedDigit()
                .foregroundStyle(ApprovedColor.inkTertiary.resolved(colorScheme))
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text("\(Int(value.rounded()))"))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 5.0 : -5.0
            onEnd(min(max(value + step, range.lowerBound), range.upperBound))
        }
        .accessibilityIdentifier("slider.\(label.lowercased())")
    }

    static func value(at x: CGFloat, width: CGFloat, range: ClosedRange<Double>) -> Double {
        let fraction = min(max(Double(x / max(width, 1)), 0), 1)
        return (range.lowerBound + fraction * (range.upperBound - range.lowerBound)).rounded()
    }
}

/// Leading-aligned wrapping rows (CSS `flex-wrap: wrap; row-gap: 0`).
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height }
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// One `.tabs` item: label and count, the selected one bold, the applied one dotted. Its own view so
/// it reads the colour scheme where it is shown (the phone strip builds tabs outside the panel).
struct CategoryTab: View {
    let model: DevelopPanelModel
    let item: DevelopPanelModel.CategoryItem
    @Environment(\.colorScheme) private var colorScheme

    private func c(_ token: ApprovedColor.Token) -> Color { token.resolved(colorScheme) }

    var body: some View {
        let isOn = item.id == model.currentCategoryID
        Button {
            model.selectCategory(item.id)
        } label: {
            HStack(spacing: 4) {
                if item.isFavourites { ApprovedIconView(icon: .star, size: 15) }
                Text(item.name).approvedText(15, weight: isOn ? .semibold : .regular)
                    .overlay(alignment: .bottom) { BrowsedUnderline(isOn: isOn).offset(y: 6) }
                if item.holdsAppliedPreset { AppliedDot().padding(.leading, 3) }
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isOn ? c(ApprovedColor.ink) : c(ApprovedColor.inkSecondary))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(item.name))
        .accessibilityValue(Text(item.holdsAppliedPreset ? "Contains the applied preset" : ""))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("develop.category.\(item.id)")
    }
}

/// The browsed category: a 2 pt orange underline under its name (owner amendment 2026-10-05). A shape, not only a
/// colour, so browsing and "applied" (the dot) differ without relying on colour.
struct BrowsedUnderline: View {
    let isOn: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule()
            .fill(ApprovedColor.browse.resolved(colorScheme))
            .frame(height: 2)
            .opacity(isOn ? 1 : 0)
            .accessibilityHidden(true)
    }
}

/// The category holding the applied preset: a 5 pt dot in the selection colour (approved `.tabs .dot`).
struct AppliedDot: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Circle().fill(ApprovedColor.edited.resolved(colorScheme)).frame(width: 5, height: 5).accessibilityHidden(true)
    }
}
