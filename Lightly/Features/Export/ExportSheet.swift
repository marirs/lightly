import SwiftUI

/// The export sheet (spec §14).
///
/// Every option is selectable regardless of entitlement; Maximum quality is not
/// badged, dimmed, or locked. The boundary appears only when the user commits
/// (spec §0.3, §26.2).
struct ExportSheet: View {
    @State private var viewModel: ExportViewModel
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// See the layout comment in `body`.
    private var actionsFlowWithContent: Bool { dynamicTypeSize.isAccessibilitySize }

    /// URL handed to the system share sheet once encoding finishes.
    @State private var shareURL: URL?

    init(viewModel: ExportViewModel, onClose: @escaping () -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, LightlySpacing.m)
                // Headroom so the title clears the sheet's drag indicator,
                // which is drawn over the content rather than above it.
                .padding(.top, LightlySpacing.m)

            // The options always scroll, so nothing is pushed off-screen.
            // At standard sizes the actions stay pinned below them. At
            // accessibility sizes two 76–91 pt action buttons would leave the
            // options a sliver of the sheet, with the Metadata section
            // running underneath the actions; there the actions flow after
            // the options instead, so every control is reachable by scrolling
            // and nothing overlaps.
            ScrollView {
                VStack(alignment: .leading, spacing: LightlySpacing.l) {
                    formatSection
                    if viewModel.settings.format.isLossy {
                        qualitySection
                    }
                    metadataSection
                    if actionsFlowWithContent {
                        actions
                    }
                }
                .padding(.horizontal, LightlySpacing.m)
                .padding(.vertical, LightlySpacing.l)
            }

            if !actionsFlowWithContent {
                actions
                    .padding(.horizontal, LightlySpacing.m)
                    .padding(.bottom, LightlySpacing.m)
            }
        }
        .background(LightlyColor.surface(colorScheme))
        .alert(
            Text("paywall.title", bundle: .main),
            isPresented: .init(
                get: { viewModel.paywallPrompt != nil },
                set: { if !$0 { viewModel.dismissPaywall() } }
            )
        ) {
            Button(String(localized: "paywall.action.notNow"), role: .cancel) {
                viewModel.dismissPaywall()
            }
        } message: {
            Text("paywall.export.message", bundle: .main)
        }
        .alert(
            Text("export.saved.title", bundle: .main),
            isPresented: .init(
                get: { viewModel.outcome == .savedToLibrary },
                set: { if !$0 { viewModel.dismissOutcome() } }
            )
        ) {
            Button(String(localized: "export.saved.done")) {
                viewModel.dismissOutcome()
                onClose()
            }
        } message: {
            Text("export.saved.message", bundle: .main)
        }
        .alert(
            Text("error.title", bundle: .main),
            isPresented: .init(
                get: { if case .failed = viewModel.outcome { true } else { false } },
                set: { if !$0 { viewModel.dismissOutcome() } }
            )
        ) {
            Button(String(localized: "error.action.dismiss")) { viewModel.dismissOutcome() }
        } message: {
            if case .failed(let error) = viewModel.outcome {
                Text(error.localizedMessageKey, bundle: .main)
            }
        }
        .onChange(of: viewModel.outcome) { _, outcome in
            if case .readyToShare(let url) = outcome { shareURL = url }
        }
        .sheet(item: $shareURL) { url in
            ShareSheet(url: url)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("export.title", bundle: .main)
                .font(LightlyTypography.title)
                .foregroundStyle(LightlyColor.textPrimary(colorScheme))

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LightlyColor.textPrimary(colorScheme))
                    .frame(
                        width: LightlySize.minimumTapTarget,
                        height: LightlySize.minimumTapTarget
                    )
            }
            .accessibilityLabel(Text("export.close.accessibility", bundle: .main))
        }
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: LightlySpacing.xs) {
            sectionLabel("export.section.format")

            Picker(
                selection: .init(
                    get: { viewModel.settings.format },
                    set: { viewModel.select(format: $0) }
                )
            ) {
                ForEach(ExportFormat.allCases) { format in
                    Text(LocalizedStringKey(format.localizationKey), bundle: .main)
                        .tag(format)
                }
            } label: {
                Text("export.section.format", bundle: .main)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("export.format")
        }
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: LightlySpacing.xs) {
            sectionLabel("export.section.quality")

            Picker(
                selection: .init(
                    get: { viewModel.settings.quality },
                    set: { viewModel.select(quality: $0) }
                )
            ) {
                ForEach(ExportQuality.allCases) { quality in
                    // No "Pro" badge: the option looks and behaves identically
                    // until the moment of export.
                    Text(LocalizedStringKey(quality.localizationKey), bundle: .main)
                        .tag(quality)
                }
            } label: {
                Text("export.section.quality", bundle: .main)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("export.quality")
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: LightlySpacing.s) {
            sectionLabel("export.section.metadata")
                .layoutAnchor("export.metadataHeader")

            Toggle(isOn: .init(
                get: { viewModel.settings.preservesMetadata },
                set: { viewModel.setPreservesMetadata($0) }
            )) {
                Text("export.metadata.preserve", bundle: .main)
                    .font(LightlyTypography.rowSubtitle)
                    // Wrap rather than truncate: a setting the user cannot
                    // finish reading is a setting they cannot judge.
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("export.preserveMetadata")
            .layoutAnchor("export.preserveMetadata")

            Toggle(isOn: .init(
                get: { viewModel.settings.preservesLocation },
                set: { viewModel.setPreservesLocation($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("export.metadata.location", bundle: .main)
                        .font(LightlyTypography.rowSubtitle)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("export.metadata.location.detail", bundle: .main)
                        .font(LightlyTypography.caption)
                        .foregroundStyle(LightlyColor.textTertiary(colorScheme))
                        // This line is the whole justification for the default;
                        // truncating it would hide the reasoning.
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!viewModel.settings.preservesMetadata)
            .accessibilityIdentifier("export.preserveLocation")
            .layoutAnchor("export.preserveLocation")
        }
    }

    private var actions: some View {
        VStack(spacing: LightlySpacing.s) {
            Button {
                viewModel.export(to: .photoLibrary)
            } label: {
                actionLabel("export.action.save", isProminent: true)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isExporting)
            .accessibilityIdentifier("export.save")
            .layoutAnchor("export.save")

            Button {
                viewModel.export(to: .share)
            } label: {
                actionLabel("export.action.share", isProminent: false)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isExporting)
            .accessibilityIdentifier("export.share")
            .layoutAnchor("export.share")
        }
    }

    // MARK: - Components

    private func sectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key, bundle: .main)
            .font(LightlyTypography.caption)
            .foregroundStyle(LightlyColor.textTertiary(colorScheme))
            .textCase(.uppercase)
    }

    private func actionLabel(_ key: LocalizedStringKey, isProminent: Bool) -> some View {
        HStack(spacing: LightlySpacing.xs) {
            if viewModel.isExporting && isProminent {
                ProgressView().controlSize(.small)
            }
            Text(key, bundle: .main)
                .font(LightlyTypography.actionPrimary)
        }
        .foregroundStyle(LightlyColor.textPrimary(colorScheme))
        .frame(maxWidth: .infinity)
        .padding(.vertical, LightlySpacing.s + 2)
        .background(
            Capsule().fill(
                isProminent
                    ? LightlyColor.surfaceElevated(colorScheme)
                    : Color.clear
            )
        )
        .overlay {
            if !isProminent {
                Capsule().strokeBorder(
                    LightlyColor.textTertiary(colorScheme).opacity(0.4),
                    lineWidth: 1
                )
            }
        }
    }
}

/// Presents the system share sheet.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Lets a `URL` drive `sheet(item:)`.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
