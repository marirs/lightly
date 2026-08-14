import SwiftUI

/// The launch screen (spec §4.1).
///
/// No buttons, no login, no spinner. The only affordance is an upward swipe,
/// which is why §0.11 requires a gentle idle nudge: the gesture is the sole
/// entry point, and a user who does not discover it has no way forward.
struct LaunchView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live drag translation, used to move the artwork with the gesture.
    @State private var dragTranslation: CGFloat = 0
    /// Whether the idle period has elapsed and the affordance should hint.
    @State private var isHintingSwipe = false

    /// Upward drag distance, in points, that commits to revealing the sheet.
    private let swipeCommitThreshold: CGFloat = 60

    /// Height of the mountain band.
    private static let artworkHeight: CGFloat = 150

    /// Vertical space reserved at the bottom for the swipe affordance.
    ///
    /// The artwork is inset by this amount and the affordance occupies exactly
    /// it, so the two can never overlap regardless of device height.
    private static let affordanceReservedHeight: CGFloat = 72

    var body: some View {
        ZStack {
            LightlyColor.background(colorScheme)
                .ignoresSafeArea()

            // Artwork sits behind the content, inset from the bottom so the
            // swipe affordance below it keeps clear space. Overlapping the two
            // makes the only entry point in the app harder to read.
            VStack {
                Spacer()
                MountainArtwork(
                    tint: LightlyColor.line(colorScheme),
                    parallaxOffset: parallaxOffset
                )
                .frame(height: Self.artworkHeight)
                .padding(.bottom, Self.affordanceReservedHeight)
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                Spacer()

                // The lockup and tagline read as one brand statement, so they
                // are grouped rather than separated by a flexible spacer.
                VStack(spacing: LightlySpacing.xl) {
                    brandLockup
                    tagline
                }

                Spacer()
                Spacer()

                swipeAffordance
                    .frame(height: Self.affordanceReservedHeight)
            }
            .padding(.horizontal, LightlySpacing.l)
        }
        .contentShape(Rectangle())
        .gesture(swipeUpGesture)
        .task { await beginIdleHintCountdown() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("launch.accessibility.label", bundle: .main))
        .accessibilityHint(Text("launch.accessibility.hint", bundle: .main))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            // VoiceOver users cannot perform the swipe reliably, so activation
            // is an equivalent path to the same intent.
            appState.revealSourceSelection()
        }
    }

    // MARK: - Composition

    private var brandLockup: some View {
        VStack(spacing: LightlySpacing.m) {
            BrandMark(
                size: LightlySize.brandMarkLaunch,
                tint: LightlyColor.textPrimary(colorScheme)
            )

            VStack(spacing: LightlySpacing.xxs) {
                Text("brand.wordmark", bundle: .main)
                    .font(LightlyTypography.wordmark)
                    .foregroundStyle(LightlyColor.textPrimary(colorScheme))

                Text("brand.wordmark.subtitle", bundle: .main)
                    .font(LightlyTypography.wordmarkSubtitle)
                    .tracking(LightlyTypography.wordmarkSubtitleTracking)
                    .foregroundStyle(LightlyColor.textSecondary(colorScheme))
            }
        }
    }

    private var tagline: some View {
        Text("launch.tagline", bundle: .main)
            .font(LightlyTypography.tagline)
            .foregroundStyle(LightlyColor.textSecondary(colorScheme))
            .multilineTextAlignment(.center)
            .lineSpacing(LightlySpacing.xxs)
    }

    private var swipeAffordance: some View {
        VStack(spacing: LightlySpacing.xs) {
            Image(systemName: "chevron.up")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(LightlyColor.textTertiary(colorScheme))
                .offset(y: hintOffset)

            Text("launch.swipe.prompt", bundle: .main)
                .font(LightlyTypography.caption)
                .foregroundStyle(LightlyColor.textTertiary(colorScheme))
        }
        .animation(
            isHintingSwipe && !reduceMotion
                ? LightlyMotion.affordanceNudge.repeatForever(autoreverses: true)
                : .default,
            value: isHintingSwipe
        )
    }

    // MARK: - Motion

    /// Vertical travel applied to the idle hint.
    ///
    /// Respects Reduce Motion by resolving to zero, in which case the affordance
    /// simply remains visible rather than animating.
    private var hintOffset: CGFloat {
        guard isHintingSwipe, !reduceMotion else { return 0 }
        return -LightlyMotion.affordanceNudgeTravel
    }

    /// Damped translation passed to the artwork.
    ///
    /// Damping keeps the response "subtle" per §4.1 — the mountains acknowledge
    /// the gesture rather than tracking it one-to-one.
    private var parallaxOffset: CGFloat {
        max(0, -dragTranslation) * 0.4
    }

    private var swipeUpGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                // Only upward movement drives the artwork.
                dragTranslation = min(0, value.translation.height)
            }
            .onEnded { value in
                let didSwipeUpFarEnough = -value.translation.height >= swipeCommitThreshold
                withAnimation(LightlyMotion.ambient) {
                    dragTranslation = 0
                }
                if didSwipeUpFarEnough {
                    appState.revealSourceSelection()
                }
            }
    }

    /// Starts the idle countdown that eventually hints at the swipe gesture.
    ///
    /// Cancelled automatically when the view disappears, because `.task` ties
    /// the work to the view's lifetime.
    private func beginIdleHintCountdown() async {
        try? await Task.sleep(for: LightlyMotion.idleBeforeAffordanceHint)
        guard !Task.isCancelled else { return }
        isHintingSwipe = true
    }
}

#Preview("Light") {
    LaunchView()
        .environment(AppState(photoLoader: ImageIOPhotoLoader()))
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    LaunchView()
        .environment(AppState(photoLoader: ImageIOPhotoLoader()))
        .preferredColorScheme(.dark)
}
