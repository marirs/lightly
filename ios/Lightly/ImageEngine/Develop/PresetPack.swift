import CryptoKit
import Foundation
import OSLog

/// The Develop preset pack, format 3 (`shared/look-pack/build_pack.py` → `out/manifest.json`):
/// one recipe per preset, no per-preset LUTs. The app bakes each preset's global LUT from its
/// recipe on demand (`DevelopLUTCache`).
///
/// Categories and presets keep manifest order, which is the approved catalogue order
/// (`presets/develop-design-ui.json`, checked by `catalogue.uiSha256`).
struct PresetPack: Sendable {

    struct Preset: Sendable, Equatable, Identifiable {
        let id: String
        let displayName: String
        /// 1-based position in its category (the ruler's stop).
        let stop: Int
        let categoryID: String
        let lookVersion: String
        /// Lightly operators the recipe uses, in pipeline order.
        let operators: [String]
        let recipe: PresetRecipe
        /// complete / approximate / incomplete (separate from validation).
        let completeness: String
        /// Coverage codes: rendered by an approximation, not rendered, deliberately not applied.
        let approximated: [String]
        let unsupported: [String]
        let notApplied: [String]
        /// From the preset's real settings: drives the Effects "added on top" notice (slice 4).
        let hasGrain: Bool
        let hasVignette: Bool
        /// `validation.status`; nothing in today's pack is validated.
        let validationStatus: String
    }

    struct Category: Sendable, Equatable, Identifiable {
        let id: String
        let name: String
        let presets: [Preset]
    }

    let categories: [Category]
    let status: String
    private let presetsByID: [String: Preset]

    init(categories: [Category], status: String) {
        self.categories = categories
        self.status = status
        var index: [String: Preset] = [:]
        for category in categories {
            for preset in category.presets where index[preset.id] == nil { index[preset.id] = preset }
        }
        presetsByID = index
    }

    static let empty = PresetPack(categories: [], status: "missing")

    var isEmpty: Bool { categories.isEmpty }
    var presetCount: Int { presetsByID.count }

    func preset(id: String) -> Preset? { presetsByID[id] }

    func category(id: String) -> Category? { categories.first { $0.id == id } }

    /// How a saved Look reference resolves (EditState schema 2 rules, unchanged in schema 3).
    func resolve(lookID: String, version: String) -> LookReferenceResolution {
        guard let preset = presetsByID[lookID] else { return .unavailable }
        return preset.lookVersion == version ? .available(preset) : .changed(current: preset.lookVersion)
    }
}

/// Resolution of a recipe's `look` against the bundled pack: never substitute.
enum LookReferenceResolution: Equatable, Sendable {
    case available(PresetPack.Preset)
    /// The id is not in this pack: rendered without the Look.
    case unavailable
    /// The id exists with another `lookVersion`: rendered without the Look until the person
    /// accepts the current version (a new undoable step).
    case changed(current: String)
}

/// Why no presets could be loaded at all.
enum PresetPackProblem: Error, Equatable, Sendable {
    case missing
    case unreadableManifest(String)
    case unsupportedFormat(String)
    case unsupportedFormatVersion(Int)
    case unsupportedRecipeVersion(Int)
    case unsupportedRenderingContract(Int)
    /// The pack's lookVersions were computed with other model constants than this build renders with.
    case developModelMismatch(pack: String, app: String)
    /// The pack's categories are not the approved catalogue this build ships.
    case catalogueMismatch(pack: String, app: String)

    var explanation: String {
        switch self {
        case .missing: return "No preset pack in this build (no LookPack/manifest.json)."
        case .unreadableManifest(let detail): return "The preset pack manifest could not be read: \(detail)"
        case .unsupportedFormat(let format): return "\"\(format)\" is not a Lightly preset pack."
        case .unsupportedFormatVersion(let version):
            return "Preset pack format \(version) is not supported; this build reads format \(PresetPackLoader.supportedFormatVersion). "
                + "Rebuild it with shared/look-pack/build_pack.py."
        case .unsupportedRecipeVersion(let version): return "Recipe version \(version) is not supported."
        case .unsupportedRenderingContract(let version): return "Rendering contract \(version) is not supported."
        case .developModelMismatch(let pack, let app):
            return "The pack was built for develop model constants \(pack); this build renders with \(app)."
        case .catalogueMismatch(let pack, let app):
            return "The pack's catalogue (\(pack)) is not this build's approved catalogue (\(app))."
        }
    }
}

/// One preset the loader refused, and why. Reported, never silently skipped.
struct DroppedPreset: Equatable, Sendable {
    let presetID: String
    let reason: String
}

struct PresetPackLoadResult: Sendable {
    let pack: PresetPack
    let problem: PresetPackProblem?
    let droppedPresets: [DroppedPreset]
    /// Manifest read + index time, for the performance evidence (target ≤ 300 ms).
    let parseDuration: Duration
}

/// Reads and checks the format-3 pack. The pack is untrusted input: format, format version, recipe
/// version, rendering contract and model constants must match exactly, or nothing is loaded.
enum PresetPackLoader {

    /// Folder inside the app bundle (copied by `scripts/bundle_look_pack.sh`).
    static let bundleDirectoryName = "LookPack"
    static let manifestFileName = "manifest.json"
    static let supportedFormat = "lightly-look-pack"
    static let supportedFormatVersion = 3
    static let supportedRecipeVersion = 1
    static let supportedRenderingContract = 2

    private static let logger = Logger(subsystem: "com.lightlylabs.lightly", category: "PresetPack")

    static func loadBundled(from bundle: Bundle = .main, model: DevelopModel?) -> PresetPackLoadResult {
        let directory = bundle.resourceURL?.appendingPathComponent(bundleDirectoryName, isDirectory: true)
            ?? bundle.bundleURL.appendingPathComponent(bundleDirectoryName, isDirectory: true)
        let catalogueDigest = bundle.url(forResource: "develop-design-ui", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .map(sha256Hex)
        let result = load(from: directory, model: model, expectedCatalogueSha256: catalogueDigest)
        report(result)
        return result
    }

    static func load(from directory: URL, model: DevelopModel?, expectedCatalogueSha256: String?) -> PresetPackLoadResult {
        let clock = ContinuousClock()
        let start = clock.now
        let url = directory.appendingPathComponent(manifestFileName)
        guard let data = try? Data(contentsOf: url) else {
            return PresetPackLoadResult(pack: .empty, problem: .missing, droppedPresets: [], parseDuration: clock.now - start)
        }
        let outcome = read(data, model: model, expectedCatalogueSha256: expectedCatalogueSha256)
        return PresetPackLoadResult(pack: outcome.pack, problem: outcome.problem, droppedPresets: outcome.dropped,
                                    parseDuration: clock.now - start)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func read(_ data: Data, model: DevelopModel?, expectedCatalogueSha256: String?)
        -> (pack: PresetPack, problem: PresetPackProblem?, dropped: [DroppedPreset]) {
        func failed(_ problem: PresetPackProblem) -> (PresetPack, PresetPackProblem?, [DroppedPreset]) { (.empty, problem, []) }
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return failed(.unreadableManifest("not an object"))
            }
            root = object
        } catch {
            return failed(.unreadableManifest(error.localizedDescription))
        }
        // Header checks come before any preset is read: a pack this build does not understand must
        // not be half-loaded.
        let format = root["format"] as? String ?? ""
        guard format == supportedFormat else { return failed(.unsupportedFormat(format)) }
        let formatVersion = root["formatVersion"] as? Int ?? -1
        guard formatVersion == supportedFormatVersion else { return failed(.unsupportedFormatVersion(formatVersion)) }
        let recipeVersion = root["recipeVersion"] as? Int ?? -1
        guard recipeVersion == supportedRecipeVersion else { return failed(.unsupportedRecipeVersion(recipeVersion)) }
        let contract = (root["renderingContract"] as? [String: Any])?["version"] as? Int ?? -1
        guard contract == supportedRenderingContract else { return failed(.unsupportedRenderingContract(contract)) }
        let packConstants = (root["developModel"] as? [String: Any])?["constantsSha256"] as? String ?? ""
        if let model, packConstants != model.constantsSha256 {
            return failed(.developModelMismatch(pack: packConstants, app: model.constantsSha256))
        }
        let packCatalogue = (root["catalogue"] as? [String: Any])?["uiSha256"] as? String ?? ""
        if let expectedCatalogueSha256, packCatalogue != expectedCatalogueSha256 {
            return failed(.catalogueMismatch(pack: packCatalogue, app: expectedCatalogueSha256))
        }
        guard let rawCategories = root["categories"] as? [[String: Any]] else {
            return failed(.unreadableManifest("no categories"))
        }

        var dropped: [DroppedPreset] = []
        var categories: [PresetPack.Category] = []
        for rawCategory in rawCategories {
            guard let categoryID = rawCategory["id"] as? String, let name = rawCategory["name"] as? String,
                  let rawPresets = rawCategory["presets"] as? [[String: Any]] else {
                return failed(.unreadableManifest("malformed category"))
            }
            var presets: [PresetPack.Preset] = []
            for raw in rawPresets {
                switch readPreset(raw, categoryID: categoryID) {
                case .success(let preset): presets.append(preset)
                case .failure(let reason): dropped.append(DroppedPreset(presetID: raw["id"] as? String ?? "?", reason: reason.description))
                }
            }
            categories.append(PresetPack.Category(id: categoryID, name: name, presets: presets))
        }
        let state = (root["status"] as? [String: Any])?["state"] as? String ?? "unknown"
        return (PresetPack(categories: categories, status: state), nil, dropped)
    }

    private struct PresetError: Error, CustomStringConvertible {
        let description: String
    }

    private static func readPreset(_ raw: [String: Any], categoryID: String) -> Result<PresetPack.Preset, PresetError> {
        guard let id = raw["id"] as? String, let name = raw["displayName"] as? String, let stop = raw["stop"] as? Int,
              let lookVersion = raw["lookVersion"] as? String, let operators = raw["operators"] as? [String],
              let rawRecipe = raw["recipe"], let completeness = raw["completeness"] as? String,
              let effects = raw["effects"] as? [String: Any], let validation = raw["validation"] as? [String: Any] else {
            return .failure(PresetError(description: "missing preset fields"))
        }
        guard raw["recipeVersion"] as? Int == supportedRecipeVersion else {
            return .failure(PresetError(description: "recipe version \(raw["recipeVersion"] ?? "nil")"))
        }
        // DEFERRED(validated overrides): no preset ships a Lightroom HALD override today
        // (rendering-v2 §4.4). One that did would render differently from its recipe, so it is
        // refused and reported rather than rendered from the recipe alone.
        if let override = raw["globalOverride"], !(override is NSNull) {
            return .failure(PresetError(description: "globalOverride is not supported by this build"))
        }
        let recipe: PresetRecipe
        do { recipe = try PresetRecipe(json: rawRecipe) } catch {
            return .failure(PresetError(description: "recipe: \(error)"))
        }
        func codes(_ key: String) -> [String] {
            (raw[key] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
        }
        return .success(PresetPack.Preset(
            id: id, displayName: name, stop: stop, categoryID: categoryID, lookVersion: lookVersion,
            operators: operators, recipe: recipe, completeness: completeness,
            approximated: codes("approximated"), unsupported: codes("unsupported"), notApplied: codes("notApplied"),
            hasGrain: effects["grain"] as? Bool ?? false, hasVignette: effects["vignette"] as? Bool ?? false,
            validationStatus: validation["status"] as? String ?? "unknown"))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func report(_ result: PresetPackLoadResult) {
        if let problem = result.problem {
            logger.error("Preset pack not loaded: \(problem.explanation, privacy: .public)")
        }
        for dropped in result.droppedPresets {
            logger.error("Preset \(dropped.presetID, privacy: .public) dropped: \(dropped.reason, privacy: .public)")
        }
        logger.info("Preset pack: \(result.pack.categories.count) categories, \(result.pack.presetCount) presets, parsed in \(result.parseDuration, privacy: .public)")
    }
}
