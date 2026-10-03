import SwiftUI

/// Welcome (approved `welcomeHTML`): ⋮ More top right; the mark, "Lightly" and the tagline;
/// Choose a photo and Camera; the privacy line and the Privacy Policy link. No login, no
/// onboarding.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    /// The prototype keeps max(28, 6% of the screen height) below the Privacy Policy link,
    /// above the home-indicator inset.
    static func bottomSpace(forScreenHeight height: CGFloat) -> CGFloat {
        max(28, height * 0.06)
    }

    var body: some View {
        GeometryReader { geometry in
            let screenHeight = geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
            VStack(spacing: 0) {
                topBar
                FillingScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 24)
                        brand.layoutAnchor("welcome.brand")
                        Spacer(minLength: 32)
                        actions.layoutAnchor("welcome.actions")
                        privacyLine
                        privacyPolicyLink.layoutAnchor("welcome.privacyPolicy")
                        Color.clear.frame(height: Self.bottomSpace(forScreenHeight: screenHeight))
                    }
                }
            }
        }
        .background(ApprovedColor.background.resolved(colorScheme).ignoresSafeArea())
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ApprovedIconButton(
                icon: .more,
                accessibilityLabel: Text("more.accessibility", bundle: .main),
                identifier: "welcome.more",
                action: { appState.openMore() }
            )
        }
        .padding(.horizontal, ApprovedMetrics.headerHorizontalPadding)
        .frame(height: ApprovedMetrics.headerHeight)
    }

    private var brand: some View {
        VStack(spacing: 14) {
            BrandMark(size: 56, tint: ApprovedColor.ink.resolved(colorScheme), minimumStrokeWidth: 1.6)
            VStack(spacing: 14) {
                Text("brand.wordmark", bundle: .main)
                    .approvedText(34, weight: .semibold, trackingEm: -0.02)
                    .foregroundStyle(ApprovedColor.ink.resolved(colorScheme))
                    .accessibilityAddTraits(.isHeader)
                Text("welcome.tagline", bundle: .main)
                    .approvedText(17)
                    .foregroundStyle(ApprovedColor.inkSecondary.resolved(colorScheme))
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                appState.chooseFromLibrary()
            } label: {
                Label {
                    Text("welcome.choosePhoto", bundle: .main)
                } icon: {
                    ApprovedIconView(icon: .photo, size: 20)
                }
                .labelStyle(ApprovedButtonLabelStyle())
            }
            .buttonStyle(ApprovedButtonStyle(kind: .primary, isLarge: true, fillsWidth: true))
            .accessibilityIdentifier("welcome.choosePhoto")

            Button {
                Task { await appState.chooseCamera() }
            } label: {
                Label {
                    Text("welcome.camera", bundle: .main)
                } icon: {
                    ApprovedIconView(icon: .camera, size: 20)
                }
                .labelStyle(ApprovedButtonLabelStyle())
            }
            .buttonStyle(ApprovedButtonStyle(kind: .line, isLarge: true, fillsWidth: true))
            .accessibilityIdentifier("welcome.camera")
        }
        // `.welcome .actions`: at most 420 pt including 20 pt padding each side.
        .frame(maxWidth: 380)
        .padding(.horizontal, 20)
    }

    private var privacyLine: some View {
        Text("welcome.privacyLine", bundle: .main)
            .approvedText(12.5)
            .foregroundStyle(ApprovedColor.inkTertiary.resolved(colorScheme))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.top, 14)
    }

    private var privacyPolicyLink: some View {
        Button {
            appState.openPrivacyPolicyFromWelcome()
        } label: {
            Text("welcome.privacyPolicy", bundle: .main)
                .underline()
        }
        .buttonStyle(ApprovedButtonStyle(kind: .quiet))
        .accessibilityAddTraits(.isLink)
        .accessibilityIdentifier("welcome.privacyPolicy")
        .padding(.top, 4)
    }
}

/// Icon and title side by side with the prototype's 8 pt gap (`.btn { gap: 8px }`).
struct ApprovedButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
            configuration.title
        }
    }
}

#Preview("Light") {
    WelcomeView()
        .environment(AppState(photoLoader: ImageIOPhotoLoader()))
}
