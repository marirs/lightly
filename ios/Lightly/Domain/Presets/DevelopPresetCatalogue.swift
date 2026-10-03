import Foundation

/// The fixed Develop catalogue: categories and preset display names, in display order.
///
/// Read from `develop-design-ui.json`, which the build copies verbatim from
/// `presets/develop-design-ui.json` (the approved catalogue, shared with Android). Slice 1 needs
/// it only to name favourites; slice 2's Develop panel reads the same type.
struct DevelopPresetCatalogue: Sendable, Equatable {

    struct Preset: Sendable, Equatable, Decodable {
        let id: String
        let displayName: String
        /// 1-based position within its category.
        let stop: Int
    }

    struct Category: Sendable, Equatable, Decodable {
        let id: String
        let name: String
        let presets: [Preset]
    }

    /// A preset together with the category it belongs to.
    struct Entry: Sendable, Equatable {
        let preset: Preset
        let category: Category
    }

    let categories: [Category]
    private let entriesByPresetID: [String: Entry]

    init(categories: [Category]) {
        self.categories = categories
        var entries: [String: Entry] = [:]
        for category in categories {
            for preset in category.presets where entries[preset.id] == nil {
                entries[preset.id] = Entry(preset: preset, category: category)
            }
        }
        self.entriesByPresetID = entries
    }

    static let empty = DevelopPresetCatalogue(categories: [])

    func entry(forPresetID id: String) -> Entry? {
        entriesByPresetID[id]
    }

    /// The preset at a 1-based stop of a category, as the prototype addresses them.
    func preset(inCategory categoryID: String, atStop stop: Int) -> Preset? {
        guard let category = categories.first(where: { $0.id == categoryID }),
              category.presets.indices.contains(stop - 1) else { return nil }
        return category.presets[stop - 1]
    }

    // MARK: - Loading

    private struct File: Decodable {
        let schemaVersion: Int
        let categories: [Category]
    }

    /// Supported `schemaVersion` of the catalogue file.
    static let supportedSchemaVersion = 1

    static func decode(_ data: Data) throws -> DevelopPresetCatalogue {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.schemaVersion == supportedSchemaVersion else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported catalogue schema \(file.schemaVersion)"))
        }
        return DevelopPresetCatalogue(categories: file.categories)
    }

    /// The catalogue bundled with the app, or `.empty` when it is missing or unreadable (the
    /// favourites list then shows no names rather than wrong ones).
    static func loadBundled(from bundle: Bundle = .main) -> DevelopPresetCatalogue {
        guard let url = bundle.url(forResource: "develop-design-ui", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalogue = try? decode(data) else { return .empty }
        return catalogue
    }
}
