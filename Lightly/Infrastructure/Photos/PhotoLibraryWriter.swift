import Foundation
import Photos

/// Saves an exported photograph to the user's library.
protocol PhotoLibraryWriting: Sendable {
    /// Writes encoded image data as a new asset.
    ///
    /// - Throws: `LightlyError.permissionDenied` when the user declines,
    ///   `LightlyError.storageFull` when the device is out of space, or
    ///   `LightlyError.exportFailed` for other write failures.
    func save(_ data: Data, fileExtension: String) async throws
}

/// PhotoKit implementation.
///
/// Requests **add-only** authorisation, never full library access. Saving needs
/// nothing more, and asking for read access to write a file would contradict
/// the same principle that put the native picker in §0.1: request the narrowest
/// permission that does the job.
struct PhotoKitLibraryWriter: PhotoLibraryWriting {

    func save(_ data: Data, fileExtension: String) async throws {
        try await requestAddOnlyAuthorization()

        // PhotoKit's file-based request wants a URL, so the encoded bytes go to
        // a temporary file that is removed once the asset has been created.
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)

        do {
            try data.write(to: temporaryURL)
        } catch let error as NSError where isOutOfSpace(error) {
            throw LightlyError.storageFull
        } catch {
            throw LightlyError.exportFailed
        }

        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: temporaryURL, options: nil)
            }
        } catch let error as NSError where isOutOfSpace(error) {
            throw LightlyError.storageFull
        } catch {
            throw LightlyError.exportFailed
        }
    }

    private func requestAddOnlyAuthorization() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)

        switch current {
        case .authorized, .limited:
            return
        case .denied, .restricted:
            throw LightlyError.permissionDenied
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard granted == .authorized || granted == .limited else {
                throw LightlyError.permissionDenied
            }
        @unknown default:
            throw LightlyError.permissionDenied
        }
    }

    /// Whether a write failure was caused by a full disk.
    ///
    /// Distinguished from a generic failure so the user is told to free space
    /// rather than shown an unhelpful "export failed" (spec §28).
    private func isOutOfSpace(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain
            && error.code == NSFileWriteOutOfSpaceError
    }
}
