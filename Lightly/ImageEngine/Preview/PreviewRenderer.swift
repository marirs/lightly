import CoreGraphics
import CoreImage
import Foundation

/// Provides two rendering paths: fast preview for interactive editing and
/// full-resolution for export (spec §15.3).
///
/// During editing, every recipe change — Develop, Look application, intensity
/// slider drag — triggers a re-render. Doing this at full resolution (e.g.,
/// 4032×3024 for a 12MP capture) wastes time producing pixels the display
/// cannot show. Preview rendering downsamples once and renders against the
/// smaller image, keeping interactions responsive.
///
/// Export calls `renderFullResolution`, which uses the original pixels so the
/// output file matches the source dimensions.
actor PreviewRenderer {
    private let renderer = RecipeRenderer()
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    
    /// Maximum pixel dimension of the preview image.
    private let maximumPreviewDimension: Int
    
    /// Cached downsampled base image, keyed by source content identity.
    ///
    /// v3 differs: v1 keyed on width×height, so a second photo with the same
    /// dimensions was rendered from the first photo's pixels.
    private var previewBase: (source: PhotoFingerprint, image: CGImage)?
    
    init(maximumPreviewDimension: Int = 1290) {
        self.maximumPreviewDimension = maximumPreviewDimension
    }
    
    /// Renders a recipe at preview resolution for display during editing.
    func renderPreview(
        _ source: CGImage,
        identity: PhotoFingerprint,
        with recipe: DevelopRecipe
    ) throws -> CGImage {
        let base = try downsample(source, identity: identity)
        return try renderer.render(base, with: recipe)
    }
    
    /// Renders a recipe at full resolution for export.
    func renderFullResolution(
        _ source: CGImage,
        with recipe: DevelopRecipe
    ) throws -> CGImage {
        try renderer.render(source, with: recipe)
    }
    
    /// Produces a reduced-resolution copy, preserving aspect ratio.
    /// Returns the source untouched when already small enough.
    private func downsample(_ source: CGImage, identity: PhotoFingerprint) throws -> CGImage {
        if let cached = previewBase, cached.source == identity {
            return cached.image
        }

        let longestSide = max(source.width, source.height)
        guard longestSide > maximumPreviewDimension else {
            previewBase = (identity, source)
            return source
        }
        
        let scale = Double(maximumPreviewDimension) / Double(longestSide)
        let scaled = CIImage(cgImage: source).transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        
        guard let output = context.createCGImage(scaled, from: scaled.extent) else {
            throw LightlyError.developFailed
        }
        
        previewBase = (identity, output)
        return output
    }
    
    /// Invalidates the cached preview base.
    /// Call when the source photo changes (e.g., new photo loaded).
    func invalidateCache() {
        previewBase = nil
    }
}
