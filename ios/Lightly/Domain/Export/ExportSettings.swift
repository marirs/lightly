import Foundation
import UniformTypeIdentifiers

/// Output container for an exported photograph (spec §14, V1 formats).
///
/// TIFF, 16-bit, and RAW sidecars are Phase 2.
enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case heic
    case jpeg
    case png

    var id: String { rawValue }

    var localizationKey: String { "export.format.\(rawValue)" }

    var utType: UTType {
        switch self {
        case .heic: .heic
        case .jpeg: .jpeg
        case .png: .png
        }
    }

    var fileExtension: String {
        switch self {
        case .heic: "heic"
        case .jpeg: "jpg"
        case .png: "png"
        }
    }

    /// Whether the encoder honours a quality setting.
    ///
    /// PNG is lossless, so offering it a quality slider would be meaningless.
    var isLossy: Bool {
        self != .png
    }
}

/// Output quality (spec §13).
enum ExportQuality: String, CaseIterable, Identifiable, Sendable {
    case high
    case maximum

    var id: String { rawValue }

    var localizationKey: String { "export.quality.\(rawValue)" }

    var compressionQuality: Double {
        switch self {
        // Spec §5.4 fixes Save-copy JPEG quality at 0.92 (was 0.85).
        case .high: 0.92
        case .maximum: 1.0
        }
    }

    /// Whether this quality requires Lightly Pro (spec §26.1).
    var requiresPro: Bool {
        self == .maximum
    }
}

/// How the export should be produced.
struct ExportSettings: Equatable, Sendable {
    var format: ExportFormat
    var quality: ExportQuality

    /// "Keep photo metadata": copy camera, lens, aperture, shutter speed, ISO
    /// and date taken from the original (`ExportMetadataComposer.keptExifKeys`).
    var preservesMetadata: Bool

    /// "Include location": copy the GPS block from the original.
    ///
    /// Defaulted **off**, because location is the one field that discloses
    /// something about the person rather than the photograph.
    // v3 differs: v1 honoured this only while `preservesMetadata` was on. The
    // approved Preferences make the two switches independent.
    var preservesLocation: Bool

    /// The two switches as the encoder's policy.
    var metadataPolicy: ExportMetadataPolicy {
        ExportMetadataPolicy(keepsCaptureMetadata: preservesMetadata, includesLocation: preservesLocation)
    }

    /// Save copy's settings for the person's metadata preferences: always a
    /// new JPEG (spec D8) at the fixed Save-copy quality.
    static func saveCopy(metadata policy: ExportMetadataPolicy) -> ExportSettings {
        var settings = ExportSettings.default
        settings.preservesMetadata = policy.keepsCaptureMetadata
        settings.preservesLocation = policy.includesLocation
        return settings
    }

    static let `default` = ExportSettings(
        // Spec D8: Save creates a new JPEG. HEIC/PNG remain selectable but
        // are no longer the default (the v1 default was HEIC).
        format: .jpeg,
        quality: .high,
        preservesMetadata: true,
        preservesLocation: false
    )
}
