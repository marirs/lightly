import SwiftUI

/// Welcome (Lightly 2 `welcome`): the lime ⋮ More top right; the coloured mark (84 pt), "Lightly" (44 pt heading,
/// −1 pt tracking) and the tagline (18 pt ink2), 16 pt apart; Choose a photo (lime, 56 pt) and Camera (outlined, 56 pt)
/// 12 pt apart in a column at most 360 pt wide; then the Privacy Policy link (14 pt accent, 10 pt padding; the privacy
/// line was removed by the owner on 2026-10-10, 290172d). Phones stack it with 24 pt sides; wide screens (unfolded
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
                            actions
                        }
                        // 10 pt above the home indicator, inside the scroll view (not around it) so the Privacy
                        // Policy link's 44 pt touch target, which reaches a few points into this margin, stays
                        // inside the scroll view's bounds and keeps receiving touches.
                        .padding(.bottom, 10)
                        // Inside the scroll view, whose content would otherwise take the touches on empty space.
                        .background(emptySpace)
                    }
                }
            }
            // Phones: 24 pt sides (the 10 pt bottom margin is inside the scroll view). Wide: the frame inset (16 pt),
            // columns 24 pt in.
            .padding(.horizontal, wide ? 16 : 24)
            .padding(.vertical, wide ? 16 : 0)
        }
        // The page colour itself takes the double tap where nothing in front does.
        .background(ApprovedColor.background.resolved(colorScheme).cyclesThemeOnDoubleTap(cycleTheme).ignoresSafeArea())
    }

    /// Double tap on empty space cycles the theme (owner amendment 2026-10-11), with its toast.
    private var emptySpace: some View { Color.clear.cyclesThemeOnDoubleTap(cycleTheme) }

    private func cycleTheme() { appState.showToast(appState.cycleAppearance()) }

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
        VStack(spacing: 12) {
            // The anchor covers the two buttons only, so layout tests can check they never overlap the link.
            VStack(spacing: 12) {
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
            }
            .layoutAnchor("welcome.actions")

            privacyPolicyLink
        }
        .frame(maxWidth: 360)
    }

    /// The mockup's link box is the 14 pt text plus 10 pt padding (36.5 pt tall in the reference). It keeps that box and
    /// position, and `TouchTargetOutset` grows only the tappable frame to 44 pt, centred on it, so the link meets the
    /// minimum target size without moving anything on screen. At large text sizes the box is taller than 44 pt anyway.
    private var privacyPolicyLink: some View {
        let c = L2(scheme: colorScheme)
        return TouchTargetOutset(minimumHeight: 44) {
            Button { appState.openPrivacyPolicyFromWelcome() } label: {
                Text("welcome.privacyPolicy", bundle: .main)
                    .l2Text(14, weight: .semibold)
                    .foregroundStyle(c(ApprovedColor.selection))
                    .padding(10)
                    .layoutAnchor("welcome.privacyPolicy.label")
                    // Fills the taller frame TouchTargetOutset proposes; the text stays centred in it.
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isLink)
            .accessibilityIdentifier("welcome.privacyPolicy")
            .layoutAnchor("welcome.privacyPolicy")
        }
    }
}

/// Lays out its one child at the child's natural size (so the surrounding layout is exactly as without it) but places
/// the child with at least `minimumHeight`, centred on that natural box. The extra height reaches into the space around
/// it, which gives a small control a full touch target without changing the approved spacing.
struct TouchTargetOutset: Layout {
    var minimumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        child.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                    proposal: ProposedViewSize(width: natural.width, height: max(natural.height, minimumHeight)))
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
