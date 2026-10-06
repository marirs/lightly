import Foundation

/// Baked 33³ develop.global LUTs, keyed by `lookVersion` (rendering-v2 §4.2).
///
/// `lookVersion` changes whenever the recipe, the model constants or an override changes, so it is
/// a complete cache key: a hit can never return a LUT for other pixels. Least recently used entries
/// are evicted beyond `capacity` (each LUT is 33³ × 4 floats ≈ 575 KB).
///
/// Thread-safe: renders bake off the main actor. Two threads asking for the same missing LUT may
/// both bake it; the result is identical, so the duplicate work is accepted rather than adding a
/// wait that could stall the latest preview behind an older one.
final class DevelopLUTCache: @unchecked Sendable {
    // @unchecked: every mutable member is guarded by `lock`.

    let model: DevelopModel
    let capacity: Int

    fileprivate let lock = NSLock()
    fileprivate var entries: [String: LUT3D] = [:]
    fileprivate var recency: [String] = []
    fileprivate var bakeDurations: [Duration] = []

    init(model: DevelopModel, capacity: Int = 48) {
        self.model = model
        self.capacity = max(1, capacity)
    }

    /// The coarser LUT a ruler drag previews with (2026-10-06): 17³ bakes about 7× faster than 33³, so each newly
    /// crossed stop shows while the finger moves; the settled selection renders with the contract's 33³.
    static let dragDimension = 17

    /// The preset's global LUT, baked on first use. `dimension` other than the contract's is for drag previews only.
    func lut(for preset: PresetPack.Preset, dimension: Int = LUT3D.contractDimension) -> LUT3D {
        let key = dimension == LUT3D.contractDimension ? preset.lookVersion : "\(preset.lookVersion)#\(dimension)"
        if let hit = cached(key) { return hit }
        let clock = ContinuousClock()
        let start = clock.now
        let baked = DevelopGlobalProgram(recipe: preset.recipe.global, model: model).bakeLUT(dimension: dimension)
        let elapsed = clock.now - start
        lock.withLock {
            bakeDurations.append(elapsed)
            entries[key] = baked
            touch(key)
            while recency.count > capacity {
                entries[recency.removeFirst()] = nil
            }
        }
        return baked
    }

    func contains(lookVersion: String) -> Bool {
        lock.withLock { entries[lookVersion] != nil }
    }

    func containsDragLUT(for preset: PresetPack.Preset) -> Bool {
        lock.withLock { entries["\(preset.lookVersion)#\(Self.dragDimension)"] != nil }
    }

    /// Every bake so far (performance evidence).
    var recordedBakeDurations: [Duration] { lock.withLock { bakeDurations } }

    private func cached(_ key: String) -> LUT3D? {
        lock.withLock {
            guard let hit = entries[key] else { return nil }
            touch(key)
            return hit
        }
    }

    /// Caller holds `lock`.
    private func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

#if DEBUG
extension DevelopLUTCache {
    /// Capture sessions: every screen starts with the cache a fresh launch has (empty).
    func debugRemoveAll() {
        lock.withLock {
            entries.removeAll()
            recency.removeAll()
            bakeDurations.removeAll()
        }
    }
}
#endif
