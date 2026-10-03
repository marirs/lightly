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

    init(model: DevelopModel, capacity: Int = 24) {
        self.model = model
        self.capacity = max(1, capacity)
    }

    /// The preset's global LUT, baked on first use.
    func lut(for preset: PresetPack.Preset) -> LUT3D {
        if let hit = cached(preset.lookVersion) { return hit }
        let clock = ContinuousClock()
        let start = clock.now
        let baked = DevelopGlobalProgram(recipe: preset.recipe.global, model: model).bakeLUT()
        let elapsed = clock.now - start
        lock.withLock {
            bakeDurations.append(elapsed)
            entries[preset.lookVersion] = baked
            touch(preset.lookVersion)
            while recency.count > capacity {
                entries[recency.removeFirst()] = nil
            }
        }
        return baked
    }

    func contains(lookVersion: String) -> Bool {
        lock.withLock { entries[lookVersion] != nil }
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
