import SwiftUI

/// Welcome (Lightly 2 `welcome`): the lime ⋮ More top right; the coloured mark (84 pt), "Lightly" (44 pt heading,
/// −1 pt tracking) and the tagline (18 pt ink2), 16 pt apart; Choose a photo (lime, 56 pt) and Camera (outlined, 56 pt)
/// 12 pt apart in a column at most 360 pt wide; the privacy line (13 pt ink2, 8 pt more space above) and the
/// Privacy Policy link (14 pt accent, 10 pt padding). Phones stack it with 24 pt sides; wide screens (unfolded
/// foldables, iPhone Duo, iPad) put the brand and the actions side by side in two equal columns.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 600
            VStack(spacing: 0) {
                HStack { Spacer(minLength: 0); L2MoreButton(identifier: "welcome.more") { appState.openMore() } }
                if wide {
                    HStack(spacing: 32) {
                        brand.frame(maxWidth: .infinity)
                        actions.frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, 24)
                    .frame(maxHeight: .infinity)
                } else {
                    FillingScrollView {
                        VStack(spacing: 0) {
                            Spacer(minLength: 24)
                            brand.layoutAnchor("welcome.brand")
                            Spacer(minLength: 32)
                            actions.layoutAnchor("welcome.actions")
                        }
                    }
                }
            }
            // Phones: 24 pt sides, 10 pt above the home indicator. Wide: the frame inset (16 pt), columns 24 pt in.
            .padding(.horizontal, wide ? 16 : 24)
            .padding(.vertical, wide ? 16 : 0)
            .padding(.bottom, wide ? 0 : 10)
        }
        .background(ApprovedColor.background.resolved(colorScheme).ignoresSafeArea())
    }

    private var brand: some View {
        let c = L2(scheme: colorScheme)
        return VStack(spacing: 16) {
            BrandMark(size: 84)
            Text("brand.wordmark", bundle: .main)
                .l2Heading(44, tracking: -1)
                .foregroundStyle(c(ApprovedColor.ink))
                .accessibilityAddTraits(.isHeader)
            Text("welcome.tagline", bundle: .main)
                .l2Text(18)
                .foregroundStyle(c(ApprovedColor.inkSecondary))
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        let c = L2(scheme: colorScheme)
        return VStack(spacing: 12) {
            Button { appState.chooseFromLibrary() } label: {
                L2Label(title: Text("welcome.choosePhoto", bundle: .main), icon: .photo, iconSize: 20)
            }
            .buttonStyle(L2WideButtonStyle(kind: .primary, height: 56))
            .accessibilityIdentifier("welcome.choosePhoto")

            Button { Task { await appState.chooseCamera() } } label: {
                L2Label(title: Text("welcome.camera", bundle: .main), icon: .camera, iconSize: 20)
            }
            .buttonStyle(L2WideButtonStyle(kind: .line, height: 56))
            .accessibilityIdentifier("welcome.camera")

            Button { appState.openPrivacyPolicyFromWelcome() } label: {
                Text("welcome.privacyPolicy", bundle: .main)
                    .l2Text(14, weight: .semibold)
                    .foregroundStyle(c(ApprovedColor.selection))
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isLink)
            .accessibilityIdentifier("welcome.privacyPolicy")
            .layoutAnchor("welcome.privacyPolicy")
        }
        .frame(maxWidth: 360)
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
