import CoreGraphics
import Foundation
import Observation
import os

/// State of one Look's thumbnail.
///
/// A failed thumbnail is a first-class state rather than a nil: one Look that
/// cannot render must not blank the grid or block the others (spec §28's
/// principle that failures are defined and contained).
enum ThumbnailState: Equatable, Sendable {
    case loading
    case ready(CGImage)
    case failed

    var image: CGImage? {
        if case .ready(let image) = self { return image }
        return nil
    }
}

/// Drives the Looks screen (spec §7).
@MainActor
@Observable
final class LooksViewModel {

    // MARK: - State

    private(set) var category: PresetCategory = .recommended

    /// Looks in the current category.
    private(set) var presets: [LightlyPreset] = []

    /// Thumbnail state per Look identifier.
    private(set) var thumbnails: [String: ThumbnailState] = [:]

    /// The Look currently being previewed, if any.
    ///
    /// Preview is free for every Look regardless of entitlement (spec §0.3):
    /// the user sees the result before any question of payment arises.
    private(set) var previewedLookID: String?

    /// Intensity for the previewed Look, 0...1.
    private(set) var intensity: Double = 1

    /// Set when the user tries to *apply* a Look they are not entitled to.
    ///
    /// Nil during preview, however long the user explores. This is the only
    /// point at which entitlement is consulted.
    private(set) var paywallPrompt: PaidCapability?

    /// Favourited IDs that no longer resolve to a Look, sorted for stable display.
    ///
    /// Filtered out of the grid rather than shown as broken cells, because a
    /// cell with no recipe cannot be previewed or applied. The IDs are *not*
    /// removed from storage: if a future `PresetIDMigrations` entry maps them,
    /// the favourite comes back without the user re-adding it.
    private(set) var unavailableFavouriteIDs: [String] = []

    // MARK: - Dependencies

    private let catalog: any PresetProviding
    private let thumbnailRenderer: any LookThumbnailRendering
    private let entitlements: any EntitlementResolving
    private let favouritesManager: any FavouritesManaging
    private let thumbnailSource: LookThumbnailSource

    /// In-flight thumbnail work, retained so it can be cancelled when the
    /// category changes or the screen closes.
    private var thumbnailTask: Task<Void, Never>?

    /// Thumbnail edge length in pixels.
    private let thumbnailDimension = 360

    init(
        thumbnailSource: LookThumbnailSource,
        catalog: any PresetProviding,
        thumbnailRenderer: any LookThumbnailRendering,
        entitlements: any EntitlementResolving,
        favouritesManager: any FavouritesManaging = UserDefaultsFavouritesManager()
    ) {
        self.thumbnailSource = thumbnailSource
        self.catalog = catalog
        self.thumbnailRenderer = thumbnailRenderer
        self.entitlements = entitlements
        self.favouritesManager = favouritesManager
    }

    // MARK: - Favourites

    func isFavourite(_ preset: LightlyPreset) -> Bool {
        favouritesManager.isFavourite(presetID: preset.id)
    }

    func toggleFavourite(_ preset: LightlyPreset) {
        favouritesManager.toggleFavourite(presetID: preset.id)
        if category == .favourites {
            load(category: .favourites)
        }
    }

    // MARK: - Derived

    /// Whether the current category's recommendations are genuinely tailored.
    ///
    /// False until scene classification exists. The interface uses this to
    /// describe the set honestly rather than implying personalisation
    /// (spec §7: Recommended must be scene-aware — it is not yet).
    var recommendationsAreSceneAware: Bool { false }

    /// The Look currently previewed.
    ///
    /// Nil when the previewed ID no longer resolves, which makes Apply
    /// unavailable rather than committing some other Look in its place.
    var previewedPreset: LightlyPreset? {
        guard let id = previewedLookID else { return nil }
        return catalog.resolvePreset(id: id).preset
    }

    /// Whether the previewed Look can be applied under the current entitlement.
    var canApplyPreviewedLook: Bool {
        guard let preset = previewedPreset else { return false }
        return isEntitled(to: preset)
    }

    private func isEntitled(to preset: LightlyPreset) -> Bool {
        preset.isIncludedInFreeTier || entitlements.canApply(.fullLooksLibrary)
    }

    // MARK: - Intents

    /// Loads a category and begins rendering its thumbnails.
    ///
    /// Idempotent: re-requesting the category already on screen keeps the
    /// rendered thumbnails rather than discarding and re-rendering them. The
    /// view's `task` fires on every appearance, so without this, dismissing and
    /// reopening the sheet would throw away completed work and flash the grid
    /// back to placeholders.
    func load(category: PresetCategory) {
        guard category != self.category || presets.isEmpty || category == .favourites else { return }

        self.category = category

        if category == .recommended {
            presets = catalog.recommended(for: .unclassified)
        } else if category == .favourites {
            presets = resolveFavourites()
        } else {
            presets = catalog.presets(in: category)
        }

        thumbnails = Dictionary(
            uniqueKeysWithValues: presets.map { ($0.id, ThumbnailState.loading) }
        )

        // Replacing the category abandons the previous category's renders;
        // finishing them would waste work on cells nobody is looking at.
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            await self?.renderThumbnails()
        }
    }

    /// Resolves stored favourites, recording the ones that no longer exist.
    ///
    /// Sorted by ID so the grid order is stable across launches; the stored
    /// favourites are a `Set` and would otherwise reshuffle.
    private func resolveFavourites() -> [LightlyPreset] {
        var resolved: [LightlyPreset] = []
        var unavailable: [String] = []
        for id in favouritesManager.allFavourites().sorted() {
            switch catalog.resolvePreset(id: id) {
            case .found(let preset):
                resolved.append(preset)
            case .unavailable(let requestedID):
                unavailable.append(requestedID)
            }
        }
        if !unavailable.isEmpty {
            Self.logger.notice(
                "Hiding \(unavailable.count) favourite(s) with no matching Look: \(unavailable, privacy: .public)"
            )
        }
        unavailableFavouriteIDs = unavailable
        return resolved
    }

    private static let logger = Logger(subsystem: "com.lightlylabs.lightly", category: "Looks")

    /// Renders each thumbnail, isolating failures to their own cell.
    private func renderThumbnails() async {
        for preset in presets {
            if Task.isCancelled { return }

            do {
                let image = try await thumbnailRenderer.thumbnail(
                    for: preset,
                    from: thumbnailSource,
                    maximumDimension: thumbnailDimension
                )
                guard !Task.isCancelled else { return }
                thumbnails[preset.id] = .ready(image)
            } catch {
                // One Look failing must not blank the grid. The cell shows a
                // placeholder and the remaining Looks continue rendering.
                guard !Task.isCancelled else { return }
                thumbnails[preset.id] = .failed
            }
        }
    }

    /// Previews a Look. Always permitted, for every Look.
    func preview(_ preset: LightlyPreset) {
        previewedLookID = preset.id
        intensity = 1
    }

    /// Clears the preview, returning to the pre-Looks image.
    func clearPreview() {
        previewedLookID = nil
        intensity = 1
    }

    /// Adjusts intensity of the previewed Look.
    func setIntensity(_ value: Double) {
        intensity = max(0, min(1, value))
    }

    /// Attempts to apply the previewed Look.
    ///
    /// The single entitlement checkpoint (spec §0.3, §26.2): everything before
    /// this is free, and nothing in the interface advertises the boundary until
    /// the user reaches it.
    ///
    /// - Returns: The Look and intensity to commit, or `nil` when a paywall was
    ///   raised instead.
    func confirmApplication() -> (preset: LightlyPreset, intensity: Double)? {
        guard let preset = previewedPreset else { return nil }

        guard isEntitled(to: preset) else {
            paywallPrompt = .fullLooksLibrary
            return nil
        }

        return (preset, intensity)
    }

    /// Dismisses the paywall without applying.
    func dismissPaywall() {
        paywallPrompt = nil
    }

    /// Cancels in-flight thumbnail work.
    func cancelThumbnailWork() {
        thumbnailTask?.cancel()
    }

    /// Exposed so tests can await thumbnail completion deterministically.
    var inFlightThumbnailWork: Task<Void, Never>? { thumbnailTask }
}
