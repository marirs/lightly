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

    /// Copy capture date, camera, and lens from the original.
    var preservesMetadata: Bool

    /// Copy GPS coordinates from the original.
    ///
    /// Separate from `preservesMetadata`, and defaulted **off**, because
    /// location is the one field that discloses something about the person
    /// rather than the photograph. Spec §13 lists it as its own setting for
    /// exactly this reason. The export sheet shows both switches so the choice
    /// is visible rather than buried in a default.
    var preservesLocation: Bool

    static let `default` = ExportSettings(
        // Deferred (spec D8 wants JPEG): switching the default changes the
        // recorded export-sheet snapshots, which needs an approved re-record.
        format: .heic,
        quality: .high,
        preservesMetadata: true,
        preservesLocation: false
    )
}
