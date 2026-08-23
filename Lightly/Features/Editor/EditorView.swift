import SwiftUI

/// The editor shell (spec §4.3–§4.5).
///
/// One view renders all three phases, because they are the same screen with
/// different affordances — the photograph never moves or resizes between them,
/// which is what makes the transition feel calm rather than navigational.
struct EditorView: View {
    @State private var viewModel: EditorViewModel
    /// Called when the user leaves the editor.
    let onBack: () -> Void
    /// Builds the Looks view model on demand.
    ///
    /// A closure rather than an instance so thumbnail work starts when the
    /// screen opens, not when the editor appears.
    var makeLooksViewModel: (() -> LooksViewModel)?

    /// Builds the export view model using the current edit recipe.
    var makeExportViewModel: ((DevelopRecipe) -> ExportViewModel)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingLooks = false
    @State private var isShowingExport = false

    init(
        viewModel: EditorViewModel,
        onBack: @escaping () -> Void,
        makeLooksViewModel: (() -> LooksViewModel)? = nil,
        makeExportViewModel: ((DevelopRecipe) -> ExportViewModel)? = nil
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onBack = onBack
        self.makeLooksViewModel = makeLooksViewModel
        self.makeExportViewModel = makeExportViewModel
    }

    var body: some View {
        ZStack {
            LightlyColor.background(colorScheme)
                .ignoresSafeArea()

            photograph

            if viewModel.phase == .developing {
                DevelopingOverlay(
                    stages: viewModel.displayedStages,
                    completedStages: viewModel.completedStages
                )
                .transition(.opacity)
            }

            VStack(spacing: 0) {
                topControls
                Spacer()
                bottomControls
            }
        }
        .animation(LightlyMotion.surface, value: viewModel.phase)
        .sheet(isPresented: $isShowingLooks) {
            if let makeLooksViewModel {
                LooksView(
                    viewModel: makeLooksViewModel(),
                    onPreviewChanged: { preset, intensity in
                        viewModel.previewLook(preset, intensity: intensity)
                    },
                    onApply: { preset, intensity in
                        viewModel.applyLook(preset, intensity: intensity)
                        isShowingLooks = false
                    },
                    onClose: { isShowingLooks = false }
                )
                // A detent keeps the photograph visible behind the sheet, so a
                // Look is judged against the picture it is being applied to.
                .presentationDetents([.fraction(0.62), .large])
                .presentationCornerRadius(LightlyRadius.sheet)
                .presentationBackgroundInteraction(.enabled)
            }
        }
        .sheet(isPresented: $isShowingExport) {
            if let makeExportViewModel {
                // Built from the current composed recipe so export renders at
                // full resolution from the original photograph (spec §15.3).
                ExportSheet(
                    viewModel: makeExportViewModel(viewModel.composedRecipe),
                    onClose: { isShowingExport = false }
                )
                .presentationDetents([.medium, .large])
                .presentationCornerRadius(LightlyRadius.sheet)
            }
        }
        .onChange(of: isShowingLooks) { _, isPresented in
            // Abandoning the sheet must discard the transient preview and
            // restore exactly what history says — previewing has no lasting
            // consequence.
            if !isPresented { viewModel.previewLook(nil, intensity: 1) }
        }
        .alert(
            Text("error.title", bundle: .main),
            isPresented: .init(
                get: { viewModel.activeError != nil },
                set: { if !$0 { viewModel.dismissError() } }
            )
        ) {
            Button(String(localized: "error.action.dismiss")) { viewModel.dismissError() }
        } message: {
            if let error = viewModel.activeError {
                Text(error.localizedMessageKey, bundle: .main)
            }
        }
    }

    // MARK: - Photograph

    /// The photograph fills almost the entire screen (spec §4.3).
    private var photograph: some View {
        Image(decorative: viewModel.displayedImage, scale: 1)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .accessibilityLabel(
                viewModel.isShowingOriginal
                    ? Text("editor.photo.original.accessibility", bundle: .main)
                    : Text("editor.photo.accessibility", bundle: .main)
            )
    }

    // MARK: - Top controls

    private var topControls: some View {
        HStack {
            circularControl(symbol: "chevron.left", labelKey: "editor.back.accessibility") {
                onBack()
            }

            // Belt and braces. The real guarantee is at the composition root,
            // which refuses to compile a release build while the engine is a
            // placeholder; this makes the notice's absence from release
            // builds structural as well.
            #if DEBUG
            if viewModel.requiresDebugDisclosure {
                DebugProcessingNotice()
                    .padding(.leading, LightlySpacing.xs)
            }
            #endif

            Spacer()

            circularControl(symbol: "ellipsis", labelKey: "editor.more.accessibility") {
                // The More screen (spec §12) is a later milestone. No action is
                // wired rather than presenting an empty destination.
            }
        }
        .padding(.horizontal, LightlySpacing.m)
        .padding(.top, LightlySpacing.xs)
    }

    // MARK: - Bottom controls

    @ViewBuilder
    private var bottomControls: some View {
        switch viewModel.phase {
        case .readyToDevelop:
            PreDevelopActionBar(
                onCrop: {
                    // Crop is a later milestone in Phase 1.
                },
                onDevelop: { viewModel.develop() }
            )
            .padding(.bottom, LightlySpacing.l)

        case .developing:
            // The overlay owns this state; no actions are offered while work is
            // in flight.
            EmptyView()

        case .developed:
            VStack(spacing: LightlySpacing.m) {
                developedSecondaryRow
                ContextualActionBar(
                    tools: SceneKind.unclassified.toolbar,
                    onSelect: { tool in
                        // Only Looks exists so far; the rest are later
                        // milestones and deliberately do nothing rather than
                        // opening an empty screen.
                        if tool == .looks { isShowingLooks = true }
                    }
                )
            }
            .padding(.bottom, LightlySpacing.s)
        }
    }

    /// Crop on the left; Compare and Share on the right (spec §4.5).
    private var developedSecondaryRow: some View {
        HStack {
            circularControl(symbol: "crop", labelKey: "action.crop") {}

            Spacer()

            if viewModel.isCompareAvailable {
                compareControl
            }

            if viewModel.isShareAvailable {
                circularControl(symbol: "square.and.arrow.up", labelKey: "action.share") {
                    isShowingExport = true
                }
                .accessibilityIdentifier("action.share")
            }
        }
        .padding(.horizontal, LightlySpacing.m)
    }

    /// Press and hold to reveal the original; release to return (spec §4.5).
    ///
    /// A long-press gesture drives the hold behaviour, while `accessibilityAction`
    /// exposes the tap-to-toggle alternative for users who cannot hold.
    private var compareControl: some View {
        Image(systemName: "rectangle.righthalf.inset.filled")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(LightlyColor.textPrimary(colorScheme))
            .frame(
                width: LightlySize.minimumTapTarget,
                height: LightlySize.minimumTapTarget
            )
            .background(.regularMaterial, in: Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in viewModel.beginCompare() }
                    .onEnded { _ in viewModel.endCompare() }
            )
            .accessibilityIdentifier("action.compare")
            .accessibilityLabel(Text("action.compare.accessibility", bundle: .main))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { viewModel.toggleCompare() }
    }

    // MARK: - Shared control

    private func circularControl(
        symbol: String,
        labelKey: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(LightlyColor.textPrimary(colorScheme))
                .frame(
                    width: LightlySize.minimumTapTarget,
                    height: LightlySize.minimumTapTarget
                )
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(labelKey, bundle: .main))
    }
}
