import SwiftUI

/// The editor screen (spec §2 primary flow, D4).
///
/// Top: Back and the notices the user must not miss (Auto unavailable,
/// approximate Looks, a saved Look that is unavailable). Middle: the photograph, which is never covered by a
/// control or sheet — press and hold it to see the original. Bottom: one
/// panel with the Look categories, the stepped slider and the edit actions,
/// capped to a fraction of the height so the photo stays the subject; when
/// the content is taller (large text), the panel scrolls instead of growing
/// over the photo.
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

    /// Spec D4: the bottom panel takes ≤ 35% of the height on compact
    /// screens. At accessibility sizes the same content needs far more room;
    /// half the height keeps the photo visible while the panel scrolls.
    private var panelHeightFraction: CGFloat { dynamicTypeSize.isAccessibilitySize ? 0.5 : 0.35 }

    /// Notices sit above the photo at standard sizes, capped so they cannot
    /// squeeze it. At accessibility sizes they wrap to many lines, so they
    /// move to the top of the scrolling bottom panel instead of being
    /// clipped in a second, separate scroll area.
    private var noticesHeightFraction: CGFloat { 0.14 }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                topBar
                if !dynamicTypeSize.isAccessibilitySize {
                    EditorNotices(viewModel: viewModel)
                        .cappedScrollable(maxHeight: geometry.size.height * noticesHeightFraction)
                }
                photograph
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, LightlySpacing.xs)
                bottomPanel
                    .cappedScrollable(maxHeight: geometry.size.height * panelHeightFraction)
                    .layoutAnchor("editor.bottomControls")
            }
        }
        .background(LightlyColor.background(colorScheme).ignoresSafeArea())
        .onChange(of: viewModel.saveStatus) { _, status in
            announce(status)
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
            Spacer()
        }
        .padding(.horizontal, LightlySpacing.m)
        .padding(.top, LightlySpacing.xs)
    }

    // MARK: - Photograph

    /// Press and hold shows the original (spec §2 step 6). The Compare
    /// toggle in the panel is the alternative for people who cannot hold.
    private var photograph: some View {
        Image(decorative: viewModel.displayedImage, scale: 1)
            .resizable()
            .scaledToFit()
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

    private var photoAccessibilityValue: Text {
        if viewModel.isShowingOriginal { return Text(verbatim: "") }
        if let look = viewModel.committedLook { return Text(verbatim: look.name) }
        return viewModel.isAutoUnavailable
            ? Text("editor.photo.autoUnavailable.accessibility", bundle: .main)
            : Text(verbatim: viewModel.noLookStopLabel)
    }

    // MARK: - Bottom panel

    @ViewBuilder
    private var bottomPanel: some View {
        VStack(spacing: LightlySpacing.s) {
            if dynamicTypeSize.isAccessibilitySize {
                EditorNotices(viewModel: viewModel, isInsideBottomPanel: true)
            }
            switch viewModel.phase {
            case .developing:
                developingRow
            case .ready:
                LookControls(viewModel: viewModel)
                EditActions(viewModel: viewModel)
                SaveCopyStatusLine(status: viewModel.saveStatus)
            case .failed(let error):
                failureRow(error)
            }
        }
        .padding(.horizontal, LightlySpacing.m)
        .padding(.vertical, LightlySpacing.s)
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
    /// Shows the content at its natural height up to `maxHeight`, and
    /// scrolls it beyond that instead of letting it push other content off
    /// screen or overlap it.
    func cappedScrollable(maxHeight: CGFloat) -> some View {
        ViewThatFits(in: .vertical) {
            self
            ScrollView(.vertical) { self }
        }
        .frame(maxHeight: maxHeight)
    }
}
