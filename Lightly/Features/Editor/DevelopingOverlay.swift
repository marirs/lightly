import SwiftUI

/// The developing state (spec §4.4).
///
/// The photograph stays visible behind a translucent scrim. Stages are listed
/// only if the engine genuinely performs them, and each is ticked when its work
/// actually completes — no timers, no staged reveal, no artificial pacing.
struct DevelopingOverlay: View {
    /// Stages the active engine actually performs.
    let stages: [DevelopStage]
    /// Stages whose work has completed.
    let completedStages: Set<DevelopStage>

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Scrim: darkens the photograph without hiding it.
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: LightlySpacing.xl) {
                VStack(spacing: LightlySpacing.xs) {
                    Text("develop.progress.title", bundle: .main)
                        .font(LightlyTypography.title)
                        .foregroundStyle(.white)

                    // Canonical copy, locked by spec §0.11 and §4.4.
                    Text("develop.progress.subtitle", bundle: .main)
                        .font(LightlyTypography.subtitle)
                        .foregroundStyle(.white.opacity(0.75))
                }

                VStack(spacing: 0) {
                    ForEach(stages) { stage in
                        stageRow(stage)
                    }
                }
                .frame(maxWidth: 320)
            }
            .padding(LightlySpacing.l)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("develop.progress.title", bundle: .main))
    }

    private func stageRow(_ stage: DevelopStage) -> some View {
        let isComplete = completedStages.contains(stage)

        return HStack {
            Text(LocalizedStringKey(stage.localizationKey), bundle: .main)
                .font(LightlyTypography.rowSubtitle)
                .foregroundStyle(.white.opacity(isComplete ? 0.95 : 0.5))

            Spacer(minLength: LightlySpacing.m)

            Image(systemName: isComplete ? "checkmark.circle" : "circle")
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(.white.opacity(isComplete ? 0.95 : 0.3))
        }
        .padding(.vertical, LightlySpacing.s)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            isComplete
                ? Text("develop.stage.complete", bundle: .main)
                : Text("develop.stage.pending", bundle: .main)
        )
    }
}

#Preview {
    ZStack {
        Color.gray
        DevelopingOverlay(
            stages: DebugFixedRecipeDeveloper().performedStages,
            completedStages: [.whiteBalance, .exposure]
        )
    }
    .ignoresSafeArea()
}
