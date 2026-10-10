import SwiftUI
import UIKit
import AVFoundation

/// Explicitly sized camera preview and a mirrored confirmation image.
struct CameraCaptureView: UIViewControllerRepresentable {
    /// Called with encoded image data when the user keeps a capture.
    let onCapture: (Data) -> Void
    /// Called when the user backs out. Must not be treated as an error (§28).
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> CameraPreviewController {
        let controller = CameraPreviewController(overlay: context.coordinator.overlay)
        context.coordinator.attach(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: CameraPreviewController, context: Context) {}

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
    @MainActor
    final class Coordinator: NSObject {
        private let onCapture: (Data) -> Void
        private let onCancel: () -> Void
        private weak var picker: CameraPreviewController?
        let overlay = CameraControlsOverlay()
        private(set) var pendingCapture: Data?
        private var capturing = false

        func attach(to picker: CameraPreviewController) {
            self.picker = picker
            picker.onPhoto = { [weak self] image, front in
                self?.receive(image, camera: front ? .front : .rear)
            }
            picker.onFailure = { [weak self] in self?.onCancel() }
            overlay.onShutter = { [weak self] in
                guard let self, !self.capturing, self.pendingCapture == nil else { return }
                self.capturing = true
                self.overlay.setCapturing(true)
                self.picker?.takePhoto()
            }
            overlay.onCancel = { [weak self] in self?.onCancel() }
            overlay.onSwitch = { [weak self] in self?.picker?.switchCamera() }
            overlay.onFlash = { [weak self] in self?.picker?.cycleFlash() }
            overlay.onRetake = { [weak self] in self?.retake() }
            overlay.onUse = { [weak self] in self?.usePhoto() }
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

    }

}

/// Opaque review prevents any unmirrored system confirmation from being shown.
/// Capture controls and preview share one explicit layout.
@MainActor
final class CameraControlsOverlay: UIView {
    var onShutter: (() -> Void)?
    var onCancel: (() -> Void)?
    var onSwitch: (() -> Void)?
    var onFlash: (() -> Void)?
    var onRetake: (() -> Void)?
    var onUse: (() -> Void)?
    var onLayout: ((CGRect) -> Void)?
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
        onLayout?(CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - barHeight)))
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


/// Owns the preview's bounds instead of depending on UIImagePickerController's
/// undocumented internal preview frame. The original capture is kept in full.
@MainActor
final class CameraPreviewController: UIViewController {
    private let engine = CameraCaptureEngine()
    private let preview = AVCaptureVideoPreviewLayer()
    private let overlay: CameraControlsOverlay
    private var flashMode: AVCaptureDevice.FlashMode = .auto
    var onPhoto: ((UIImage, Bool) -> Void)?
    var onFailure: (() -> Void)?

    init(overlay: CameraControlsOverlay) {
        self.overlay = overlay
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        preview.session = engine.session
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        view.addSubview(overlay)
        overlay.setCapturing(true)
        overlay.onLayout = { [weak self] frame in
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self?.preview.frame = frame
            CATransaction.commit()
        }
        let focus = UITapGestureRecognizer(target: self, action: #selector(focusAtTap(_:)))
        view.addGestureRecognizer(focus)
        focus.cancelsTouchesInView = false
        engine.onReady = { [weak self] front, hasFlash in
            guard let self else { return }
            if let connection = self.preview.connection {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                connection.automaticallyAdjustsVideoMirroring = false
                if connection.isVideoMirroringSupported { connection.isVideoMirrored = front }
            }
            self.overlay.flash.isHidden = !hasFlash
            self.overlay.setCapturing(false)
            self.updateFlash()
        }
        engine.onPhoto = { [weak self] image, front in self?.onPhoto?(image, front) }
        engine.onFailure = { [weak self] in self?.onFailure?() }
        overlay.onReviewDismissed = { [weak self] in self?.engine.refreshControls() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        overlay.frame = view.bounds
        overlay.setNeedsLayout()
        overlay.layoutIfNeeded()
    }
    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); engine.start() }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); engine.stop() }
    func takePhoto() { engine.takePhoto(flash: flashMode) }
    func switchCamera() { overlay.setCapturing(true); engine.switchCamera() }
    func cycleFlash() {
        flashMode = flashMode == .auto ? .on : flashMode == .on ? .off : .auto
        updateFlash()
    }
    private func updateFlash() {
        overlay.flash.setImage(UIImage(systemName: flashMode == .off ? "bolt.slash.fill" : "bolt.fill"), for: .normal)
        overlay.flash.accessibilityValue = flashMode == .auto ? "Auto" : flashMode == .on ? "On" : "Off"
        overlay.flash.tintColor = flashMode == .off ? .white : .systemYellow
    }
    @objc private func focusAtTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        guard preview.frame.contains(point), overlay.hitTest(point, with: nil) == nil else { return }
        engine.focus(at: preview.captureDevicePointConverted(fromLayerPoint: point))
    }
}

/// All session mutations and start/stop run on one queue, never on the UI thread.
final class CameraCaptureEngine: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "pro.lightly.camera", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var captureFront = false
    var onReady: (@MainActor (Bool, Bool) -> Void)?
    var onPhoto: (@MainActor (UIImage, Bool) -> Void)?
    var onFailure: (@MainActor () -> Void)?

    func start() { queue.async { [self] in
        if input == nil {
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let candidate = try? AVCaptureDeviceInput(device: device), session.canAddInput(candidate), session.canAddOutput(output) else {
                session.commitConfiguration(); fail(); return
            }
            session.addInput(candidate); input = candidate
            session.addOutput(output)
            session.commitConfiguration()
        }
        session.startRunning()
        ready()
    } }
    func stop() { queue.async { [self] in session.stopRunning() } }
    func refreshControls() { queue.async { [self] in ready() } }
    private func ready() {
        let front = input?.device.position == .front
        let flash = input?.device.hasFlash ?? false
        DispatchQueue.main.async { [self] in onReady?(front, flash) }
    }
    private func fail() { DispatchQueue.main.async { [self] in onFailure?() } }
    func switchCamera() { queue.async { [self] in
        guard let old = input else { ready(); return }
        let position: AVCaptureDevice.Position = old.device.position == .front ? .back : .front
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let candidate = try? AVCaptureDeviceInput(device: device) else { ready(); return }
        session.beginConfiguration()
        session.removeInput(old)
        if session.canAddInput(candidate) { session.addInput(candidate); input = candidate }
        else { session.addInput(old) }
        session.commitConfiguration()
        ready()
    } }
    func focus(at point: CGPoint) { queue.async { [self] in
        guard let device = input?.device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
            device.focusPointOfInterest = point; device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposurePointOfInterest = point; device.exposureMode = .continuousAutoExposure
        }
    } }
    func takePhoto(flash: AVCaptureDevice.FlashMode) { queue.async { [self] in
        guard session.isRunning, let connection = output.connection(with: .video) else { fail(); return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
        captureFront = input?.device.position == .front
        let settings = AVCapturePhotoSettings()
        if output.supportedFlashModes.contains(flash) { settings.flashMode = flash }
        output.capturePhoto(with: settings, delegate: self)
    } }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else { fail(); return }
        let front = captureFront
        DispatchQueue.main.async { [self] in onPhoto?(image, front) }
    }
}
