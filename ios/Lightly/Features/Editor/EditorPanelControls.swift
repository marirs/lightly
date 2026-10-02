import SwiftUI

// Controls in the editor's panel. They always sit on the plain background (never over the photo),
// so every control boundary uses `controlChrome(onPlainBackground: true)`: a solid fill plus a
// ≥ 3:1 outline (WCAG 1.4.11), with labels ≥ 4.5:1 on that fill.

/// Look categories, the selected preset's name and position, and the stepped slider (spec D5/D6).
/// All of it comes from the Look pack: no category name, count or order is known to this view.
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

    /// The widest arrangement whose labels fit whole: one row when they
    /// fit, otherwise wrapped rows, so every category stays visible and
    /// legible (no off-screen scrolling) whatever the pack's labels are.
    private var categoryChips: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(chipsPerRowCandidates, id: \.self) { perRow in
                EqualWidthRows(viewModel.categories, perRow: perRow) { category in
                    categoryChip(category)
                }
            }
        }
    }

    /// Candidate chips-per-row, widest first. Accessibility sizes start at
    /// two per row (spec §6: the category row becomes a list at AX sizes).
    /// The last candidate is one per row, which always fits.
    private var chipsPerRowCandidates: [Int] {
        let count = max(viewModel.categories.count, 1)
        let widest = dynamicTypeSize.isAccessibilitySize ? min(count, 2) : count
        return Array(Set([widest, min(widest, 3), min(widest, 2), 1])).sorted(by: >)
    }

    private func categoryChip(_ category: LUTLookCategory) -> some View {
        let isSelected = category.id == viewModel.selectedCategoryID
        return Button {
            viewModel.selectCategory(category.id)
        } label: {
            // The label is pack data, shown verbatim (not a localisation key).
            Text(verbatim: category.label)
                .font(LightlyTypography.caption.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, LightlySpacing.xs)
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

/// The stepped Look slider: stop 0 is "no Look" (labelled "Original", or "Auto" while an Auto
/// correction is applied), then one stop per preset of the category in the pack's browse order.
/// It selects a preset; it is never an intensity control (spec D6), so there is no value between
/// two stops, and every stop has a visible marker.
///
/// Dragging moves the selection by the distance dragged (like a thumb: a drag to the right never
/// selects a stop further left), previewing each stop as it is reached; lifting the finger commits;
/// a tap commits the stop under the finger. VoiceOver/Switch Control increments commit directly, one stop per step (spec §2
/// step 4: "a keyboard/accessibility increment").
struct SteppedLookSlider: View {
    let viewModel: LUTEditorViewModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: LightlySpacing.xxs) {
            nameAndPosition
            SteppedTrack(
                stopCount: viewModel.stops.count,
                selectedIndex: viewModel.displayedStopIndex,
                onPreview: { viewModel.previewStop($0) },
                onSettle: { viewModel.settleStop($0) },
                onCancel: { viewModel.cancelStopPreview() },
                onInterrupted: { viewModel.settleStopPreviewIfAny() }
            )
            .layoutAnchor("editor.lookSlider")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("editor.lookSlider.accessibility", bundle: .main))
            .accessibilityValue(viewModel.sliderAccessibilityValue)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: viewModel.adjustStop(by: 1)
                case .decrement: viewModel.adjustStop(by: -1)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("editor.lookSlider")
        }
    }

    /// "Nordic Tone (10) · 3 of 5". Preset names are pack data, shown verbatim. They wrap rather
    /// than truncate: at large text "Cinematic Light Tone (11)" needs two lines, and a clipped
    /// name would hide which preset it is. The position moves to its own line when the two do not
    /// fit side by side.
    // DEFERRED: product-facing Look names (spec U8) and their localisation; until then the
    // preset's own name is shown.
    private var nameAndPosition: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: LightlySpacing.xs) {
                stopName.fixedSize()
                positionSeparator
                stopPosition
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: LightlySpacing.xxs) {
                stopName
                stopPosition
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The slider's own accessibility value carries the name and position.
        .accessibilityHidden(true)
    }

    private var stopName: some View {
        Text(verbatim: viewModel.stopLabel(at: viewModel.displayedStopIndex))
            .font(LightlyTypography.rowTitle)
            .foregroundStyle(LightlyColor.textPrimary(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .layoutAnchor("editor.lookStopName")
            .accessibilityIdentifier("editor.lookStopName")
    }

    private var positionSeparator: some View {
        Text(verbatim: "·")
            .font(LightlyTypography.rowSubtitle)
            .foregroundStyle(LightlyColor.textSecondary(colorScheme))
    }

    private var stopPosition: some View {
        Text(verbatim: viewModel.stopPositionText)
            .font(LightlyTypography.rowSubtitle.monospacedDigit())
            .foregroundStyle(LightlyColor.textSecondary(colorScheme))
            .fixedSize()
            .layoutAnchor("editor.lookStopPosition")
            .accessibilityIdentifier("editor.lookStopPosition")
    }
}

/// A track with one detent per stop and a thumb on the selected one.
///
/// Custom rather than `Slider(step:)`: the system slider draws no detents, and the agreed UX needs
/// a visible marker per stop. Geometry matches UISlider's (thumb centre inset by its radius), so
/// stop `i` of `n` sits at `i/(n-1)` of the inset width.
struct SteppedTrack: View {
    let stopCount: Int
    let selectedIndex: Int
    let onPreview: (Int) -> Void
    let onSettle: (Int) -> Void
    /// A drag that turned out to be vertical (scrolling the panel) changes nothing.
    let onCancel: () -> Void
    /// The gesture ended without `onEnded` (cancelled by the system, e.g. when the panel's layout
    /// changes under the finger). Without this a preview could stay on screen uncommitted.
    let onInterrupted: () -> Void

    static let thumbDiameter: CGFloat = 28
    static let height: CGFloat = 44
    private static let detentDiameter: CGFloat = 8
    /// Movement before a drag is classified as horizontal (select) or vertical (scroll).
    private static let axisDecisionDistance: CGFloat = 6

    @Environment(\.colorScheme) private var colorScheme
    @State private var dragAxis: Axis?
    /// The selected stop when the press began; a drag moves relative to it.
    @State private var dragStartIndex = 0
    @GestureState private var isPressing = false

    var body: some View {
        GeometryReader { proxy in
            let positions = Self.stopPositions(count: stopCount, width: proxy.size.width)
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(LightlyColor.controlBoundary(colorScheme))
                    .frame(width: max(proxy.size.width - Self.thumbDiameter, 0), height: 3)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                ForEach(positions.indices, id: \.self) { index in
                    Circle()
                        .fill(index <= selectedIndex ? LightlyColor.textPrimary(colorScheme) : LightlyColor.surfaceElevated(colorScheme))
                        .overlay(Circle().strokeBorder(LightlyColor.controlBoundary(colorScheme), lineWidth: 1.5))
                        .frame(width: Self.detentDiameter, height: Self.detentDiameter)
                        .position(x: positions[index], y: proxy.size.height / 2)
                }
                if positions.indices.contains(selectedIndex) {
                    Circle()
                        .fill(LightlyColor.textPrimary(colorScheme))
                        .overlay(Circle().strokeBorder(LightlyColor.background(colorScheme), lineWidth: 2))
                        .frame(width: Self.thumbDiameter, height: Self.thumbDiameter)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .position(x: positions[selectedIndex], y: proxy.size.height / 2)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            // Simultaneous, so the panel can still scroll when a vertical swipe starts on the track.
            .simultaneousGesture(dragGesture(positions: positions))
            .onChange(of: isPressing) { _, pressing in
                // A new press starts unclassified. An ended press commits any preview left behind;
                // after a normal release `onEnded` has already settled it and this does nothing.
                if pressing {
                    dragAxis = nil
                    dragStartIndex = selectedIndex
                } else {
                    onInterrupted()
                }
            }
        }
        .frame(height: Self.height)
    }

    private func dragGesture(positions: [CGFloat]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isPressing) { _, pressing, _ in pressing = true }
            .onChanged { value in
                if dragAxis == nil {
                    let dx = abs(value.translation.width), dy = abs(value.translation.height)
                    if dx >= Self.axisDecisionDistance, dx > dy { dragAxis = .horizontal }
                    if dy >= Self.axisDecisionDistance, dy >= dx { dragAxis = .vertical }
                }
                if dragAxis == .horizontal {
                    onPreview(Self.stop(from: dragStartIndex, dragged: value.translation.width, positions: positions))
                }
            }
            .onEnded { value in
                defer { dragAxis = nil }
                switch dragAxis {
                case .vertical:
                    onCancel()
                case .horizontal:
                    onSettle(Self.stop(from: dragStartIndex, dragged: value.translation.width, positions: positions))
                case nil:
                    // A tap that never moved far enough to decide: the stop under the finger.
                    onSettle(Self.nearestStop(to: value.location.x, positions: positions))
                }
            }
    }

    static func stopPositions(count: Int, width: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let inset = thumbDiameter / 2
        guard count > 1 else { return [inset] }
        let usable = max(width - 2 * inset, 0)
        return (0..<count).map { inset + usable * CGFloat($0) / CGFloat(count - 1) }
    }

    /// `start` moved by `distance` points, one stop per stop spacing, clamped to the ends.
    static func stop(from start: Int, dragged distance: CGFloat, positions: [CGFloat]) -> Int {
        guard positions.count > 1 else { return 0 }
        let spacing = positions[1] - positions[0]
        guard spacing > 0 else { return start }
        let moved = start + Int((distance / spacing).rounded())
        return min(max(moved, 0), positions.count - 1)
    }

    static func nearestStop(to x: CGFloat, positions: [CGFloat]) -> Int {
        positions.indices.min { abs(positions[$0] - x) < abs(positions[$1] - x) } ?? 0
    }
}

/// The optional Strength of the applied Look: visually secondary (small type, secondary colour,
/// small control) and shown only while a Look is applied. Dragging previews; releasing commits one
/// undo step. VoiceOver adjusts in 10% steps, each one a step.
struct StrengthControl: View {
    let viewModel: LUTEditorViewModel

    @Environment(\.colorScheme) private var colorScheme

    private static let accessibilityStep: Float = 0.1

    private var percentText: String {
        String(format: String(localized: "editor.strength.value"), Int((viewModel.displayedLookStrength * 100).rounded()))
    }

    var body: some View {
        HStack(spacing: LightlySpacing.xs) {
            Text("editor.strength.label", bundle: .main)
                .font(LightlyTypography.caption)
                .foregroundStyle(LightlyColor.textSecondary(colorScheme))
                .fixedSize()
            Slider(
                value: Binding(
                    get: { Double(viewModel.displayedLookStrength) },
                    set: { viewModel.previewLookStrength(Float($0)) }
                ),
                in: 0...1,
                onEditingChanged: { isEditing in
                    if !isEditing { viewModel.commitLookStrength(viewModel.displayedLookStrength) }
                }
            )
            .tint(LightlyColor.textSecondary(colorScheme))
            .controlSize(.small)
            .layoutAnchor("editor.strengthSlider")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("editor.strength.label", bundle: .main))
            .accessibilityValue(Text(verbatim: percentText))
            .accessibilityAdjustableAction { direction in
                let step: Float = direction == .increment ? Self.accessibilityStep : -Self.accessibilityStep
                viewModel.commitLookStrength(viewModel.displayedLookStrength + step)
            }
            .accessibilityIdentifier("editor.strengthSlider")
            Text(verbatim: percentText)
                .font(LightlyTypography.caption.monospacedDigit())
                .foregroundStyle(LightlyColor.textSecondary(colorScheme))
                .frame(minWidth: 36, alignment: .trailing)
                .fixedSize()
                .accessibilityHidden(true)
        }
        .frame(minHeight: LightlySize.minimumTapTarget)
        .disabled(!viewModel.canAdjustStrength)
        .opacity(viewModel.canAdjustStrength ? 1 : 0.4)
        .layoutAnchor("editor.strength")
    }
}

/// Undo, Redo, Reset to Auto and Compare (toggle). Save copy is in the top bar.
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
                redoAction
                if !dynamicTypeSize.isAccessibilitySize { resetAction; compareAction }
            }
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: LightlySpacing.xs) { resetAction; compareAction }
            }
        }
    }

    private var undoAction: some View {
        action(symbol: "arrow.uturn.backward", labelKey: "action.undo", identifier: "action.undo",
               isEnabled: viewModel.canUndo) { viewModel.undo() }
    }

    private var redoAction: some View {
        action(symbol: "arrow.uturn.forward", labelKey: "action.redo", identifier: "action.redo",
               isEnabled: viewModel.canRedo) { viewModel.redo() }
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
            .frame(maxWidth: .infinity, minHeight: LightlySize.minimumTapTarget + LightlySpacing.xxs)
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

/// The primary action, always in the top bar: a filled capsule, the one solid control on screen.
struct SaveCopyButton: View {
    let viewModel: LUTEditorViewModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button { viewModel.saveCopy() } label: {
            HStack(spacing: LightlySpacing.xxs) {
                if viewModel.saveStatus == .saving {
                    ProgressView().tint(LightlyColor.background(colorScheme))
                } else {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text("action.saveCopy", bundle: .main)
                    .font(LightlyTypography.actionPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(LightlyColor.background(colorScheme))
            .padding(.horizontal, LightlySpacing.m)
            .frame(minHeight: LightlySize.minimumTapTarget)
            .background(Capsule().fill(LightlyColor.textPrimary(colorScheme)))
            .overlay(Capsule().strokeBorder(LightlyColor.controlBoundary(colorScheme), lineWidth: 1.5))
            .layoutAnchor("editor.control.action.saveCopy")
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canSaveCopy)
        .opacity(viewModel.canSaveCopy ? 1 : 0.4)
        .accessibilityIdentifier("action.saveCopy")
    }
}

/// Shown instead of the Look controls when Auto genuinely failed: Retry, or Continue without
/// Auto. Never shown for "no model in this build", where a retry could not help.
struct AutoFailureRow: View {
    let viewModel: LUTEditorViewModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: LightlySpacing.s) {
            Text("editor.auto.failed.title", bundle: .main)
                .font(LightlyTypography.rowSubtitle)
                .foregroundStyle(LightlyColor.textPrimary(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: LightlySpacing.xs) {
                button("action.retry", identifier: "action.retryAuto") { viewModel.retryAuto() }
                button("action.continueWithoutAuto", identifier: "action.continueWithoutAuto") { viewModel.continueWithoutAuto() }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor.autoFailed")
    }

    private func button(_ key: LocalizedStringKey, identifier: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(key, bundle: .main)
                .font(LightlyTypography.rowSubtitle.weight(.semibold))
                .foregroundStyle(LightlyColor.textPrimary(colorScheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, LightlySpacing.s)
                .frame(maxWidth: .infinity, minHeight: LightlySize.minimumTapTarget)
                .controlChrome(Capsule(), onPlainBackground: true, colorScheme: colorScheme)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// Compact notices. They state limits plainly — a missing Auto model must never look like an
/// enhanced photo, approximate Looks must never look like finished conversions, and a saved Look
/// that is unavailable or changed must never be silently replaced — in one short line each, so
/// they do not push the photo off screen. The Save copy outcome is shown here too.
struct EditorNotices: View {
    let viewModel: LUTEditorViewModel
    /// Inside the panel the panel already provides the margins.
    var isInsidePanel = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: LightlySpacing.xxs) {
            SaveCopyStatusLine(status: viewModel.saveStatus)
            switch viewModel.autoNotice {
            case .notInBuild:
                notice(symbol: "wand.and.stars.inverse", identifier: "editor.autoUnavailableNotice") {
                    Text("editor.auto.unavailable.notice", bundle: .main)
                }
            case .failed:
                notice(symbol: "wand.and.stars.inverse", identifier: "editor.autoFailedNotice") {
                    Text("editor.auto.failed.notice", bundle: .main)
                }
            case nil:
                EmptyView()
            }
            switch viewModel.lookNotice {
            case .unavailable:
                notice(symbol: "exclamationmark.triangle", identifier: "editor.lookUnavailableNotice") {
                    Text("editor.looks.unavailable.notice", bundle: .main)
                }
            case .changed(let lookName):
                lookChangedNotice(lookName)
            case nil:
                EmptyView()
            }
            if viewModel.showsApproximateLooksNotice {
                notice(symbol: "info.circle", identifier: "editor.approximateLooksNotice") {
                    Text("editor.looks.approximate.notice", bundle: .main)
                }
            }
        }
        .padding(.horizontal, isInsidePanel ? 0 : LightlySpacing.m)
        .padding(.top, isInsidePanel ? 0 : LightlySpacing.xxs)
    }

    /// The one notice with an action: "Use current version" is a new, undoable step.
    private func lookChangedNotice(_ lookName: String) -> some View {
        HStack(alignment: .center, spacing: LightlySpacing.xs) {
            notice(symbol: "arrow.triangle.2.circlepath", identifier: "editor.lookChangedNotice") {
                Text(verbatim: String(format: String(localized: "editor.looks.changed.notice"), lookName))
            }
            Button { viewModel.useCurrentLookVersion() } label: {
                Text("action.useCurrentVersion", bundle: .main)
                    .font(LightlyTypography.caption.weight(.semibold))
                    .foregroundStyle(LightlyColor.textPrimary(colorScheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, LightlySpacing.xs)
                    .frame(minHeight: LightlySize.minimumTapTarget)
                    .controlChrome(Capsule(), onPlainBackground: true, colorScheme: colorScheme)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canUseCurrentLookVersion)
            .accessibilityIdentifier("action.useCurrentVersion")
        }
    }

    private func notice(symbol: String, identifier: String, @ViewBuilder message: () -> Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: LightlySpacing.xs) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
            message()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(LightlyTypography.caption)
        .foregroundStyle(LightlyColor.textPrimary(colorScheme))
        .padding(.horizontal, LightlySpacing.s)
        .padding(.vertical, LightlySpacing.xxs + 2)
        .background(
            RoundedRectangle(cornerRadius: LightlyRadius.row, style: .continuous)
                .fill(LightlyColor.surfaceElevated(colorScheme))
        )
        .accessibilityElement(children: .combine)
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
                EqualWidthRowLayout(columns: perRow, spacing: LightlySpacing.xs) {
                    ForEach(rows[rowIndex]) { item in cell(item) }
                }
            }
        }
    }
}

/// One row of `columns` equal cells (a short row keeps the full rows' cell width).
///
/// Its ideal width is the widest cell's ideal width times the column count, so `ViewThatFits`
/// only accepts an arrangement in which *every* label fits its equal share. v3 differs: an
/// `HStack` reported the sum of the cells' widths, so five chips "fitted" a 320 pt side panel
/// while "Natural" was truncated to "Nat…".
struct EqualWidthRowLayout: Layout {
    let columns: Int
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let columns = max(columns, 1)
        let gaps = spacing * CGFloat(columns - 1)
        let cellWidth: CGFloat
        if let width = proposal.width {
            cellWidth = max((width - gaps) / CGFloat(columns), 0)
        } else {
            cellWidth = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        }
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height }.max() ?? 0
        return CGSize(width: proposal.width ?? cellWidth * CGFloat(columns) + gaps, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = max(columns, 1)
        let cellWidth = max((bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns), 0)
        for (index, subview) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index) * (cellWidth + spacing)
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: cellWidth, height: bounds.height))
        }
    }
}
