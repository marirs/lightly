import SwiftUI

/// Scoped reset (Lightly 2 `resetRow`): the section title (14 pt bold) and, when there is something to reset, "Reset".
/// Reset offers this adjustment, the whole tool, or Cancel (`actionSheet` 'Reset').
struct PanelResetRow: View {
    let session: EditorSession
    let section: String
    let title: String
    var adjustment: String? = nil
    var resetAdjustment: (() -> Void)? = nil
    @State private var showsChoices = false
    var body: some View {
        L2ResetRow(title: title, canReset: session.canReset(section: section), identifier: "reset.\(section)") { showsChoices = true }
            .fullScreenCover(isPresented: $showsChoices) {
                L2ActionSheet(title: "Reset", options: options, onCancel: { showsChoices = false })
                    .presentationBackground(.clear)
            }
            .transaction { if showsChoices { $0.disablesAnimations = true } }
    }

    private var options: [(title: String, identifier: String, action: () -> Void)] {
        var list: [(title: String, identifier: String, action: () -> Void)] = []
        if let adjustment {
            list.append(("Reset \(title.lowercased())", "reset.\(section).\(adjustment)", {
                showsChoices = false
                if let resetAdjustment { resetAdjustment() } else { session.resetEdits(section: section, adjustment: adjustment) }
            }))
        }
        list.append(("Reset \(section)", "reset.\(section).all", { showsChoices = false; session.resetEdits(section: section) }))
        return list
    }
}

/// The panel's own title is drawn by its container in Lightly 2 (two-pane and iPad headers), never inside the panel.
struct PanelTitle: View {
    let text: String
    var body: some View { EmptyView() }
}

/// Tool tabs (Lightly 2 `tabs`): scrolling text tabs, selected bold ink, others ink3, an orange dot on tabs with edits.
struct PanelTabs<ID: Hashable>: View {
    let items: [(id: ID, title: String, dotted: Bool)]
    let selected: ID
    let wraps: Bool
    let identifierPrefix: String
    let onSelect: (ID) -> Void

    var body: some View {
        L2Tabs(items: items.map { .init(value: $0.id, title: Text(LocalizedStringKey($0.title)), dot: $0.dotted,
                                        identifier: "\(identifierPrefix).\($0.title)") },
               selection: selected, onSelect: onSelect)
    }
}

/// A panel slider (Lightly 2 `slider`).
struct PanelSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let identifier: String
    var isEnabled = true
    let onChange: (Double) -> Void
    let onEnd: (Double) -> Void

    var body: some View {
        L2Slider(label: label, value: value, range: range, isEnabled: isEnabled, onChange: onChange, onEnd: onEnd)
            .accessibilityIdentifier(identifier)
    }
}

/// A sideways-scrolling row (`rowOf`): 8 pt gaps, the right edge fading (88 %).
struct ChipRow<Content: View>: View {
    var spacing: CGFloat = 8
    /// The selected chip's index, for rows that follow the mockup's `scrolled()` (the chip before it sits at the leading
    /// edge). The chips must carry `.id(index)`. nil leaves the row where the finger put it.
    var scrolledToIndex: Int? = nil
    @ViewBuilder let content: () -> Content
    /// The end fades only while chips are hidden past it (owner amendment 2026-10-10, as `L2Tabs`), so not once scrolled
    /// to the end (owner report 2026-10-11).
    @State private var hidesMore = false
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) { content() }.padding(.vertical, 4).padding(.horizontal, 2)
                    .reportsTrailingEdge(in: "chiprow")
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .trailingOverflowFade(in: "chiprow", hidesMore: $hidesMore)
            .onChange(of: scrolledToIndex, initial: true) { _, index in
                guard let index else { return }
                proxy.scrollTo(max(0, index - 1), anchor: .leading)
            }
        }
    }
}

/// An option (Lightly 2 `chips`): a 38 pt capsule, 13 pt padding; selected on an ink fill with on-ink text, others
/// outlined in ink2. `card` options (signatures, fonts, paper) are 50 pt or taller, 16 pt corners, with a 2 pt accent
/// border when selected.
struct OptionChip<Label: View>: View {
    let isOn: Bool
    let identifier: String
    var minWidth: CGFloat = 0
    var card = false
    var cardHeight: CGFloat = 50
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let c = L2(scheme: colorScheme)
        Button(action: action) {
            if card {
                HStack(spacing: 6) { label() }
                    .l2Text(13, weight: .semibold)
                    .foregroundStyle(c(ApprovedColor.ink))
                    .padding(.horizontal, 12)
                    .frame(minWidth: minWidth, minHeight: cardHeight)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(isOn ? c(ApprovedColor.selection) : c(ApprovedColor.hairline), lineWidth: isOn ? 2 : 1))
                    .contentShape(Rectangle())
            } else {
                HStack(spacing: 6) { label() }
                    .l2Text(13, weight: .semibold)
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(isOn ? c(ApprovedColor.onInk) : c(ApprovedColor.inkSecondary))
                    .padding(.horizontal, 13)
                    .frame(minWidth: minWidth, minHeight: 38)
                    .background(Capsule().fill(isOn ? c(ApprovedColor.segmentSelected) : .clear))
                    .overlay { if !isOn { Capsule().strokeBorder(c(ApprovedColor.hairline), lineWidth: 1) } }
                    .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// A swatch (Lightly 2 gradient swatches): `width`×`height`, `cornerRadius`; when chosen, a 2 pt sheet-coloured gap
/// and a 2 pt accent ring outside it.
struct SwatchButton<Fill: ShapeStyle>: View {
    let fill: Fill
    var width: CGFloat = 56
    var height: CGFloat = 42
    var cornerRadius: CGFloat = 14
    let isOn: Bool
    let label: String
    let identifier: String
    /// VoiceOver value: the colour's name.
    var colourName: String?
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let c = L2(scheme: colorScheme)
        Button(action: action) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill)
                .frame(width: width, height: height)
                .overlay {
                    if isOn {
                        RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous).stroke(c(ApprovedColor.sheet), lineWidth: 2).padding(-1)
                        RoundedRectangle(cornerRadius: cornerRadius + 4, style: .continuous).stroke(c(ApprovedColor.selection), lineWidth: 2).padding(-3)
                    }
                }
                .padding(4)
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

/// The stage's progress card for an operation in progress: spinner, label, Cancel (no bar).
struct StageOperationProgress: View {
    let title: String
    let identifier: String
    let onCancel: () -> Void
    var body: some View {
        ProgressBox(title: title) { ProgressCancelButton(identifier: "\(identifier).cancel", action: onCancel) }
            .accessibilityIdentifier(identifier)
    }
}
