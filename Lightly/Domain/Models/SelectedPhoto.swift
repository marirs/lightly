import CoreGraphics
import Foundation

/// A photograph the user has chosen, before any development has occurred.
///
/// Holds the decoded image plus the provenance needed later by the editor. The
/// original is never mutated (spec §2.6, non-destructive editing) — this value
/// is the immutable root that the edit history (§27) will branch from.
struct SelectedPhoto: Identifiable, Sendable {
    let id: UUID
    /// The decoded, orientation-normalised image.
    let image: CGImage
    /// Where the photograph came from, for analytics and UI affordances.
    let source: PhotoSource
    /// Pixel dimensions after orientation normalisation.
    let pixelSize: CGSize

    /// The colour space of the source image (spec §15.4).
    ///
    /// Tracked explicitly so the rendering pipeline and export can produce
    /// output in the same colour space as the source. A Display P3 photograph
    /// must stay P3 through editing and export; silently flattening it to sRGB
    /// would lose the extended gamut the photographer intended to capture.
    let colorSpace: CGColorSpace

    /// The bytes the photograph was decoded from.
    ///
    /// Retained because a `CGImage` carries no EXIF, and export must be able to
    /// copy capture date, camera, lens, and optionally location from the source
    /// (spec §14). Discarding this at ingest would silently strip metadata from
    /// every exported photograph with no way to recover it.
    ///
    /// The cost is one encoded copy in memory — a few megabytes for a typical
    /// capture. Phase 2 may move this to a file-backed reference when RAW
    /// support arrives and sizes grow.
    let originalData: Data

    init(id: UUID = UUID(), image: CGImage, source: PhotoSource, originalData: Data) {
        self.id = id
        self.image = image
        self.source = source
        self.pixelSize = CGSize(width: image.width, height: image.height)
        self.colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        self.originalData = originalData
    }
}
