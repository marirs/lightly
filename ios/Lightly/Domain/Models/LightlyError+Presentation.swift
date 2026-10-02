import SwiftUI

extension LightlyError {

    /// Localisation key for the user-facing explanation of this state.
    ///
    /// Kept separate from the error type itself so the domain layer carries no
    /// presentation concerns. Every case resolves to a real entry in the String
    /// Catalogue — spec §28 requires defined copy for each state, and an
    /// exhaustive switch here means a new case cannot ship without it.
    var localizedMessageKey: LocalizedStringKey {
        switch self {
        case .unsupportedImageFormat: "error.unsupportedImageFormat"
        case .photoLoadingFailed: "error.photoLoadingFailed"
        case .insufficientMemory: "error.insufficientMemory"
        case .rawFileTooLarge: "error.rawFileTooLarge"
        case .developFailed: "error.developFailed"
        case .modelUnavailable: "error.modelUnavailable"
        case .noFaceDetected: "error.noFaceDetected"
        case .multipleFacesDetected: "error.multipleFacesDetected"
        case .cloudFeatureUnavailable: "error.cloudFeatureUnavailable"
        case .networkInterrupted: "error.networkInterrupted"
        case .exportFailed: "error.exportFailed"
        case .storageFull: "error.storageFull"
        case .permissionDenied: "error.permissionDenied"
        case .userCancelled: "error.userCancelled"
        }
    }
}
