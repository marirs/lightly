import Foundation

/// Baked 33³ develop.global LUTs, keyed by `lookVersion` (rendering-v2 §4.2). Table looks share the cache:
/// their LUT is read from the pack's `luts/` file instead of baked (`GlobalTableLoader`).
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

    /// The preset's global LUT, baked (or, for a table look, read) on first use. `dimension` other than the
    /// contract's is for drag previews only.
    ///
    /// Throws only for a table look whose file is missing, the wrong size or not the file the manifest names
    /// (`GlobalTableError`); a recipe bake cannot fail.
    func lut(for preset: PresetPack.Preset, dimension: Int = LUT3D.contractDimension) throws -> LUT3D {
        let key = Self.key(lookVersion: preset.lookVersion, dimension: dimension)
        if let hit = cached(key) { return hit }
        if let table = preset.globalTable {
            let lut = try tableLUT(table, lookVersion: preset.lookVersion, dimension: dimension)
            store(lut, key: key)
            return lut
        }
        let clock = ContinuousClock()
        let start = clock.now
        let baked = DevelopGlobalProgram(recipe: preset.recipe.global, model: model).bakeLUT(dimension: dimension)
        let elapsed = clock.now - start
        lock.withLock { bakeDurations.append(elapsed) }
        store(baked, key: key)
        return baked
    }

    /// The table at `dimension`. A coarser LUT is resampled from the cached 33³ one, so the file is read and its
    /// digest checked once while that entry stays cached (again only after eviction, which re-verifies it).
    private func tableLUT(_ table: GlobalTableRef, lookVersion: String, dimension: Int) throws -> LUT3D {
        guard dimension != table.dimension else { return try GlobalTableLoader.load(table) }
        let fullKey = Self.key(lookVersion: lookVersion, dimension: table.dimension)
        let full: LUT3D
        if let hit = cached(fullKey) {
            full = hit
        } else {
            full = try GlobalTableLoader.load(table)
            store(full, key: fullKey)
        }
        return GlobalTableLoader.resample(full, toDimension: dimension)
    }

    private static func key(lookVersion: String, dimension: Int) -> String {
        dimension == LUT3D.contractDimension ? lookVersion : "\(lookVersion)#\(dimension)"
    }

    private func store(_ lut: LUT3D, key: String) {
        lock.withLock {
            entries[key] = lut
            touch(key)
            while recency.count > capacity {
                entries[recency.removeFirst()] = nil
            }
        }
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
