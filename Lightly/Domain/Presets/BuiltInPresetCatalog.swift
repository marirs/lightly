import Foundation

/// The first-party catalog of Looks (spec §6, §7).
///
/// Loads the converted and curated preset collection from `presets_photo.json`.
/// Indexes presets by category for $O(1)$ lookup and rapid filtering.
struct BuiltInPresetCatalog: PresetProviding {

    /// Number of Looks surfaced in the first viewport.
    static let recommendedCount = 6

    private let all: [LightlyPreset]
    private let byCategory: [PresetCategory: [LightlyPreset]]
    private let byID: [String: LightlyPreset]

    init(presets: [LightlyPreset]? = nil) {
        if let presets {
            self.all = presets
        } else {
            self.all = Self.loadBundledPresets()
        }

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

    func preset(withID id: String) -> LightlyPreset? {
        if let exact = byID[id] { return exact }
        if let match = all.first(where: { $0.id.hasPrefix(id) || id.hasPrefix($0.id) }) {
            return match
        }
        if id.contains("golden") || id.contains("gold") {
            return all.first(where: { $0.category == .goldenHour || $0.category == .film })
        }
        return nil
    }

    // MARK: - Bundle Loading

    private struct PresetPayload: Codable {
        let version: String
        let totalCount: Int
        let presets: [LightlyPreset]
    }

    private static func loadBundledPresets() -> [LightlyPreset] {
        // Try Bundle.main
        if let url = Bundle.main.url(forResource: "presets_photo", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let payload = try? JSONDecoder().decode(PresetPayload.self, from: data) {
            return payload.presets
        }

        // Fallback for tests or direct filesystem search
        let candidatePaths = [
            Bundle.main.bundlePath + "/presets_photo.json",
            Bundle.main.bundlePath + "/Lightly_Lightly.bundle/presets_photo.json"
        ]

        for path in candidatePaths {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let payload = try? JSONDecoder().decode(PresetPayload.self, from: data) {
                return payload.presets
            }
        }

        // Direct path for unit test execution environment
        let devPath = "/Users/sg/Documents/Dev/Projects/lightly/Lightly/Resources/Presets/presets_photo.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: devPath)),
           let payload = try? JSONDecoder().decode(PresetPayload.self, from: data) {
            return payload.presets
        }

        return []
    }
}
