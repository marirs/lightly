import Foundation

/// Manages user's favourite preset identifiers (spec §7).
protocol FavouritesManaging: Sendable {
    /// Whether a Look is currently favourited.
    func isFavourite(presetID: String) -> Bool

    /// Toggles favourite state for a Look.
    func toggleFavourite(presetID: String)

    /// Returns the set of all favourited preset IDs.
    func allFavourites() -> Set<String>
}

/// UserDefaults-backed persistence for favourite Looks.
final class UserDefaultsFavouritesManager: FavouritesManaging, @unchecked Sendable {
    private let key = "lightly.user.favourite_presets"
    private let userDefaults: UserDefaults
    private let lock = NSLock()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func isFavourite(presetID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let current = storedFavourites()
        return current.contains(presetID)
    }

    func toggleFavourite(presetID: String) {
        lock.lock()
        defer { lock.unlock() }
        var current = storedFavourites()
        if current.contains(presetID) {
            current.remove(presetID)
        } else {
            current.insert(presetID)
        }
        userDefaults.set(Array(current), forKey: key)
    }

    func allFavourites() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return storedFavourites()
    }

    private func storedFavourites() -> Set<String> {
        guard let list = userDefaults.stringArray(forKey: key) else { return [] }
        return Set(list)
    }
}
