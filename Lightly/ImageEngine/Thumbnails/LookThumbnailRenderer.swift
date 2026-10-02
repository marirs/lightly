import CoreGraphics
import CoreImage
import Foundation

/// The photograph and edit a Look thumbnail is rendered onto.
///
/// Carries an explicit content identity alongside the pixels so caches can
/// key on *which* photo this is, not merely its size.
struct LookThumbnailSource: Sendable {
    let image: CGImage
    let fingerprint: PhotoFingerprint
    /// The committed edit the Look is composed onto.
    let editBase: DevelopRecipe

    init(image: CGImage, fingerprint: PhotoFingerprint, editBase: DevelopRecipe) {
        self.image = image
        self.fingerprint = fingerprint
        self.editBase = editBase
    }

    init(photo: SelectedPhoto, editBase: DevelopRecipe) {
        self.init(image: photo.image, fingerprint: photo.fingerprint, editBase: editBase)
    }
}

/// Renders Look preview thumbnails from the user's own photograph (spec §7).
///
/// Thumbnails are rendered at reduced resolution; full resolution is produced
/// only when a Look is confirmed or exported. Rendering nine full-size variants
/// to fill a grid would stall the interface and burn battery for pixels nobody
/// sees at 100pt square.
protocol LookThumbnailRendering: Sendable {
    /// Produces a preview of `preset` composed onto `source`.
    ///
    /// - Throws: `LightlyError.developFailed` if the preview cannot be rendered.
    func thumbnail(
        for preset: LightlyPreset,
        from source: LookThumbnailSource,
        maximumDimension: Int
    ) async throws -> CGImage
}

/// Everything that determines a thumbnail's pixels.
///
/// The Look is keyed by ID *and* its full recipe because presets carry no
/// version number; comparing the recipe value itself (rather than a hash of
/// it) means an edited Look can never collide with its previous render.
struct LookThumbnailCacheKey: Hashable, Sendable {
    let source: PhotoFingerprint
    let editBase: DevelopRecipe
    let lookID: String
    let lookRecipe: DevelopRecipe
    let maximumDimension: Int
}

/// Core Image implementation.
///
/// Downsamples once per (photo, size) and caches rendered thumbnails, so a
/// grid of Looks costs one downsample plus one filter pass each, and
/// reopening the grid for the same photo and edit costs nothing.
actor CoreImageThumbnailRenderer: LookThumbnailRendering {

    private struct DownsampleKey: Hashable {
        let source: PhotoFingerprint
        let maximumDimension: Int
    }

    private let context = ColorPipeline.makeContext()
    private let renderer = RecipeRenderer()

    private var downsampledBases = BoundedCache<DownsampleKey, CGImage>(capacity: 2)
    private var thumbnails: BoundedCache<LookThumbnailCacheKey, CGImage>

    /// Counters for tests and diagnostics.
    private(set) var cacheHits = 0
    private(set) var cacheMisses = 0

    /// - Parameter thumbnailCapacity: Rendered thumbnails kept. At 360 px each
    ///   is ≈0.5 MB, so the default bounds the cache near 30 MB.
    init(thumbnailCapacity: Int = 60) {
        thumbnails = BoundedCache(capacity: thumbnailCapacity)
    }

    func thumbnail(
        for preset: LightlyPreset,
        from source: LookThumbnailSource,
        maximumDimension: Int
    ) async throws -> CGImage {
        let key = LookThumbnailCacheKey(
            source: source.fingerprint,
            editBase: source.editBase,
            lookID: preset.id,
            lookRecipe: preset.recipe,
            maximumDimension: maximumDimension
        )
        if let cached = thumbnails.value(for: key) {
            cacheHits += 1
            return cached
        }
        cacheMisses += 1

        let base = try downsample(source, to: maximumDimension)
        let rendered = try renderer.render(base, with: Self.recipe(composing: preset, onto: source.editBase))
        thumbnails.insert(rendered, for: key)
        return rendered
    }

    /// The recipe to render.
    ///
    /// An identity base returns the Look's recipe untouched rather than going
    /// through `combined(with:)`, whose grading/grain merge rules are not a
    /// strict identity; this keeps today's original-based thumbnails
    /// byte-for-byte unchanged.
    private static func recipe(composing preset: LightlyPreset, onto base: DevelopRecipe) -> DevelopRecipe {
        base.isIdentity ? preset.recipe : base.combined(with: preset.recipe)
    }

    /// Produces a reduced-resolution copy, preserving aspect ratio.
    ///
    /// Returns the source untouched when it is already small enough, avoiding a
    /// pointless re-encode.
    private func downsample(_ source: LookThumbnailSource, to maximumDimension: Int) throws -> CGImage {
        let key = DownsampleKey(source: source.fingerprint, maximumDimension: maximumDimension)
        if let cached = downsampledBases.value(for: key) {
            return cached
        }

        let image = source.image
        let longestSide = max(image.width, image.height)
        guard longestSide > maximumDimension else {
            downsampledBases.insert(image, for: key)
            return image
        }

        let scale = Double(maximumDimension) / Double(longestSide)
        let scaled = CIImage(cgImage: image).transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )

        guard let output = ColorPipeline.renderSRGB(scaled, in: context) else {
            throw LightlyError.developFailed
        }

        downsampledBases.insert(output, for: key)
        return output
    }
}

/// A small least-recently-used cache.
///
/// Linear bookkeeping is deliberate: capacities here are tens of entries, and
/// a value type keeps it trivially isolated inside the owning actor.
struct BoundedCache<Key: Hashable, Value> {
    let capacity: Int
    private var storage: [Key: Value] = [:]
    private var recency: [Key] = []

    init(capacity: Int) {
        precondition(capacity > 0, "A cache that can hold nothing is a bug at the call site")
        self.capacity = capacity
    }

    var count: Int { storage.count }

    mutating func value(for key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        markRecentlyUsed(key)
        return value
    }

    mutating func insert(_ value: Value, for key: Key) {
        storage[key] = value
        markRecentlyUsed(key)
        while recency.count > capacity {
            storage.removeValue(forKey: recency.removeFirst())
        }
    }

    mutating func removeAll() {
        storage.removeAll()
        recency.removeAll()
    }

    private mutating func markRecentlyUsed(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}
