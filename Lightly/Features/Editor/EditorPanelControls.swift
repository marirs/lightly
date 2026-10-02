import SwiftUI

// Controls in the editor's bottom panel. They always sit on the plain
// background (never over the photo), so every control boundary uses
// `controlChrome(onPlainBackground: true)`: a solid fill plus a ≥ 3:1
// outline (WCAG 1.4.11), with labels ≥ 4.5:1 on that fill.

/// Look categories and the stepped slider (spec D5/D6).
struct LookControls: View {
    let viewModel: LUTEditorViewModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: LightlySpacing.s) {
            if viewModel.categories.isEmpty {
                Text("editor.looks.noneInBuild", bundle: .main)
                    .font(LightlyTypography.rowSubtitle)
                    .foregroundStyle(LightlyColor.textSecondary(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("editor.looks.none")
            } else {
                categoryChips
                if !viewModel.stops.isEmpty {
                    SteppedLookSlider(viewModel: viewModel)
                }
            }
        }
    }

    /// One row at standard sizes; wraps at accessibility sizes so every
    /// category stays visible and legible (no off-screen scrolling).
    private var categoryChips: some View {
        EqualWidthRows(
            viewModel.categories,
            perRow: dynamicTypeSize.isAccessibilitySize ? 2 : max(viewModel.categories.count, 1)
        ) { category in
            categoryChip(category)
        }
    }

    private func categoryChip(_ category: LUTLookCategory) -> some View {
        let isSelected = category.id == viewModel.selectedCategoryID
        return Button {
            viewModel.selectCategory(category.id)
        } label: {
            Text(LookCategoryName.key(for: category.id), bundle: .main)
                .font(LightlyTypography.caption.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                // Selected inverts the colours, so the state reads without
                // relying on the accent hue.
                .foregroundStyle(isSelected ? LightlyColor.background(colorScheme) : LightlyColor.textPrimary(colorScheme))
                .frame(maxWidth: .infinity, minHeight: LightlySize.minimumTapTarget)
                .background(
                    Capsule().fill(isSelected ? LightlyColor.textPrimary(colorScheme) : LightlyColor.surfaceElevated(colorScheme))
                )
                .overlay(Capsule().strokeBorder(LightlyColor.controlBoundary(colorScheme), lineWidth: 1.5))
                .layoutAnchor("editor.category.\(category.id)")
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("editor.category.\(category.id)")
    }
}

/// The stepped Look slider: stop 0 is Auto, then the category's Looks.
///
/// Dragging previews each stop as it is reached; lifting the finger
/// commits. VoiceOver/Switch Control increments commit directly, one stop
/// per step (spec §2 step 4: "a keyboard/accessibility increment").
struct SteppedLookSlider: View {
    let viewModel: LUTEditorViewModel

    @Environment(\.colorScheme) private var colorScheme

    private var stops: [LookStop] { viewModel.stops }
    private var lastIndex: Int { max(stops.count - 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: LightlySpacing.xxs) {
            stopName(viewModel.displayedStopIndex)
                .font(LightlyTypography.rowTitle)
                .foregroundStyle(LightlyColor.textPrimary(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                // The slider's own accessibility value carries the name.
                .accessibilityHidden(true)

            Slider(
                value: Binding(
                    get: { Double(viewModel.displayedStopIndex) },
                    set: { viewModel.previewStop(Int($0.rounded())) }
                ),
                in: 0...Double(lastIndex),
                step: 1,
                onEditingChanged: { isEditing in
                    if !isEditing { viewModel.settleStop(viewModel.displayedStopIndex) }
                }
            )
            .tint(LightlyColor.textPrimary(colorScheme))
            .layoutAnchor("editor.lookSlider")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("editor.lookSlider.accessibility", bundle: .main))
            .accessibilityValue(accessibilityValue)
            .accessibilityAdjustableAction { direction in
                let current = viewModel.displayedStopIndex
                switch direction {
                case .increment: viewModel.settleStop(min(current + 1, stops.count - 1))
                case .decrement: viewModel.settleStop(max(current - 1, 0))
                @unknown default: break
                }
            }
            .accessibilityIdentifier("editor.lookSlider")
        }
    }

    private func stopName(_ index: Int) -> Text {
        guard stops.indices.contains(index), let name = stops[index].lookName else {
            return Text("editor.stop.auto", bundle: .main)
        }
        // Placeholder Look names are provisional data, not product copy.
        // DEFERRED: localised Look names arrive with the curated look-book.
        return Text(verbatim: name)
    }

    /// e.g. "Warm, Golden, stop 2 of 3".
    private var accessibilityValue: String {
        let index = viewModel.displayedStopIndex
        let category = viewModel.selectedCategoryID.map(LookCategoryName.localized(for:)) ?? ""
        let name = stops.indices.contains(index) ? (stops[index].lookName ?? String(localized: "editor.stop.auto")) : ""
        return String(format: String(localized: "editor.lookSlider.value"), category, name, index + 1, stops.count)
    }
}

/// Undo, Reset to Auto, Compare (toggle) and Save copy.
struct EditActions: View {
    let viewModel: LUTEditorViewModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Four across at standard sizes; two per row at accessibility sizes
        // so labels stay whole.
        VStack(spacing: LightlySpacing.xs) {
            HStack(spacing: LightlySpacing.xs) {
                undoAction
                resetAction
                if !dynamicTypeSize.isAccessibilitySize { compareAction; saveCopyAction }
            }
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: LightlySpacing.xs) { compareAction; saveCopyAction }
            }
        }
    }

    private var undoAction: some View {
        action(symbol: "arrow.uturn.backward", labelKey: "action.undo", identifier: "action.undo",
                   isEnabled: viewModel.canUndo) { viewModel.undo() }
    }

    private var resetAction: some View {
        action(symbol: "arrow.counterclockwise", labelKey: "action.reset", identifier: "action.reset",
                   isEnabled: viewModel.canResetToAuto) { viewModel.resetToAuto() }
                .accessibilityLabel(Text("action.reset.accessibility", bundle: .main))
    }

    private var compareAction: some View {
        action(symbol: "rectangle.righthalf.inset.filled", labelKey: "action.compare", identifier: "action.compare",
                   isEnabled: viewModel.isReady, isSelected: viewModel.isCompareToggledOn) { viewModel.toggleCompare() }
                .accessibilityLabel(Text("action.compare.accessibility", bundle: .main))
                .accessibilityHint(Text("action.compare.hint", bundle: .main))
    }

    private var saveCopyAction: some View {
        action(symbol: "square.and.arrow.down", labelKey: "action.saveCopy", identifier: "action.saveCopy",
                   isEnabled: viewModel.canSaveCopy) { viewModel.saveCopy() }
    }

    private func action(
        symbol: String,
        labelKey: LocalizedStringKey,
        identifier: String,
        isEnabled: Bool,
        isSelected: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            VStack(spacing: LightlySpacing.xxs) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                Text(labelKey, bundle: .main)
                    .font(LightlyTypography.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? LightlyColor.background(colorScheme) : LightlyColor.textPrimary(colorScheme))
            .frame(maxWidth: .infinity, minHeight: LightlySize.minimumTapTarget + LightlySpacing.s)
            .background(
                RoundedRectangle(cornerRadius: LightlyRadius.row, style: .continuous)
                    .fill(isSelected ? LightlyColor.textPrimary(colorScheme) : LightlyColor.surfaceElevated(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LightlyRadius.row, style: .continuous)
                    .strokeBorder(LightlyColor.controlBoundary(colorScheme), lineWidth: 1.5)
            )
            .layoutAnchor("editor.control.\(identifier)")
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // Disabled controls are exempt from WCAG contrast, but they must
        // still read as unavailable rather than as broken.
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

/// Outcome of the last Save copy, worded per spec §2 step 7.
// DEFERRED: the "View" action that opens the new photo. Lightly has
// add-only library access, so it cannot read the asset back to show it.
struct SaveCopyStatusLine: View {
    let status: SaveCopyStatus

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch status {
            case .idle:
                EmptyView()
            case .saving:
                HStack(spacing: LightlySpacing.xs) {
                    ProgressView()
                    Text("editor.save.saving", bundle: .main)
                }
            case .saved:
                Label {
                    Text("editor.save.saved", bundle: .main)
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            case .failed(let error):
                Label {
                    Text(error.localizedMessageKey, bundle: .main)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
            }
        }
        .font(LightlyTypography.rowSubtitle)
        .foregroundStyle(LightlyColor.textPrimary(colorScheme))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor.saveStatus")
    }
}

/// Notices shown above the photo. They state limits of this build plainly:
/// a missing Auto model must never look like an enhanced photo, and
/// placeholder Looks must never look like the product's curated Looks.
struct EditorNotices: View {
    let viewModel: LUTEditorViewModel
    /// Inside the bottom panel the panel already provides the margins.
    var isInsideBottomPanel = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: LightlySpacing.xs) {
            if viewModel.isAutoUnavailable {
                notice(symbol: "wand.and.stars.inverse", messageKey: "editor.auto.unavailable.notice",
                       identifier: "editor.autoUnavailableNotice")
            }
            if viewModel.lookBook.isProvisional {
                notice(symbol: "flask", messageKey: "editor.looks.provisional.notice",
                       identifier: "editor.provisionalLooksNotice")
            }
        }
        .padding(.horizontal, isInsideBottomPanel ? 0 : LightlySpacing.m)
        .padding(.top, isInsideBottomPanel ? 0 : LightlySpacing.xs)
    }

    private func notice(symbol: String, messageKey: LocalizedStringKey, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LightlySpacing.xs) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
            Text(messageKey, bundle: .main)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(LightlyTypography.caption)
        .foregroundStyle(LightlyColor.textPrimary(colorScheme))
        .padding(.horizontal, LightlySpacing.s)
        .padding(.vertical, LightlySpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: LightlyRadius.row, style: .continuous)
                .fill(LightlyColor.surfaceElevated(colorScheme))
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

/// Lays items out in rows of `perRow` equal-width cells.
///
/// Not a lazy grid: the panel may scroll at large text sizes, and every
/// control must exist (for VoiceOver and for layout tests) even while it is
/// scrolled out of view.
struct EqualWidthRows<Item: Identifiable, Cell: View>: View {
    private let rows: [[Item]]
    private let perRow: Int
    private let cell: (Item) -> Cell

    init(_ items: [Item], perRow: Int, @ViewBuilder cell: @escaping (Item) -> Cell) {
        self.perRow = max(perRow, 1)
        self.rows = stride(from: 0, to: items.count, by: self.perRow).map {
            Array(items[$0..<min($0 + max(perRow, 1), items.count)])
        }
        self.cell = cell
    }

    var body: some View {
        VStack(spacing: LightlySpacing.xs) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(spacing: LightlySpacing.xs) {
                    ForEach(rows[rowIndex]) { item in cell(item) }
                    // Keeps a short last row's cells the same width as the
                    // rows above.
                    ForEach(0..<(perRow - rows[rowIndex].count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
        }
    }
}

/// Localised category names (`editor.lookCategory.<id>`).
///
/// Keys are built as plain strings on purpose: an interpolated literal
/// passed to `LocalizedStringKey` becomes a *format* key
/// ("editor.lookCategory.%@") and never matches the catalogue.
enum LookCategoryName {
    static func key(for categoryID: String) -> LocalizedStringKey {
        let key = "editor.lookCategory." + categoryID
        return LocalizedStringKey(key)
    }

    static func localized(for categoryID: String) -> String {
        Bundle.main.localizedString(forKey: "editor.lookCategory." + categoryID, value: categoryID, table: nil)
    }
}
