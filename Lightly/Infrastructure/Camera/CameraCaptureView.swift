import SwiftUI
import UIKit

/// Thin wrapper over the native iOS camera capture flow (spec §4.2).
///
/// Uses `UIImagePickerController` rather than a custom `AVCaptureSession`
/// because V1 explicitly excludes a custom camera (spec §21). The system UI also
/// handles the permission prompt, so Lightly never has to reproduce it.
struct CameraCaptureView: UIViewControllerRepresentable {
    /// Called with encoded image data when the user keeps a capture.
    let onCapture: (Data) -> Void
    /// Called when the user backs out. Must not be treated as an error (§28).
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        // Guard the source type: the simulator and iPads without a camera will
        // otherwise raise at presentation time.
        controller.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera)
            ? .camera
            : .photoLibrary
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {
        // No dynamic configuration; the flow is fully system-driven.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    /// Bridges `UIImagePickerController`'s delegate callbacks to closures.
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data) -> Void
        private let onCancel: () -> Void

        init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // Prefer HEIC, which is the native iPhone capture format and
            // eliminates the lossy JPEG round-trip that Phase 1 shipped with
            // (see phase-2-deferred.md item 2). The JPEG fallback handles
            // simulator environments and older devices that lack hardware
            // HEIC encoding.
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.heicData() ?? image.jpegData(compressionQuality: 1.0) else {
                // A capture that cannot be encoded is a defined failure state,
                // not a silent no-op. Surfaced as cancellation here and mapped
                // by the caller.
                onCancel()
                return
            }
            onCapture(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
