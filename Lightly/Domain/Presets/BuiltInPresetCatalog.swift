import Foundation
import os

/// The first-party catalog of Looks (spec §6, §7).
///
/// Built from the converted preset collection in `presets_photo.json`, which
/// is loaded only from an app (or injected test) bundle — see `load(from:)`.
/// Indexes presets by category for $O(1)$ lookup and rapid filtering.
struct BuiltInPresetCatalog: PresetProviding {

    /// Number of Looks surfaced in the first viewport.
    static let recommendedCount = 6

    private let all: [LightlyPreset]
    private let byCategory: [PresetCategory: [LightlyPreset]]
    private let byID: [String: LightlyPreset]
    private let migrations: PresetIDMigrations

    /// Set only when `bundled(from:)` could not load the resource.
    let loadFailure: PresetCatalogLoadError?

    /// Builds a catalogue from already-decoded presets.
    ///
    /// Bundle loading lives in `load(from:)` so that failure is a thrown,
    /// typed error rather than a hidden side effect of initialisation.
    init(
        presets: [LightlyPreset],
        migrations: PresetIDMigrations = .shipped,
        loadFailure: PresetCatalogLoadError? = nil
    ) {
        self.migrations = migrations
        self.loadFailure = loadFailure
        self.all = presets

        var catMap: [PresetCategory: [LightlyPreset]] = [:]
        var idMap: [String: LightlyPreset] = [:]

        for preset in self.all {
            catMap[preset.category, default: []].append(preset)
            idMap[preset.id] = preset
        }

        self.byCategory = catMap
        self.byID = idMap
    }

    func presets(in category: PresetCategory) -> [LightlyPreset] {
        guard category != .recommended else {
            return recommended(for: .unclassified)
        }
        return byCategory[category] ?? []
    }

    func recommended(for scene: SceneKind) -> [LightlyPreset] {
        let free = all.filter { $0.isIncludedInFreeTier }
        let pro = all.filter { !$0.isIncludedInFreeTier }

        var result: [LightlyPreset] = []
        result.append(contentsOf: free.prefix(2))
        result.append(contentsOf: pro.prefix(4))

        if result.count < Self.recommendedCount {
            return Array(all.prefix(Self.recommendedCount))
        }
        return result
    }

    /// Exact lookup after applying explicit migrations.
    ///
    /// v1 differs: there is no prefix or "gold" substring fallback any more.
    /// Those substituted an unrelated Look for a missing one; an unknown ID is
    /// now reported as `.unavailable` and the caller decides what to show.
    func resolvePreset(id requestedID: String) -> PresetLookupResult {
        let currentID = migrations.currentID(for: requestedID)
        guard let preset = byID[currentID] else {
            return .unavailable(requestedID: requestedID)
        }
        return .found(preset)
    }

    // MARK: - Bundle Loading

    /// Name of the bundled preset database, without extension.
    static let bundledResourceName = "presets_photo"

    private struct PresetPayload: Decodable {
        let version: String
        let totalCount: Int
        let presets: [LightlyPreset]
    }

    /// Loads the catalogue from `bundle`, throwing a typed error on failure.
    ///
    /// v3 differs: v1 tried Bundle.main, two hand-built bundle paths and an
    /// absolute path on the developer's machine, then returned an empty
    /// catalogue on any failure. A missing or corrupt resource is a build
    /// defect, so it is now reported rather than hidden behind an empty grid.
    static func load(
        from bundle: Bundle,
        resourceName: String = bundledResourceName,
        migrations: PresetIDMigrations = .shipped
    ) throws -> BuiltInPresetCatalog {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw PresetCatalogLoadError.resourceMissing(resourceName: resourceName)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PresetCatalogLoadError.unreadable(resourceName: resourceName, reason: "\(error)")
        }
        do {
            let payload = try JSONDecoder().decode(PresetPayload.self, from: data)
            return BuiltInPresetCatalog(presets: payload.presets, migrations: migrations)
        } catch {
            throw PresetCatalogLoadError.decodingFailed(resourceName: resourceName, reason: "\(error)")
        }
    }

    /// The app's catalogue, for composition roots that cannot propagate errors.
    ///
    /// On failure this logs a fault, trips an assertion in debug builds, and
    /// returns an empty catalogue carrying the error in `loadFailure` — so the
    /// condition shows in logs, stops development builds, and stays
    /// distinguishable from "no Looks" instead of silently presenting nothing.
    static func bundled(from bundle: Bundle = .main) -> BuiltInPresetCatalog {
        do {
            return try load(from: bundle)
        } catch {
            let failure = error as? PresetCatalogLoadError
                ?? .unreadable(resourceName: bundledResourceName, reason: "\(error)")
            logger.fault("Preset catalogue failed to load: \(String(describing: failure), privacy: .public)")
            assertionFailure("Preset catalogue failed to load: \(failure)")
            return BuiltInPresetCatalog(presets: [], loadFailure: failure)
        }
    }

    private static let logger = Logger(subsystem: "com.lightlylabs.lightly", category: "Presets")
}

/// Why the bundled preset catalogue could not be loaded.
enum PresetCatalogLoadError: Error, Equatable, Sendable {
    case resourceMissing(resourceName: String)
    case unreadable(resourceName: String, reason: String)
    case decodingFailed(resourceName: String, reason: String)
}
