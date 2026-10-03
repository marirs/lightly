import Foundation
import Observation

/// Favourite Develop presets: up to five ordered shortcuts (approved Preferences › Favourite
/// presets, and Develop's Favourites category in slice 2).
///
/// Favourites are shortcuts only; nothing here applies a preset. Order is the person's own and
/// is kept exactly as they arrange it.
// v3 differs: the legacy `UserDefaultsFavouritesManager` keeps an unordered, unbounded set of
// Look-pack ids for the legacy Looks screen. The approved model is ordered, capped at five and
// keyed by `presets/develop-design-ui.json` ids, so it lives under its own key; the two never mix.
@MainActor
@Observable
final class FavouritePresetsStore {

    static let capacity = 5
    static let storageKey = "lightly.favouritePresets.v1"

    enum AddOutcome: Equatable {
        case added
        case alreadyFavourite
        /// Five already: the caller offers to replace one (approved "Favourites full").
        case full
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Preset ids in the person's order, at most `capacity`.
    private(set) var presetIDs: [String] {
        didSet { defaults.set(presetIDs, forKey: Self.storageKey) }
    }

    /// - Parameter catalogue: When non-empty, stored ids that are not in it are dropped on load.
    ///   The catalogue is frozen per release, so an unknown id can only come from a damaged
    ///   store; showing it would name a preset that cannot be applied.
    init(defaults: UserDefaults = .standard, catalogue: DevelopPresetCatalogue = .empty) {
        self.defaults = defaults
        var stored = Self.deduplicated(defaults.stringArray(forKey: Self.storageKey) ?? [])
        if !catalogue.categories.isEmpty {
            stored = stored.filter { catalogue.entry(forPresetID: $0) != nil }
        }
        presetIDs = Array(stored.prefix(Self.capacity))
    }

    var freeSlots: Int { Self.capacity - presetIDs.count }

    func contains(_ presetID: String) -> Bool { presetIDs.contains(presetID) }

    @discardableResult
    func add(_ presetID: String) -> AddOutcome {
        if presetIDs.contains(presetID) { return .alreadyFavourite }
        guard presetIDs.count < Self.capacity else { return .full }
        presetIDs.append(presetID)
        return .added
    }

    func remove(_ presetID: String) {
        presetIDs.removeAll { $0 == presetID }
    }

    /// Moves the favourite at `source` so it ends up at index `destination` of the result.
    func move(from source: Int, to destination: Int) {
        guard presetIDs.indices.contains(source), presetIDs.indices.contains(destination), source != destination else { return }
        var reordered = presetIDs
        let moved = reordered.remove(at: source)
        reordered.insert(moved, at: destination)
        presetIDs = reordered
    }

    /// Puts `newPresetID` in the slot of `existingPresetID`, keeping the order.
    func replace(_ existingPresetID: String, with newPresetID: String) {
        guard let index = presetIDs.firstIndex(of: existingPresetID), !presetIDs.contains(newPresetID) else { return }
        presetIDs[index] = newPresetID
    }

    /// Replaces the whole list (DEBUG seeding for comparison captures and UI tests).
    func replaceAll(with presetIDs: [String]) {
        self.presetIDs = Array(Self.deduplicated(presetIDs).prefix(Self.capacity))
    }

    private static func deduplicated(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
