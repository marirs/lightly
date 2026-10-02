import Foundation

/// Explicit, reviewable renames of shipped Look identifiers.
///
/// Look IDs are persisted in favourites and edit history, so a renamed ID must
/// be carried forward deliberately rather than guessed. Before this table the
/// catalogue matched by bidirectional prefix and fell back to "any golden-hour
/// Look" for IDs containing "gold" — which silently swapped a user's favourite
/// for an unrelated recipe. Only true renames (same recipe, new ID) belong
/// here; a removed Look must stay unresolvable so callers can say so.
struct PresetIDMigrations: Sendable, Equatable {

    /// Old ID → new ID.
    let renames: [String: String]

    /// Upper bound on rename chains, so a cycle introduced by a bad edit to
    /// the table terminates instead of hanging lookup.
    private static let maximumChainLength = 16

    init(renames: [String: String]) {
        self.renames = renames
    }

    /// Renames shipped with the app.
    ///
    /// Intentionally empty: the ID set in `presets_photo.json` has been
    /// identical since ingestion (verified across commits a6751bc..f7336fb).
    /// The hand-written starter IDs that predate ingestion (e.g.
    /// `film.golden-memory`) were *replaced* by different recipes, not
    /// renamed, so mapping them would be inventing an equivalence.
    static let shipped = PresetIDMigrations(renames: [:])

    /// Follows the rename chain from `id` to its current identifier.
    ///
    /// Returns `id` unchanged when no rename applies.
    func currentID(for id: String) -> String {
        var resolved = id
        var visited: Set<String> = [id]
        for _ in 0..<Self.maximumChainLength {
            guard let next = renames[resolved], visited.insert(next).inserted else {
                return resolved
            }
            resolved = next
        }
        return resolved
    }
}

/// The outcome of resolving a persisted Look identifier.
///
/// A dedicated type rather than an optional so that "this Look no longer
/// exists" is something every caller has to handle by name, instead of a nil
/// that is easy to `compactMap` away or paper over with a substitute.
enum PresetLookupResult: Equatable, Sendable {
    case found(LightlyPreset)
    /// No Look has this ID, even after applying migrations. Carries the ID the
    /// caller asked for so it can be reported or kept for later recovery.
    case unavailable(requestedID: String)

    var preset: LightlyPreset? {
        if case .found(let preset) = self { return preset }
        return nil
    }
}
