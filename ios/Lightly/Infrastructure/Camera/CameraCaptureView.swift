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
        // v3 differs: v1 fell back to the legacy library picker when there was
        // no camera. The approved flow has no such picker: `AppState` presents
        // this view only when capture is available (`CameraAccessing`).
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            controller.sourceType = .camera
        } else {
            // Unreachable through AppState; never show a library instead.
            DispatchQueue.main.async { onCancel() }
        }
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {
        // No dynamic configuration; the flow is fully system-driven.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    /// Match the front camera's mirrored viewfinder before encoding. Keeping the
    /// transform in the capture bytes makes editor, restore and export agree.
    static func imageMatchingPreview(_ image: UIImage, camera: UIImagePickerController.CameraDevice) -> UIImage {
        guard camera == .front, let pixels = image.cgImage else { return image }
        // Mirror in displayed coordinates, after sensor rotation. Merely
        // toggling the mirrored variant flips vertically for left/right images.
        let orientation: UIImage.Orientation
        switch image.imageOrientation {
        case .up: orientation = .upMirrored
        case .upMirrored: orientation = .up
        case .down: orientation = .downMirrored
        case .downMirrored: orientation = .down
        case .left: orientation = .rightMirrored
        case .rightMirrored: orientation = .left
        case .right: orientation = .leftMirrored
        case .leftMirrored: orientation = .right
        @unknown default: return image
        }
        return UIImage(cgImage: pixels, scale: image.scale, orientation: orientation)
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
            guard let original = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            let image = CameraCaptureView.imageMatchingPreview(original, camera: picker.cameraDevice)
            guard let data = image.heicData() ?? image.jpegData(compressionQuality: 1.0) else {
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
