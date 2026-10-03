import AVFoundation
import UIKit

/// Camera permission as Lightly needs it: whether to ask, capture, or show "Camera access is off".
enum CameraAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    /// Denied by the person, or restricted (Screen Time, MDM). Both lead to the same screen.
    case denied
}

/// The system camera permission and availability, behind a protocol so the flow is testable
/// without the system alert.
protocol CameraAccessing: Sendable {
    /// Whether this device can capture at all (false on the simulator).
    @MainActor var isCaptureAvailable: Bool { get }
    func authorization() -> CameraAuthorization
    /// Shows the system permission alert (only while `.notDetermined`).
    func requestAccess() async -> Bool
}

struct SystemCameraAccess: CameraAccessing {
    @MainActor var isCaptureAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func authorization() -> CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
}
