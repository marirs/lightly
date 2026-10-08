import Foundation

/// Readable preset display names (owner feedback 2026-10-05: "05 Nude Tones 05" is not a finished label), shared with
/// Android: `display-names.json`, validated by shared/look-pack/display_names.py and frozen against stable preset IDs.
/// Only presets whose name changes are listed; ids, Look versions, recipes, favourites and saved edits are untouched.
enum PresetDisplayNames {
    private struct File: Decodable {
        let formatVersion: Int
        let names: [String: String]
    }

    /// Preset id → display name, or empty when the file is missing or of another format (catalogue names are shown).
    static func loadBundled(from bundle: Bundle = .main) -> [String: String] {
        guard let url = bundle.url(forResource: "display-names", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data), file.formatVersion == 1 else { return [:] }
        return file.names
    }
}
