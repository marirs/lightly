import SwiftUI

/// The source-selection sheet revealed by the launch swipe (spec §4.2).
///
/// Offers exactly two paths, both of which hand off to Apple's own interfaces.
/// There is no custom gallery here and none is planned for V1 (spec §0.1).
struct SourceSelectionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: LightlySpacing.l) {
            header

            VStack(spacing: LightlySpacing.s) {
                sourceRow(
                    .camera,
                    icon: "camera",
                    title: "source.camera.title",
                    subtitle: "source.camera.subtitle"
                )
                sourceRow(
                    .photoLibrary,
                    icon: "photo.on.rectangle",
                    title: "source.library.title",
                    subtitle: "source.library.subtitle"
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, LightlySpacing.l)
        .padding(.top, LightlySpacing.xl)
        .background(LightlyColor.surface(colorScheme))
    }

    private var header: some View {
        VStack(spacing: LightlySpacing.xs) {
            Text("source.title", bundle: .main)
                .font(LightlyTypography.title)
                .foregroundStyle(LightlyColor.textPrimary(colorScheme))

            // Spec §0.5 forbids absolute on-device claims anywhere in the
            // product. The v1.0 mockup copy here read "Everything stays on your
            // device." — corrected to the canonical qualified wording, because
            // opt-in cloud features (§29) make the absolute form untrue.
            Text("source.privacy.subtitle", bundle: .main)
                .font(LightlyTypography.subtitle)
                .foregroundStyle(LightlyColor.textSecondary(colorScheme))
                .multilineTextAlignment(.center)
        }
    }

    private func sourceRow(
        _ source: PhotoSource,
        icon: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey
    ) -> some View {
        Button {
            appState.selectSource(source)
        } label: {
            HStack(spacing: LightlySpacing.m) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .light))
                    .frame(width: LightlySize.rowIcon, height: LightlySize.rowIcon)
                    .foregroundStyle(LightlyColor.textPrimary(colorScheme))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title, bundle: .main)
                        .font(LightlyTypography.rowTitle)
                        .foregroundStyle(LightlyColor.textPrimary(colorScheme))

                    Text(subtitle, bundle: .main)
                        .font(LightlyTypography.rowSubtitle)
                        .foregroundStyle(LightlyColor.textSecondary(colorScheme))
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LightlyColor.textTertiary(colorScheme))
            }
            .padding(LightlySpacing.m)
            .frame(minHeight: LightlySize.minimumTapTarget)
            .background(
                RoundedRectangle(cornerRadius: LightlyRadius.row, style: .continuous)
                    .fill(LightlyColor.surfaceElevated(colorScheme))
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Light") {
    SourceSelectionSheet()
        .environment(AppState(photoLoader: ImageIOPhotoLoader()))
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    SourceSelectionSheet()
        .environment(AppState(photoLoader: ImageIOPhotoLoader()))
        .preferredColorScheme(.dark)
}
