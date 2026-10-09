import SwiftUI
import UIKit

/// System camera capture with a supported control overlay. The stock camera's
/// confirmation screen unmirrors selfies before the delegate receives them;
/// our review displays the same encoded image that will enter the editor.
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
        if controller.sourceType == .camera {
            controller.showsCameraControls = false
            context.coordinator.attach(to: controller)
        }
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
        private weak var picker: UIImagePickerController?
        let overlay = CameraControlsOverlay()
        private(set) var pendingCapture: Data?
        private var capturing = false

        func attach(to picker: UIImagePickerController) {
            self.picker = picker
            overlay.frame = picker.view.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            picker.cameraOverlayView = overlay
            overlay.onShutter = { [weak self] in
                guard let self, !self.capturing, self.pendingCapture == nil, let picker = self.picker else { return }
                self.capturing = true
                self.overlay.setCapturing(true)
                picker.takePicture()
            }
            overlay.onCancel = { [weak self] in self?.onCancel() }
            overlay.onSwitch = { [weak self] in
                guard let self, !self.capturing, let picker = self.picker else { return }
                let next: UIImagePickerController.CameraDevice = picker.cameraDevice == .front ? .rear : .front
                guard UIImagePickerController.isCameraDeviceAvailable(next) else { return }
                picker.cameraDevice = next
                self.updateFlash()
            }
            overlay.onFlash = { [weak self] in
                guard let self, !self.capturing, let picker = self.picker else { return }
                switch picker.cameraFlashMode {
                case .auto: picker.cameraFlashMode = .on
                case .on: picker.cameraFlashMode = .off
                default: picker.cameraFlashMode = .auto
                }
                self.updateFlash()
            }
            overlay.onReviewDismissed = { [weak self] in self?.updateFlash() }
            overlay.onRetake = { [weak self] in self?.retake() }
            overlay.onUse = { [weak self] in self?.usePhoto() }
            updateFlash()
        }

        private func updateFlash() {
            guard let picker else { return }
            overlay.flash.isHidden = !UIImagePickerController.isFlashAvailable(for: picker.cameraDevice)
            let mode = picker.cameraFlashMode
            overlay.flash.setImage(UIImage(systemName: mode == .off ? "bolt.slash.fill" : "bolt.fill"), for: .normal)
            overlay.flash.accessibilityValue = mode == .auto ? "Auto" : mode == .on ? "On" : "Off"
            overlay.flash.tintColor = mode == .off ? .white : .systemYellow
        }

        func retake() {
            pendingCapture = nil
            overlay.showReview(nil)
        }

        func usePhoto() {
            guard let data = pendingCapture else { return }
            pendingCapture = nil
            onCapture(data)
        }

        func receive(_ original: UIImage, camera: UIImagePickerController.CameraDevice) {
            capturing = false
            overlay.setCapturing(false)
            let image = CameraCaptureView.imageMatchingPreview(original, camera: camera)
            guard let data = image.heicData() ?? image.jpegData(compressionQuality: 1.0),
                  let review = UIImage(data: data) else {
                onCancel()
                return
            }
            pendingCapture = data
            overlay.showReview(review)
        }

        init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let original = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            receive(original, camera: picker.cameraDevice)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

/// Opaque review prevents any unmirrored system confirmation from being shown.
/// Capture controls use the system camera overlay API; no private camera views.
@MainActor
final class CameraControlsOverlay: UIView {
    var onShutter: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSwitch: (() -> Void)?
    var onFlash: (() -> Void)?
    var onRetake: (() -> Void)?
    var onUse: (() -> Void)?
    let flash = UIButton(type: .system)
    let shutter = UIButton(type: .system)
    private let cancel = UIButton(type: .system)
    private let switchCamera = UIButton(type: .system)
    private let captureBar = UIView()
    private let review = UIView()
    let reviewImage = UIImageView()
    private let retake = UIButton(type: .system)
    private let use = UIButton(type: .system)

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        captureBar.backgroundColor = .black
        addSubview(captureBar)
        icon(cancel, symbol: "xmark", label: "Cancel", id: "camera.cancel") { [weak self] in self?.onCancel?() }
        icon(switchCamera, symbol: "arrow.triangle.2.circlepath.camera", label: "Switch camera", id: "camera.switch") { [weak self] in self?.onSwitch?() }
        icon(flash, symbol: "bolt.fill", label: "Flash", id: "camera.flash") { [weak self] in self?.onFlash?() }
        flash.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        flash.layer.cornerRadius = 24
        addSubview(flash)
        shutter.backgroundColor = .white
        shutter.layer.cornerRadius = 36
        shutter.layer.borderWidth = 5
        shutter.layer.borderColor = UIColor.darkGray.cgColor
        shutter.accessibilityLabel = "Take photo"
        shutter.accessibilityIdentifier = "camera.shutter"
        shutter.addAction(UIAction { [weak self] _ in self?.onShutter?() }, for: .touchUpInside)
        for button in [cancel, shutter, switchCamera] { captureBar.addSubview(button) }
        review.backgroundColor = .black
        review.isHidden = true
        addSubview(review)
        reviewImage.contentMode = .scaleAspectFit
        reviewImage.accessibilityIdentifier = "camera.review.image"
        review.addSubview(reviewImage)
        text(retake, title: "Retake", id: "camera.retake") { [weak self] in self?.onRetake?() }
        text(use, title: "Use Photo", id: "camera.use") { [weak self] in self?.onUse?() }
        review.addSubview(retake)
        review.addSubview(use)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func icon(_ button: UIButton, symbol: String, label: String, id: String, action: @escaping () -> Void) {
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 25, weight: .regular)), for: .normal)
        button.tintColor = .white
        button.accessibilityLabel = label
        button.accessibilityIdentifier = id
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    private func text(_ button: UIButton, title: String, id: String, action: @escaping () -> Void) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .title3)
        button.tintColor = .white
        button.accessibilityIdentifier = id
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    func setCapturing(_ capturing: Bool) {
        for button in [shutter, switchCamera, flash] { button.isEnabled = !capturing }
        shutter.alpha = capturing ? 0.5 : 1
    }

    func showReview(_ image: UIImage?) {
        reviewImage.image = image
        review.isHidden = image == nil
        captureBar.isHidden = image != nil
        flash.isHidden = image != nil || flash.isHidden
        if image == nil { onReviewDismissed?() }
    }
    var onReviewDismissed: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        let bottom = safeAreaInsets.bottom
        let barHeight: CGFloat = 132 + bottom
        captureBar.frame = CGRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
        shutter.frame = CGRect(x: (bounds.width - 72) / 2, y: 24, width: 72, height: 72)
        cancel.frame = CGRect(x: 20, y: 36, width: 56, height: 56)
        switchCamera.frame = CGRect(x: bounds.width - 76, y: 36, width: 56, height: 56)
        flash.frame = CGRect(x: 20, y: safeAreaInsets.top + 12, width: 48, height: 48)
        review.frame = bounds
        let reviewBarHeight: CGFloat = 72 + bottom
        reviewImage.frame = CGRect(x: 0, y: safeAreaInsets.top, width: bounds.width, height: max(0, bounds.height - safeAreaInsets.top - reviewBarHeight))
        retake.frame = CGRect(x: 16, y: bounds.height - reviewBarHeight + 8, width: 110, height: 56)
        use.frame = CGRect(x: bounds.width - 146, y: bounds.height - reviewBarHeight + 8, width: 130, height: 56)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // Let tap-to-focus and camera gestures reach the system preview.
        return hit === self ? nil : hit
    }
}
