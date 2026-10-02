import SwiftUI

/// How the editor arranges the photo and its controls for the space it has.
///
/// Photo first, always: on a narrow screen the controls sit below the photo; when the screen is
/// wide enough (iPhone landscape, iPad, wide split view) they move into a side panel so the photo
/// keeps the full height. Pure geometry, so it is unit-tested without a window.
struct EditorLayoutPolicy: Equatable {
    enum Arrangement: Equatable {
        /// Controls below the photo; `panelMaximumHeight` caps the (scrolling) panel.
        case stacked(panelMaximumHeight: CGFloat, photoMinimumHeight: CGFloat)
        /// Controls in a side panel of `panelWidth` to the right of the photo.
        case sidePanel(panelWidth: CGFloat)
    }

    /// Side panel width range (agreed UX: 320–380 pt).
    static let sidePanelWidthRange: ClosedRange<CGFloat> = 320...380
    /// The photo column must keep at least this width beside the panel, or the panel is not used.
    static let minimumPhotoWidthBesidePanel: CGFloat = 320
    /// Wide enough for a side panel even in portrait (iPad portrait, wide split view).
    static let sidePanelMinimumWidth: CGFloat = 700
    /// Spec D4: the stacked panel takes ≤ 35% of the height at standard text sizes.
    static let standardPanelShare: CGFloat = 0.35
    /// At accessibility sizes the panel scrolls within 45%, so with the top bar the photo keeps
    /// ≥ 40% of the height on a phone in portrait (agreed UX).
    static let accessibilityPanelShare: CGFloat = 0.45
    static let photoMinimumShare: CGFloat = 0.40

    static func arrangement(for size: CGSize, isAccessibilitySize: Bool) -> Arrangement {
        let panelWidth = min(max(size.width * 0.36, sidePanelWidthRange.lowerBound), sidePanelWidthRange.upperBound)
        let isWide = size.width > size.height || size.width >= sidePanelMinimumWidth
        if isWide, size.width - panelWidth >= minimumPhotoWidthBesidePanel {
            return .sidePanel(panelWidth: panelWidth)
        }
        let share = isAccessibilitySize ? accessibilityPanelShare : standardPanelShare
        return .stacked(panelMaximumHeight: size.height * share, photoMinimumHeight: size.height * photoMinimumShare)
    }
}

/// The editor screen (spec §2 primary flow, D4).
///
/// Top: Back and a prominent Save copy. The photograph is never covered by a control; press and
/// hold it (or turn on Compare) to see the original, marked by an "Original" badge. Compact
/// notices say what this build cannot do (Auto unavailable, approximate Looks, a saved Look that is
/// unavailable or changed). The controls panel holds the Look categories, the stepped preset
/// slider, the optional Strength and Undo / Redo / Reset / Compare; it sits below the photo on a
/// narrow screen and beside it when there is room (`EditorLayoutPolicy`). When its content is
/// taller than its share (large text), the panel scrolls instead of growing over the photo.
struct EditorView: View {
    @State private var viewModel: LUTEditorViewModel
    /// Called when the user leaves the editor.
    let onBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(viewModel: LUTEditorViewModel, onBack: @escaping () -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.onBack = onBack
    }

    /// Notices above the photo are capped so they cannot squeeze it; beyond that they scroll.
    private static let noticesHeightShare: CGFloat = 0.18

    var body: some View {
        GeometryReader { geometry in
            switch EditorLayoutPolicy.arrangement(for: geometry.size, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize) {
            case .stacked(let panelMaximumHeight, let photoMinimumHeight):
                stacked(size: geometry.size, panelMaximumHeight: panelMaximumHeight, photoMinimumHeight: photoMinimumHeight)
            case .sidePanel(let panelWidth):
                sideBySide(panelWidth: panelWidth)
            }
        }
        .background(LightlyColor.background(colorScheme).ignoresSafeArea())
        .onChange(of: viewModel.saveStatus) { _, status in
            announce(status)
        }
    }

    // MARK: - Arrangements

    private func stacked(size: CGSize, panelMaximumHeight: CGFloat, photoMinimumHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            topBar
            // At accessibility sizes the notices wrap to many lines; they move into the
            // scrolling panel rather than taking the photo's minimum height.
            if !dynamicTypeSize.isAccessibilitySize {
                EditorNotices(viewModel: viewModel)
                    .cappedScrollable(maxHeight: size.height * Self.noticesHeightShare)
            }
            photograph
                .frame(maxWidth: .infinity, minHeight: photoMinimumHeight, maxHeight: .infinity)
                .layoutAnchor("editor.photoArea")
                .padding(.vertical, LightlySpacing.xs)
            controlsPanel(includesNotices: dynamicTypeSize.isAccessibilitySize)
                .cappedScrollable(maxHeight: panelMaximumHeight)
                .layoutAnchor("editor.bottomControls")
                .layoutAnchor("editor.controlsPanel")
        }
    }

    private func sideBySide(panelWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                photograph
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutAnchor("editor.photoArea")
                    .padding(LightlySpacing.xs)
            }
            Rectangle()
                .fill(LightlyColor.line(colorScheme))
                .frame(width: 1)
                .accessibilityHidden(true)
            ScrollView(.vertical) {
                controlsPanel(includesNotices: true)
                    .padding(.top, LightlySpacing.xs)
            }
            .frame(width: panelWidth)
            .layoutAnchor("editor.sidePanel")
            .layoutAnchor("editor.controlsPanel")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(LightlyColor.textPrimary(colorScheme))
                    .frame(width: LightlySize.minimumTapTarget, height: LightlySize.minimumTapTarget)
                    .controlChrome(Circle(), onPlainBackground: true, colorScheme: colorScheme)
                    .layoutAnchor("editor.control.back")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("editor.back.accessibility", bundle: .main))
            .accessibilityIdentifier("editor.back")
            Spacer(minLength: LightlySpacing.s)
            SaveCopyButton(viewModel: viewModel)
        }
        .padding(.horizontal, LightlySpacing.m)
        .padding(.top, LightlySpacing.xs)
    }

    // MARK: - Photograph

    /// Press and hold shows the original (spec §2 step 6). The Compare toggle in the panel is the
    /// alternative for people who cannot hold. While the original shows, a badge says so: the
    /// edit and the original can look alike, and the state must never be guessed.
    private var photograph: some View {
        Image(decorative: viewModel.displayedImage, scale: 1)
            .resizable()
            .scaledToFit()
            .overlay(alignment: .topLeading) {
                if viewModel.isShowingOriginal { originalBadge }
            }
            .layoutAnchor("editor.photo")
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in viewModel.beginCompareHold() }
                    .onEnded { _ in viewModel.endCompareHold() }
            )
            .accessibilityElement()
            .accessibilityLabel(
                viewModel.isShowingOriginal
                    ? Text("editor.photo.original.accessibility", bundle: .main)
                    : Text("editor.photo.accessibility", bundle: .main)
            )
            .accessibilityValue(photoAccessibilityValue)
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("editor.photo")
    }

    /// Solid, outlined and inside the photo's corner, so it reads on any image.
    private var originalBadge: some View {
        Text("editor.photo.originalBadge", bundle: .main)
            .font(LightlyTypography.caption.weight(.semibold))
            .foregroundStyle(LightlyColor.textPrimary(colorScheme))
            .padding(.horizontal, LightlySpacing.xs)
            .padding(.vertical, LightlySpacing.xxs)
            .controlChrome(Capsule(), onPlainBackground: true, colorScheme: colorScheme)
            .padding(LightlySpacing.xs)
            .layoutAnchor("editor.originalBadge")
            .accessibilityHidden(true)  // the photo's own label already says "original"
    }

    private var photoAccessibilityValue: Text {
        if viewModel.isShowingOriginal { return Text(verbatim: "") }
        if let look = viewModel.committedLook { return Text(verbatim: look.name) }
        return viewModel.isAutoUnavailable
            ? Text("editor.photo.autoUnavailable.accessibility", bundle: .main)
            : Text(verbatim: viewModel.noLookStopLabel)
    }

    // MARK: - Controls panel

    @ViewBuilder
    private func controlsPanel(includesNotices: Bool) -> some View {
        // Tight spacing: every point the panel saves goes to the photo (≥ 40% of the height).
        VStack(spacing: LightlySpacing.xs) {
            if includesNotices {
                EditorNotices(viewModel: viewModel, isInsidePanel: true)
            }
            switch viewModel.phase {
            case .developing:
                developingRow
            case .ready:
                LookControls(viewModel: viewModel)
                if viewModel.showsStrengthControl {
                    StrengthControl(viewModel: viewModel)
                }
                EditActions(viewModel: viewModel)
            case .autoFailed:
                AutoFailureRow(viewModel: viewModel)
            case .failed(let error):
                failureRow(error)
            }
        }
        .padding(.horizontal, LightlySpacing.m)
        .padding(.vertical, LightlySpacing.xs)
    }

    /// Subtle progress while Auto is prepared; the photo stays visible.
    // DEFERRED: the spec's Cancel action while developing. Auto is
    // unavailable in this build, so developing finishes immediately.
    private var developingRow: some View {
        HStack(spacing: LightlySpacing.xs) {
            ProgressView()
            Text("develop.progress.title", bundle: .main)
                .font(LightlyTypography.rowSubtitle)
                .foregroundStyle(LightlyColor.textPrimary(colorScheme))
        }
        .frame(maxWidth: .infinity, minHeight: LightlySize.minimumTapTarget)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("editor.developing")
    }

    private func failureRow(_ error: LightlyError) -> some View {
        VStack(spacing: LightlySpacing.s) {
            Text(error.localizedMessageKey, bundle: .main)
                .font(LightlyTypography.rowSubtitle)
                .foregroundStyle(LightlyColor.textPrimary(colorScheme))
                .multilineTextAlignment(.center)
            Button(action: onBack) {
                Text("editor.chooseAnother", bundle: .main)
                    .font(LightlyTypography.actionPrimary)
                    .foregroundStyle(LightlyColor.textPrimary(colorScheme))
                    .padding(.horizontal, LightlySpacing.l)
                    .frame(minHeight: LightlySize.minimumTapTarget)
                    .controlChrome(Capsule(), onPlainBackground: true, colorScheme: colorScheme)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("editor.failed")
    }

    /// VoiceOver users get Save copy's outcome without hunting for it.
    private func announce(_ status: SaveCopyStatus) {
        let key: String.LocalizationValue
        switch status {
        case .idle: return
        case .saving: key = "editor.save.saving"
        case .saved: key = "editor.save.saved"
        // The specific reason is on screen in the status line; the
        // announcement only has to say that saving did not happen.
        case .failed: key = "editor.save.failed"
        }
        AccessibilityNotification.Announcement(String(localized: key)).post()
    }
}

extension View {
    /// Shows the content at its natural height up to `maxHeight`, and scrolls it beyond that
    /// instead of letting it push other content off screen or overlap it.
    ///
    /// v3 differs: this used `ViewThatFits { content; ScrollView { content } }`. Inside a stack
    /// that also holds a flexible photo, the stack's flexibility probe made it pick the scroll view
    /// and fill the whole cap (notices took 147 pt for 60 pt of text), shrinking the photo. A
    /// layout that measures the content's ideal height is deterministic.
    func cappedScrollable(maxHeight: CGFloat) -> some View {
        CappedHeightLayout(maxHeight: maxHeight) {
            ScrollView(.vertical) { self }
                .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// Sizes its single subview (a vertical scroll view) to the subview's ideal height for the
/// proposed width, capped at `maxHeight`. A scroll view's ideal height is its content's, so short
/// content is shown whole and does not scroll; taller content scrolls within the cap.
struct CappedHeightLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
