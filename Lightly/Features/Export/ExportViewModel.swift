import CoreGraphics
import Foundation
import Observation

/// Where an export is headed.
enum ExportDestination: Equatable, Sendable {
    /// Written to the user's photo library as a new asset.
    case photoLibrary
    /// Handed to the system share sheet.
    case share
}

/// Outcome of an export attempt.
enum ExportOutcome: Equatable, Sendable {
    case idle
    case exporting
    case savedToLibrary
    /// Encoded and ready for the share sheet.
    case readyToShare(URL)
    case failed(LightlyError)
}

/// Drives the export sheet (spec §14).
@MainActor
@Observable
final class ExportViewModel {

    // MARK: - State

    private(set) var settings: ExportSettings = .default
    private(set) var outcome: ExportOutcome = .idle

    /// Raised when the chosen settings need Pro and the user does not have it.
    private(set) var paywallPrompt: PaidCapability?

    // MARK: - Dependencies

    /// The fully rendered image, at full resolution.
    private let renderedImage: CGImage
    /// Bytes of the original, used as the metadata source.
    private let originalData: Data

    private let exporter: any PhotoExporting
    private let libraryWriter: any PhotoLibraryWriting
    private let entitlements: any EntitlementResolving

    private var exportTask: Task<Void, Never>?

    init(
        renderedImage: CGImage,
        originalData: Data,
        exporter: any PhotoExporting,
        libraryWriter: any PhotoLibraryWriting,
        entitlements: any EntitlementResolving
    ) {
        self.renderedImage = renderedImage
        self.originalData = originalData
        self.exporter = exporter
        self.libraryWriter = libraryWriter
        self.entitlements = entitlements
    }

    // MARK: - Derived

    /// Whether the current settings are permitted by the user's entitlement.
    var isCurrentSelectionEntitled: Bool {
        isEntitled(to: settings)
    }

    private func isEntitled(to settings: ExportSettings) -> Bool {
        guard settings.quality.requiresPro else { return true }
        return entitlements.canApply(.maximumQualityExport)
    }

    var isExporting: Bool {
        outcome == .exporting
    }

    // MARK: - Settings

    /// Selects a format.
    ///
    /// PNG is lossless, so a quality choice would be meaningless alongside it;
    /// selecting PNG drops back to High so the user is never shown — or charged
    /// for — a setting that has no effect.
    func select(format: ExportFormat) {
        settings.format = format
        if !format.isLossy {
            settings.quality = .high
        }
    }

    /// Selects a quality. Always permitted — the gate is at export, not here.
    ///
    /// Spec §26.2: the user configures freely and meets the boundary only when
    /// committing, so Maximum is selectable on the free tier and simply prompts
    /// on export.
    func select(quality: ExportQuality) {
        guard settings.format.isLossy || quality == .high else { return }
        settings.quality = quality
    }

    func setPreservesMetadata(_ preserves: Bool) {
        settings.preservesMetadata = preserves
        // Location is a subset of metadata; it cannot survive its parent being
        // switched off, and leaving the toggle on would misrepresent that.
        if !preserves { settings.preservesLocation = false }
    }

    func setPreservesLocation(_ preserves: Bool) {
        guard settings.preservesMetadata else { return }
        settings.preservesLocation = preserves
    }

    // MARK: - Export

    /// Runs an export.
    ///
    /// The entitlement checkpoint (spec §0.3): everything up to this call is
    /// free, and the paywall appears here rather than as a badge on the option.
    func export(to destination: ExportDestination) {
        guard !isExporting else { return }

        guard isCurrentSelectionEntitled else {
            paywallPrompt = .maximumQualityExport
            return
        }

        outcome = .exporting
        exportTask = Task { [weak self] in
            await self?.performExport(to: destination)
        }
    }

    private func performExport(to destination: ExportDestination) async {
        do {
            let data = try exporter.encode(
                renderedImage,
                originalData: originalData,
                settings: settings
            )

            try Task.checkCancellation()

            switch destination {
            case .photoLibrary:
                try await libraryWriter.save(data, fileExtension: settings.format.fileExtension)
                outcome = .savedToLibrary

            case .share:
                let url = try writeTemporaryFile(data)
                outcome = .readyToShare(url)
            }
        } catch is CancellationError {
            outcome = .idle
        } catch let error as LightlyError {
            outcome = .failed(error)
        } catch {
            outcome = .failed(.exportFailed)
        }
    }

    /// Writes the encoded bytes somewhere the share sheet can reach.
    private func writeTemporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lightly-\(UUID().uuidString)")
            .appendingPathExtension(settings.format.fileExtension)

        do {
            try data.write(to: url)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && error.code == NSFileWriteOutOfSpaceError {
            throw LightlyError.storageFull
        } catch {
            throw LightlyError.exportFailed
        }

        return url
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func dismissPaywall() {
        paywallPrompt = nil
    }

    func dismissOutcome() {
        outcome = .idle
    }

    /// Exposed so tests can await completion deterministically.
    var inFlightExport: Task<Void, Never>? { exportTask }
}
