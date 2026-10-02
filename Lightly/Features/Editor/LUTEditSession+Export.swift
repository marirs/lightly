import CoreGraphics
import Foundation

extension LUTEditSession {

    /// Encodes the committed edit at full resolution (spec §5.4).
    ///
    /// The committed state is snapshotted at the call: a transient Look
    /// preview is never exported. The full-resolution original is rendered
    /// with the same passes as the preview, tiled (≤2048²) so GPU memory does
    /// not scale with the frame, then encoded once by `exporter` (sRGB JPEG
    /// by default). Runs off the main actor: a 48 MP render takes seconds.
    func exportData(
        exporter: any PhotoExporting = ImageIOPhotoExporter(),
        settings: ExportSettings = .default
    ) async throws -> Data {
        let passes = passes(for: committedState)
        let original = photo.image
        let originalData = photo.originalData
        let renderer = renderer
        return try await Task.detached(priority: .userInitiated) {
            let pixels = try MetalLUTRenderer.rgba8Bytes(of: original)
            let output = try renderer.apply(
                passes, toRGBA8: pixels, width: original.width, height: original.height,
                maximumTileSide: MetalLUTRenderer.defaultMaximumTileSide
            )
            let rendered = try MetalLUTRenderer.makeImage(rgba8: output, width: original.width, height: original.height)
            return try exporter.encode(rendered, originalData: originalData, settings: settings)
        }.value
    }

    /// Saves the committed edit as a new photo (spec D8: a new JPEG; the
    /// original is never modified).
    func saveCopy(
        to writer: any PhotoLibraryWriting,
        exporter: any PhotoExporting = ImageIOPhotoExporter(),
        settings: ExportSettings = .default
    ) async throws {
        let data = try await exportData(exporter: exporter, settings: settings)
        try await writer.save(data, fileExtension: settings.format.fileExtension)
    }
}
