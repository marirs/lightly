import SwiftUI

/// The source-selection sheet revealed by the launch swipe (spec §4.2).
///
/// Offers exactly two paths, both of which hand off to Apple's own interfaces.
/// There is no custom gallery here and none is planned for V1 (spec §0.1).
struct SourceSelectionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    /// Sheet heights. 280 pt fits the content at standard text sizes; at
    /// accessibility sizes the content is several times taller, so the
    /// sheet opens large (and still scrolls) instead of clipping.
    static func detents(for size: DynamicTypeSize) -> Set<PresentationDetent> {
        size.isAccessibilitySize ? [.large] : [.height(280)]
    }

    var body: some View {
        // Scrolls so that at accessibility text sizes the rows keep their
        // natural height. Without it the fixed sheet height compressed the
        // rows and their wrapped text spilled into the neighbouring row.
        ScrollView {
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
            }
            .padding(.horizontal, LightlySpacing.l)
            .padding(.top, LightlySpacing.l)
            .padding(.bottom, LightlySpacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
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
                // Wrap, never truncate: this line is the privacy promise.
                .fixedSize(horizontal: false, vertical: true)
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
                        .layoutAnchor("source.\(source).title")

                    Text(subtitle, bundle: .main)
                        .font(LightlyTypography.rowSubtitle)
                        .foregroundStyle(LightlyColor.textSecondary(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutAnchor("source.\(source).subtitle")
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LightlyColor.textTertiary(colorScheme))
            }
            // Vertical padding `xs`, not `m`: at standard sizes the whole
            // sheet must fit the 280 pt detent at its natural height. The
            // old `m` padding only fitted because the rows were being
            // compressed below their content, which at large text made
            // the rows overlap.
            .padding(.horizontal, LightlySpacing.m)
            .padding(.vertical, LightlySpacing.xs)
            .frame(minHeight: LightlySize.minimumTapTarget)
            .background(
                RoundedRectangle(cornerRadius: LightlyRadius.row, style: .continuous)
                    .fill(LightlyColor.surfaceElevated(colorScheme))
            )
            .layoutAnchor("source.\(source).row")
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
