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

    /// Lightly 2 `messageScreen`: Close top-left (12 pt in); a 72 pt photo tile (24 pt corners, card fill, hairline,
    /// 34 pt accent icon), the title (22 pt heading) and the message (14 pt ink2, line height 1.45), 14 pt apart and at
    /// most 340 pt wide; the actions (primary, then outlined, 10 pt apart, at most 340 pt); 28 pt between the blocks,
    /// centred. Wide screens put the message and the actions side by side.
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 600
            ZStack(alignment: .topLeading) {
                Group {
                    if wide {
                        HStack(spacing: 24) { messageBlock.frame(maxWidth: .infinity); actions.frame(maxWidth: .infinity) }
                            .padding(.horizontal, 24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        FillingScrollView {
                            VStack(spacing: 28) { messageBlock; actions }
                                .padding(.horizontal, 24).padding(.top, 50).padding(.bottom, 20)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                L2IconButton(icon: .close, label: Text("common.close", bundle: .main), identifier: "recovery.close", action: onClose)
                    .padding(.leading, 12)
            }
        }
        .background(ApprovedColor.background.resolved(colorScheme).ignoresSafeArea())
    }

    private var messageBlock: some View {
        let c = L2(scheme: colorScheme)
        return VStack(spacing: 14) {
            ApprovedIconView(icon: .photo, size: 34)
                .foregroundStyle(c(ApprovedColor.selection))
                .frame(width: 72, height: 72)
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(c(ApprovedColor.backgroundSecondary)))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(c(ApprovedColor.hairline), lineWidth: 1))
            title.l2Heading(22).foregroundStyle(c(ApprovedColor.ink)).accessibilityAddTraits(.isHeader)
            message.l2Text(14, lineHeight: 1.45).foregroundStyle(c(ApprovedColor.inkSecondary))
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 340)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: primaryAction) { primaryTitle }
                .buttonStyle(L2WideButtonStyle(kind: .primary))
                .accessibilityIdentifier(primaryIdentifier)
            Button(action: secondaryAction) { secondaryTitle }
                .buttonStyle(L2WideButtonStyle(kind: .line))
                .accessibilityIdentifier(secondaryIdentifier)
        }
        .frame(maxWidth: 340)
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
