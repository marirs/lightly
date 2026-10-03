import SwiftUI
import UIKit

/// A full-screen recovery message (approved `messageScreen`): close at the top left, the photo
/// icon, a title, an explanation and two actions.
struct RecoveryMessageView: View {
    let title: Text
    let message: Text
    let primaryTitle: Text
    let primaryIdentifier: String
    let primaryAction: () -> Void
    let secondaryTitle: Text
    let secondaryIdentifier: String
    let secondaryAction: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ApprovedIconButton(
                    icon: .close, accessibilityLabel: Text("common.close", bundle: .main),
                    identifier: "recovery.close", action: onClose
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ApprovedMetrics.headerHorizontalPadding)
            .frame(height: ApprovedMetrics.headerHeight)

            FillingScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 0) {
                        // The approved screen draws the icon at the leading edge of the text
                        // block (a block-level SVG in a centred grid item), not centred over it.
                        ApprovedIconView(icon: .photo, size: 44)
                            .foregroundStyle(ApprovedColor.ink.resolved(colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        title
                            .approvedText(20, weight: .semibold)
                            .foregroundStyle(ApprovedColor.ink.resolved(colorScheme))
                            .padding(.top, 16)
                            .padding(.bottom, 8)
                            .accessibilityAddTraits(.isHeader)
                        message
                            .approvedText(15)
                            .foregroundStyle(ApprovedColor.inkSecondary.resolved(colorScheme))
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 8) {
                        Button(action: primaryAction) { primaryTitle }
                            .buttonStyle(ApprovedButtonStyle(kind: .primary, fillsWidth: true))
                            .accessibilityIdentifier(primaryIdentifier)
                        Button(action: secondaryAction) { secondaryTitle }
                            .buttonStyle(ApprovedButtonStyle(kind: .line, fillsWidth: true))
                            .accessibilityIdentifier(secondaryIdentifier)
                    }
                }
                // `max-width: 380px` inside 24 pt padding.
                .frame(maxWidth: 380)
                .padding(24)
            }
        }
        .background(ApprovedColor.background.resolved(colorScheme).ignoresSafeArea())
    }
}

/// "Camera access is off" (approved `camera-denied`).
struct CameraAccessOffView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL

    var body: some View {
        RecoveryMessageView(
            title: Text("cameraOff.title", bundle: .main),
            message: Text("cameraOff.message", bundle: .main),
            primaryTitle: Text("cameraOff.openSettings", bundle: .main),
            primaryIdentifier: "cameraOff.openSettings",
            primaryAction: {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            },
            secondaryTitle: Text("cameraOff.choosePhoto", bundle: .main),
            secondaryIdentifier: "cameraOff.choosePhoto",
            secondaryAction: { appState.chooseFromLibrary() },
            onClose: { appState.returnToWelcome() }
        )
    }
}

/// "This photo can’t be opened" (approved `load-failed`).
struct PhotoCannotBeOpenedView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        RecoveryMessageView(
            title: Text("loadFailed.title", bundle: .main),
            message: Text("loadFailed.message", bundle: .main),
            primaryTitle: Text("loadFailed.chooseAnother", bundle: .main),
            primaryIdentifier: "loadFailed.chooseAnother",
            primaryAction: { appState.chooseFromLibrary() },
            secondaryTitle: Text("loadFailed.tryAgain", bundle: .main),
            secondaryIdentifier: "loadFailed.tryAgain",
            secondaryAction: { Task { await appState.retryLastPhoto() } },
            onClose: { appState.returnToWelcome() }
        )
    }
}
