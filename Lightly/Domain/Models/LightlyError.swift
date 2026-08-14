import Foundation

/// The complete catalogue of recoverable failure states (spec §28).
///
/// Every case here must have defined user-facing copy and a clear next action.
/// The spec is explicit that there are no silent failures and no infinite
/// spinners, so this enum is exhaustive by design: adding a new failure mode to
/// the app means adding a case here and, with it, copy plus a recovery action.
///
/// Cases not reachable in Phase 1 are still declared, because the acceptance
/// criteria require snapshot coverage of every state before V1 ships.
enum LightlyError: Error, Equatable, CaseIterable, Sendable {

    // MARK: - Selection and loading

    /// The chosen asset could not be decoded into a supported image format.
    case unsupportedImageFormat
    /// The asset exists but loading threw or returned no data.
    case photoLoadingFailed
    /// The device could not hold the asset at working resolution.
    case insufficientMemory
    /// A RAW file exceeds the device's processing budget.
    case rawFileTooLarge

    // MARK: - Processing

    /// The Develop pipeline failed. The original is always preserved.
    case developFailed
    /// A required Core ML model is unavailable on this device's capability tier.
    case modelUnavailable
    /// No face was detected for an operation that requires one.
    case noFaceDetected
    /// Several faces were detected and the target is ambiguous.
    case multipleFacesDetected

    // MARK: - Cloud

    /// A cloud-assisted feature is not currently available.
    case cloudFeatureUnavailable
    /// Connectivity dropped mid-operation. Credits must not be consumed.
    case networkInterrupted

    // MARK: - Output

    /// Writing or encoding the exported image failed.
    case exportFailed
    /// There is no room on the device to save the result.
    case storageFull

    // MARK: - Permissions and intent

    /// The user declined a permission the chosen action requires.
    case permissionDenied
    /// The user backed out of an operation. Not an error condition, but it is
    /// modelled here so cancellation always unwinds through one code path with
    /// no side effects and no charges.
    case userCancelled
}

extension LightlyError {

    /// Whether this state represents a genuine fault worth reporting.
    ///
    /// Cancellation is a normal outcome and must never surface as an error
    /// banner or be recorded as a failure in telemetry (spec §30).
    var isFault: Bool {
        self != .userCancelled
    }

    /// Stable identifier used for telemetry (spec §30 permits tool
    /// success/failure, and nothing about the image itself).
    var telemetryIdentifier: String {
        String(describing: self)
    }
}
