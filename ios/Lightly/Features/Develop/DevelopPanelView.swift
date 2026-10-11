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

/// The Lightly 2 Develop panel (`developPanel` in docs/ui/directions/lightly-2-concept/index.html), 6 pt between rows:
/// the grab handle (phones, compact), the category tabs (orange underline on the browsed one, orange dot on the one
/// holding the applied preset, Favourites with its star), a notice when one applies, the heading (star, the preset's
/// name, Reset), the preset gallery and Amount. On landscape iPad (`.list`) the categories are a list above the rest.
struct DevelopPanelView: View {
    @Bindable var model: DevelopPanelModel
    let style: DevelopPanelStyle
    var expanded = false

    @Environment(\.colorScheme) private var colorScheme

    private func c(_ token: ApprovedColor.Token) -> Color { token.resolved(colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if style == .list {
                categoryList
                Rectangle().fill(c(ApprovedColor.hairline)).frame(height: 1).padding(.vertical, 4)
            } else {
                if !expanded {
                    // `handle`: 36×4, 6 pt tall row pulled 6 pt up; dragging it (or the gallery) up expands the presets.
                    Capsule().fill(c(ApprovedColor.track)).frame(width: 36, height: 4)
                        .frame(maxWidth: .infinity).frame(height: 6).padding(.top, -6)
                        .frame(minHeight: 20).contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            if value.translation.height < -24 && abs(value.translation.height) > abs(value.translation.width) {
                                withAnimation(.snappy(duration: 0.25)) { model.isExpanded = true }
                            }
                        })
                        .padding(.vertical, -7)
                        .accessibilityLabel("Preset browser")
                        .accessibilityAction(named: "Expand presets") { model.isExpanded = true }
                }
                L2Tabs(items: model.categoryItems.map { item in
                    .init(value: item.id, title: Text(item.name), icon: item.isFavourites ? .star : nil,
                          dot: item.holdsAppliedPreset, identifier: "develop.category.\(item.id)")
                }, selection: model.currentCategoryID, underline: true, onSelect: model.selectCategory)
            }
            notice
            heading
            PresetGallery(model: model, expanded: expanded || style == .list)
            L2Slider(label: "Amount", value: model.amountValue, range: 0...100, isEnabled: model.session.recipe.look != nil,
                     onChange: model.amountChanged, onEnd: model.amountEnded)
        }
    }

    /// `heading`: the star (30×36, 20 pt; accent when the preset is a favourite, ink3 otherwise, faint without a
    /// preset), the name (17 pt heading, one line), and "Reset" when a preset is applied. 8 pt gaps, 36 pt tall.
    private var heading: some View {
        let starred = model.isPresetAtStopFavourite
        let preset = model.namedPreset
        return HStack(spacing: 8) {
            Button { model.toggleStar() } label: {
                ApprovedIconView(icon: .star, size: 20, filled: starred)
                    .foregroundStyle(starred ? c(ApprovedColor.selection) : c(ApprovedColor.inkTertiary))
                    .frame(width: 30, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(preset == nil).opacity(preset == nil ? 0.35 : 1)
            .accessibilityLabel(Text("Favourite"))
            .accessibilityAddTraits(starred ? .isSelected : [])
            .accessibilityIdentifier("develop.star")
            Text(preset?.displayName ?? "Original")
                .l2Heading(17).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(c(ApprovedColor.ink))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("develop.name")
            if model.session.recipe.look != nil {
                Button(action: model.clearPreset) { L2Label(title: Text("Reset"), icon: .reset, iconSize: 15) }
                    .buttonStyle(L2LinkButtonStyle())
                    .accessibilityLabel("Reset preset").accessibilityIdentifier("develop.clear")
            }
        }
        .frame(minHeight: 36)
    }

    /// Landscape iPad (`developList`): one 38 pt row per category, 12 pt corners; the browsed one bold on a chip fill
    /// with the orange underline; the applied one dotted.
    private var categoryList: some View {
        VStack(spacing: 2) {
            ForEach(model.categoryItems) { item in
                let isOn = item.id == model.currentCategoryID
                Button { model.selectCategory(item.id) } label: {
                    HStack(spacing: 6) {
                        HStack(spacing: 6) {
                            if item.isFavourites { ApprovedIconView(icon: .star, size: 14) }
                            Text(item.name).l2Text(14.5, weight: isOn ? .bold : .medium)
                        }
                        .padding(.bottom, isOn ? 2 : 0)
                        .overlay(alignment: .bottom) { if isOn { Rectangle().fill(c(ApprovedColor.browse)).frame(height: 2) } }
                        if item.holdsAppliedPreset { Circle().fill(c(ApprovedColor.edited)).frame(width: 5, height: 5) }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(isOn ? c(ApprovedColor.ink) : c(ApprovedColor.inkSecondary))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 38)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isOn ? c(ApprovedColor.chip) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.name))
                .accessibilityValue(Text(item.holdsAppliedPreset ? "Contains the applied preset" : ""))
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityIdentifier("develop.category.\(item.id)")
            }
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var notice: some View {
        if model.isFavouritesFullNoticeShown {
            L2Notice(icon: .star, bold: "Favourites holds ten presets.", text: " Remove one in Preferences, or replace one now.",
                     actions: [("Replace…", "develop.favourites.replace", { model.isReplaceSheetShown = true }),
                               ("Not now", "develop.favourites.notNow", { model.dismissFavouritesFullNotice() })])
        } else if model.session.autoState == .failed {
            L2Notice(icon: .warn, bold: "Automatic correction didn't finish.", text: " Your photo is unchanged and presets still work.",
                     actions: [("Retry", "develop.auto.retry", { model.session.retryAuto() }),
                               ("Continue with original", "develop.auto.original", { model.session.continueWithOriginal() })])
        }
        // Unavailable Auto: no standing notice (owner amendment 2026-10-05); tapping Auto explains it (EditorSession.toggleAuto).
    }
}

/// A panel notice (Lightly 2 `notice`).
struct DevelopNotice: View {
    let icon: ApprovedIcon
    let bold: String?
    let text: String
    let actions: [(title: String, identifier: String, action: () -> Void)]

    var body: some View {
        L2Notice(icon: icon, bold: bold, text: text, actions: actions).accessibilityIdentifier("develop.notice")
    }
}

/// `quietBtn`: the chip-filled 38 pt capsule.
struct ApprovedSmallQuietButtonStyle: ButtonStyle {
    var accent = false
    func makeBody(configuration: Configuration) -> some View {
        L2QuietButtonStyle(accent: accent).makeBody(configuration: configuration)
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
                .contentShape(Rectangle())
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
            .frame(height: 44)
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
