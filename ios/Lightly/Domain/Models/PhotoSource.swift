import Foundation

/// Where a photograph enters Lightly from.
///
/// Spec §0.1 locks the library path to Apple's native `PhotosPicker`. This type
/// deliberately has no `customGallery` case: a branded gallery is a post-V1,
/// opt-in feature and adding a case here is the point at which that decision
/// would silently erode.
enum PhotoSource: String, CaseIterable, Identifiable, Sendable {
    /// Native iOS camera capture.
    case camera
    /// Apple's system photo picker. Requires no Photos authorisation.
    case photoLibrary

    var id: String { rawValue }
}
