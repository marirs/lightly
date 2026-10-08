import SwiftUI

/// Controls the tool panels share (approved `styles.css`): `.tabs`, `.sl`, `.opt`, `.sw`,
/// `.thumbopt`, `.chiprow`, the panel title and the stage progress box.

/// `.ptitle`: the tool's name at the top of a side panel ("roomy").
struct PanelTitle: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Text(text)
            .approvedText(13, weight: .semibold)
            .foregroundStyle(ApprovedColor.inkSecondary.resolved(colorScheme))
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// `.tabs`: a row of text tabs, the selected one ink and semibold, an optional dot. Scrolls with
/// faded ends on phones and brings the selected tab to 120 pt from the screen edge; wraps in the
/// tablet-portrait panel (`.wrapped .tabs`).
struct PanelTabs<ID: Hashable>: View {
    let items: [(id: ID, title: String, dotted: Bool)]
    let selected: ID
    let wraps: Bool
    let identifierPrefix: String
    let onSelect: (ID) -> Void

    @State private var viewport: CGRect = .zero
    @State private var widths: [Int: CGFloat] = [:]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if wraps {
            FlowLayout(spacing: 20) { ForEach(items.indices, id: \.self) { tab($0) } }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(items.indices, id: \.self) { index in
                            tab(index).id(index)
                                .background(GeometryReader { p in Color.clear.preference(key: TabWidthKey.self, value: [index: p.size.width]) })
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(GeometryReader { p in Color.clear.preference(key: TabViewportKey.self, value: p.frame(in: .global)) })
                .mask(LinearGradient(stops: fade, startPoint: .leading, endPoint: .trailing))
                .onPreferenceChange(TabWidthKey.self) { widths = $0; position(reader) }
                .onPreferenceChange(TabViewportKey.self) { viewport = $0; position(reader) }
                .onChange(of: selected) { position(reader) }
            }
        }
    }

    private var fade: [Gradient.Stop] {
        let w = max(viewport.width, 1)
        return [.init(color: .clear, location: 0), .init(color: .black, location: min(16 / w, 0.5)),
                .init(color: .black, location: max(1 - 24 / w, 0.5)), .init(color: .clear, location: 1)]
    }

    private func position(_ reader: ScrollViewProxy) {
        guard let index = items.firstIndex(where: { $0.id == selected }), let width = widths[index], viewport.width > width else { return }
        let total = widths.values.reduce(0, +) + CGFloat(max(items.count - 1, 0)) * 20 + 36
        guard total > viewport.width else { return }
        // Prototype: scrollLeft = max(0, tab.offsetLeft − 120), where offsetLeft is measured from
        // the screen's left edge (the tabs' offsetParent), clamped by the scroll range. In a side
        // panel the row starts far from the edge, so the selected tab scrolls to the end.
        let tabOffset = 18 + (0..<index).reduce(CGFloat(0)) { $0 + (widths[$1] ?? 0) + 20 }
        let maxScroll = max(total - viewport.width, 0)
        let scroll = min(max(tabOffset + viewport.minX - 120, 0), maxScroll)
        let fraction = (tabOffset - scroll) / max(viewport.width - width, 1)
        reader.scrollTo(index, anchor: UnitPoint(x: fraction, y: 0.5))
    }

    private func tab(_ index: Int) -> some View {
        let item = items[index], isOn = item.id == selected
        return Button { onSelect(item.id) } label: {
            HStack(spacing: 4) {
                Text(item.title).approvedText(15, weight: isOn ? .semibold : .regular)
                if item.dotted {
                    Circle().fill(ApprovedColor.edited.resolved(colorScheme)).frame(width: 5, height: 5).padding(.leading, 3)
                }
            }
            .lineLimit(1).fixedSize()
            .foregroundStyle((isOn ? ApprovedColor.ink : ApprovedColor.inkSecondary).resolved(colorScheme))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("\(identifierPrefix).\(item.title)")
    }
}

private struct TabWidthKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue()) { $1 } }
}

private struct TabViewportKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let n = nextValue(); if n != .zero { value = n } }
}

/// `.sl` with the full range of the prototype's `sl()`: a centre-anchored fill when the range
/// goes below zero, "+" on positive values of such a slider.
struct PanelSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let identifier: String
    let onChange: (Double) -> Void
    let onEnd: (Double) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let span = range.upperBound - range.lowerBound
        let fraction = (value - range.lowerBound) / span
        let mid = range.lowerBound < 0
        HStack(spacing: 12) {
            Text(label).approvedText(15).foregroundStyle(ApprovedColor.ink.resolved(colorScheme)).lineLimit(1).fixedSize()
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(ApprovedColor.track.resolved(colorScheme)).frame(height: 3)
                    Capsule().fill(ApprovedColor.ink.resolved(colorScheme))
                        .frame(width: width * abs(fraction - (mid ? 0.5 : 0)), height: 3)
                        .offset(x: mid ? width * min(0.5, fraction) : 0)
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
                    .onChanged { onChange(ApprovedSlider.value(at: $0.location.x, width: width, range: range)) }
                    .onEnded { onEnd(ApprovedSlider.value(at: $0.location.x, width: width, range: range)) })
            }
            .frame(minWidth: 90)
            Text("\(value > 0 && mid ? "+" : "")\(Int(value.rounded()))")
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
            let step = span / 20
            onEnd(min(max(value + (direction == .increment ? step : -step), range.lowerBound), range.upperBound))
        }
        .accessibilityIdentifier(identifier)
    }
}

/// `.chiprow`: options in a sideways-scrolling row, 8 pt apart, 6/18 pt padding.
struct ChipRow<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content() }.padding(.horizontal, 18).padding(.vertical, 6)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

/// `.opt`: a bordered option, selected in the selection colour on its soft fill.
struct OptionChip<Label: View>: View {
    let isOn: Bool
    let identifier: String
    /// `.opt` min-width 44; the saved-signature chips set `min-width:120px`.
    var minWidth: CGFloat = 44
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { label() }
                .foregroundStyle((isOn ? ApprovedColor.selection : ApprovedColor.inkSecondary).resolved(colorScheme))
                // `.opt` is border-box: 12 pt padding plus its 1 pt border on each side. The border
                // here is drawn inside the frame, so the content needs 13 pt to keep the width.
                // CSS min-width is border-box too: the content's minimum is min-width − 26.
                .frame(minWidth: minWidth - 26, minHeight: 44)
                .padding(.horizontal, 13)
                .background(RoundedRectangle(cornerRadius: 10).fill(isOn ? selectionSoft : .clear))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((isOn ? ApprovedColor.selection : ApprovedColor.hairline).resolved(colorScheme), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    /// `--selSoft`.
    private var selectionSoft: Color {
        colorScheme == .dark ? Color(red: 122 / 255, green: 162 / 255, blue: 1).opacity(0.14) : Color(red: 34 / 255, green: 87 / 255, blue: 210 / 255).opacity(0.08)
    }
}

/// `.sw`: a 44 pt swatch (round, or `width × 44` rounded 10 for gradients), with the selection
/// ring 5 pt outside when chosen.
struct SwatchButton<Fill: ShapeStyle>: View {
    let fill: Fill
    var width: CGFloat = 44
    var cornerRadius: CGFloat = 22
    let isOn: Bool
    let label: String
    let identifier: String
    /// VoiceOver value: the colour's name (the approved label is only "Colour").
    var colourName: String?
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: cornerRadius).fill(fill)
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(ApprovedColor.hairline.resolved(colorScheme), lineWidth: 1))
                .frame(width: width, height: 44)
                .overlay {
                    if isOn {
                        // `.sw.on::after`: inset −5, a 2 pt ring, border-radius 50 %.
                        RoundedRectangle(cornerRadius: cornerRadius + 5).strokeBorder(ApprovedColor.selection.resolved(colorScheme), lineWidth: 2)
                            .frame(width: width + 10, height: 54)
                    }
                }
                .padding(.horizontal, isOn ? 0 : 0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(colourName ?? ""))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    /// Spoken names of the approved swatch colours (Border, Watermark, Change background).
    static func name(ofHex hex: String) -> String? {
        [
            "#FFFFFF": "White", "#F4F1EC": "Warm white", "#111111": "Black", "#3C4A55": "Slate", "#C9A27E": "Tan",
            "#5A4636": "Brown", "#C9C2B8": "Stone", "#1F2328": "Charcoal", "#8A8A8F": "Grey",
            // Change background colours, named as on Android so both platforms read alike.
            "#D9D4CC": "Light stone", "#9AA3A8": "Blue grey", "#8A5A44": "Rust", "#4E6B5A": "Forest green"
        ][hex.uppercased()]
    }
}

/// The stage's `.progress` box for an operation in progress: spinner, label, Cancel (no bar).
struct StageOperationProgress: View {
    let title: String
    let identifier: String
    let onCancel: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            RingSpinner().padding(.bottom, 8)
            Text(title).font(.system(size: 14))
            Button("Cancel", action: onCancel)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(minWidth: 64, minHeight: 44)
                .padding(.top, 6)
                .accessibilityIdentifier("\(identifier).cancel")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .modifier(ShrinkToFitWidth(minimum: 200, maximum: nil))
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 20 / 255, green: 20 / 255, blue: 22 / 255).opacity(0.72)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}
