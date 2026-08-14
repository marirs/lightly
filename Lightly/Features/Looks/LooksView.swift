import SwiftUI

/// The Looks screen (spec §7).
///
/// Presented over the editor so the photograph stays visible: the point of a
/// Look is what it does to *this* picture, which the user must be able to see
/// while choosing.
struct LooksView: View {
    @State private var viewModel: LooksViewModel

    /// Called continuously as the preview changes, so the editor behind can
    /// render the Look live.
    let onPreviewChanged: (LightlyPreset?, Double) -> Void
    /// Called when the user commits a Look.
    let onApply: (LightlyPreset, Double) -> Void
    /// Called when the screen closes without applying.
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        viewModel: LooksViewModel,
        onPreviewChanged: @escaping (LightlyPreset?, Double) -> Void,
        onApply: @escaping (LightlyPreset, Double) -> Void,
        onClose: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onPreviewChanged = onPreviewChanged
        self.onApply = onApply
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            categoryTabs

            if viewModel.category == .recommended {
                recommendationDisclaimer
            }

            thumbnailGrid

            if viewModel.previewedPreset != nil {
                intensityControl
                applyRow
            }
        }
        .background(LightlyColor.surface(colorScheme))
        .task { viewModel.load(category: .recommended) }
        .onDisappear { viewModel.cancelThumbnailWork() }
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
            Text("paywall.looks.message", bundle: .main)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("looks.title", bundle: .main)
                .font(LightlyTypography.title)
                .foregroundStyle(LightlyColor.textPrimary(colorScheme))

            Spacer()

            Button {
                viewModel.clearPreview()
                onPreviewChanged(nil, 1)
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LightlyColor.textPrimary(colorScheme))
                    .frame(
                        width: LightlySize.minimumTapTarget,
                        height: LightlySize.minimumTapTarget
                    )
            }
            .accessibilityLabel(Text("looks.close.accessibility", bundle: .main))
        }
        .padding(.horizontal, LightlySpacing.m)
        .padding(.top, LightlySpacing.s)
    }

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LightlySpacing.l) {
                ForEach(PresetCategory.allCases) { category in
                    Button {
                        viewModel.load(category: category)
                    } label: {
                        Text(LocalizedStringKey(category.localizationKey), bundle: .main)
                            .font(LightlyTypography.rowSubtitle)
                            .foregroundStyle(
                                category == viewModel.category
                                    ? LightlyColor.textPrimary(colorScheme)
                                    : LightlyColor.textTertiary(colorScheme)
                            )
                            .overlay(alignment: .bottom) {
                                if category == viewModel.category {
                                    Rectangle()
                                        .fill(LightlyColor.textPrimary(colorScheme))
                                        .frame(height: 1.5)
                                        .offset(y: 6)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, LightlySpacing.m)
            .padding(.vertical, LightlySpacing.s)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// States plainly that the Recommended set is not personalised.
    ///
    /// Spec §7 requires Recommended to be scene-aware; classification is
    /// Phase 4. Until then the interface must not imply a judgement it has not
    /// made — calling a fixed list "recommended for you" would be a small lie
    /// that the product's whole privacy-and-honesty posture cannot afford.
    @ViewBuilder
    private var recommendationDisclaimer: some View {
        if !viewModel.recommendationsAreSceneAware {
            Text("looks.recommended.notTailored", bundle: .main)
                .font(LightlyTypography.caption)
                .foregroundStyle(LightlyColor.textTertiary(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, LightlySpacing.m)
                .padding(.bottom, LightlySpacing.xs)
        }
    }

    // MARK: - Grid

    /// Fewer, larger cells at accessibility sizes so names stay legible.
    private var columnCount: Int {
        dynamicTypeSize.isAccessibilitySize ? 2 : 3
    }

    private var thumbnailGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: LightlySpacing.s),
                    count: columnCount
                ),
                spacing: LightlySpacing.s
            ) {
                ForEach(viewModel.presets) { preset in
                    lookCell(preset)
                }
            }
            .padding(.horizontal, LightlySpacing.m)
            .padding(.bottom, LightlySpacing.m)
        }
    }

    private func lookCell(_ preset: LightlyPreset) -> some View {
        let isSelected = viewModel.previewedLookID == preset.id

        return Button {
            viewModel.preview(preset)
            onPreviewChanged(preset, viewModel.intensity)
        } label: {
            VStack(spacing: LightlySpacing.xxs) {
                thumbnail(for: preset)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(
                        RoundedRectangle(cornerRadius: LightlyRadius.row, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: LightlyRadius.row, style: .continuous)
                            .strokeBorder(
                                isSelected
                                    ? LightlyColor.accentWarm(colorScheme)
                                    : .clear,
                                lineWidth: 2
                            )
                    }

                // No lock badge for Pro Looks (spec §0.3). The grid gives no
                // hint of the entitlement boundary; the user explores freely
                // and meets it only when applying.
                Text(preset.name)
                    .font(LightlyTypography.caption)
                    .foregroundStyle(LightlyColor.textPrimary(colorScheme))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("look.\(preset.id)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func thumbnail(for preset: LightlyPreset) -> some View {
        switch viewModel.thumbnails[preset.id] ?? .loading {
        case .ready(let image):
            Image(decorative: image, scale: 1)
                .resizable()
                // Matches the editor: the whole composition stays visible in
                // preview, so a Look is judged on the same framing it will be
                // applied to.
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LightlyColor.surfaceElevated(colorScheme))

        case .loading:
            RoundedRectangle(cornerRadius: LightlyRadius.row, style: .continuous)
                .fill(LightlyColor.surfaceElevated(colorScheme))

        case .failed:
            // A contained failure: this cell is unavailable, the rest work.
            RoundedRectangle(cornerRadius: LightlyRadius.row, style: .continuous)
                .fill(LightlyColor.surfaceElevated(colorScheme))
                .overlay {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(LightlyColor.textTertiary(colorScheme))
                }
                .accessibilityLabel(Text("looks.thumbnail.failed", bundle: .main))
        }
    }

    // MARK: - Intensity and apply

    private var intensityControl: some View {
        HStack(spacing: LightlySpacing.m) {
            Text("looks.intensity", bundle: .main)
                .font(LightlyTypography.rowSubtitle)
                .foregroundStyle(LightlyColor.textSecondary(colorScheme))

            Slider(
                value: .init(
                    get: { viewModel.intensity },
                    set: { value in
                        viewModel.setIntensity(value)
                        onPreviewChanged(viewModel.previewedPreset, value)
                    }
                ),
                in: 0...1
            )
            .accessibilityIdentifier("looks.intensity")

            Text("\(Int(viewModel.intensity * 100))")
                .font(LightlyTypography.rowSubtitle)
                .foregroundStyle(LightlyColor.textPrimary(colorScheme))
                .monospacedDigit()
                .frame(minWidth: 34, alignment: .trailing)
        }
        .padding(.horizontal, LightlySpacing.m)
        .padding(.vertical, LightlySpacing.s)
    }

    private var applyRow: some View {
        Button {
            // The entitlement checkpoint. Everything before this was free.
            if let result = viewModel.confirmApplication() {
                onApply(result.preset, result.intensity)
            }
        } label: {
            Text("looks.apply", bundle: .main)
                .font(LightlyTypography.actionPrimary)
                .foregroundStyle(LightlyColor.textPrimary(colorScheme))
                .frame(maxWidth: .infinity)
                .padding(.vertical, LightlySpacing.s + 2)
                .background(
                    Capsule().fill(LightlyColor.surfaceElevated(colorScheme))
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("looks.apply")
        .padding(.horizontal, LightlySpacing.m)
        .padding(.bottom, LightlySpacing.m)
    }
}
