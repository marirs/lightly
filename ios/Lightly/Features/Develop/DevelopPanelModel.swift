import Foundation
import Observation

/// The Develop panel's own state and the rules of the approved `developPanel` (docs/ui/app/app.js):
/// which category is shown, which stop the ruler is on, what the name row and context line say,
/// the Amount control and the favourites flow.
///
/// Browsing (choosing a category, dragging the ruler) never changes the Look by itself. A Look is
/// applied only when the ruler is released on a different stop: one undo step.
@MainActor
@Observable
final class DevelopPanelModel {

    static let favouritesID = "favourites"
    /// The prototype opens on Landscape when no preset is applied (`ui.cat || … : 'landscape'`).
    static let defaultCategoryID = "landscape"

    let session: EditorSession
    let favourites: FavouritePresetsStore

    /// The category the person chose to browse; nil follows the applied preset.
    private(set) var browsedCategoryID: String?
    /// The stop under the needle while dragging (`ui.stop`); nil when settled.
    private(set) var draggingStop: Int?
    /// Hold-still fine control while dragging (`ui.fine`).
    private(set) var isFine = false
    /// The Amount slider replaces the ruler (`ui.amount`).
    private(set) var isAmountOpen = false
    /// The Amount while its slider is being dragged.
    private(set) var draggingAmount: Double?
    /// "Favourites holds five presets." (`ui.favFull`).
    private(set) var isFavouritesFullNoticeShown = false
    /// The Replace a favourite sheet.
    var isReplaceSheetShown = false

    init(session: EditorSession, favourites: FavouritePresetsStore) {
        self.session = session
        self.favourites = favourites
    }

    // MARK: - Categories

    struct CategoryItem: Equatable, Identifiable {
        let id: String
        let name: String
        /// "158", or "2/5" for Favourites.
        let count: String
        let isFavourites: Bool
        /// The applied preset's category (the selection-coloured dot).
        let holdsAppliedPreset: Bool
    }

    var categoryItems: [CategoryItem] {
        let applied = session.appliedPreset
        let favouritesItem = CategoryItem(id: Self.favouritesID, name: "Favourites",
                                          count: "\(favourites.presetIDs.count)/\(FavouritePresetsStore.capacity)",
                                          isFavourites: true, holdsAppliedPreset: false)
        return [favouritesItem] + session.library.pack.categories.map { category in
            CategoryItem(id: category.id, name: category.name, count: "\(category.presets.count)", isFavourites: false,
                         holdsAppliedPreset: applied?.categoryID == category.id)
        }
    }

    var currentCategoryID: String {
        browsedCategoryID ?? session.appliedPreset?.categoryID ?? Self.defaultCategoryID
    }

    var isFavouritesMode: Bool { currentCategoryID == Self.favouritesID }

    /// The presets on the ruler, in stop order.
    var currentPresets: [PresetPack.Preset] {
        if isFavouritesMode {
            return favourites.presetIDs.compactMap { session.library.pack.preset(id: $0) }
        }
        return session.library.pack.category(id: currentCategoryID)?.presets ?? []
    }

    /// Choosing a category only browses it; the applied Look stays.
    func selectCategory(_ id: String) {
        browsedCategoryID = id
        draggingStop = nil
        isAmountOpen = false
    }

    // MARK: - Ruler

    /// The settled stop: the applied preset's position in this list, else 0.
    var settledStop: Int {
        guard let applied = session.appliedPreset else { return 0 }
        guard let index = currentPresets.firstIndex(where: { $0.id == applied.id }) else { return 0 }
        return index + 1
    }

    var stop: Int { draggingStop ?? settledStop }
    var stopCount: Int { currentPresets.count }

    var presetAtStop: PresetPack.Preset? {
        stop > 0 && stop <= currentPresets.count ? currentPresets[stop - 1] : nil
    }

    /// Stop zero reads Auto only when Auto is applied, otherwise Original.
    var baseName: String { session.autoState == .applied ? "Auto" : "Original" }

    var displayedName: String { presetAtStop?.displayName ?? baseName }

    var positionText: String { "\(stop) / \(stopCount)" }

    /// "Applied: …" when another category is browsed and the ruler sits at zero.
    var contextLine: String? {
        guard let applied = session.appliedPreset, presetAtStop == nil, stop == 0 else { return nil }
        let shownHere = isFavouritesMode ? favourites.contains(applied.id) : applied.categoryID == currentCategoryID
        return shownHere ? nil : "Applied: \(applied.displayName)"
    }

    /// The finger moved the needle to `stop`: preview it (photo and labels), commit nothing.
    func dragChanged(to stop: Int) {
        let clamped = min(max(stop, 0), stopCount)
        guard clamped != draggingStop else { return }
        draggingStop = clamped
        session.previewLook(clamped == 0 ? nil : currentPresets[clamped - 1])
    }

    func setFine(_ fine: Bool) { isFine = fine }

    /// Released on `stop`: one undo step if it differs from the applied Look, else nothing.
    func dragEnded(at stop: Int) {
        let clamped = min(max(stop, 0), stopCount)
        draggingStop = nil
        isFine = false
        let target = clamped == 0 ? nil : currentPresets[clamped - 1]
        // Prototype `wireRuler`: commit only when the stop names another Look than the applied one
        // (stop zero means no Look). Releasing where it started changes nothing.
        session.applyLook(target)
    }

    /// VoiceOver increment/decrement: one stop, committed.
    func step(by delta: Int) {
        dragEnded(at: stop + delta)
    }

    // MARK: - Amount

    var amountValue: Double { draggingAmount ?? session.appliedAmount }
    var amountButtonTitle: String { "Amount \(Int(amountValue.rounded()))" }

    func openAmount() { if presetAtStop != nil { isAmountOpen = true } }
    func closeAmount() { isAmountOpen = false }

    func amountChanged(_ value: Double) {
        draggingAmount = value.rounded()
        session.previewAmount(value)
    }

    func amountEnded(_ value: Double) {
        draggingAmount = nil
        session.commitAmount(value)
    }

    // MARK: - Favourites

    var isPresetAtStopFavourite: Bool { presetAtStop.map { favourites.contains($0.id) } ?? false }

    /// The star: add, remove, or (with five already) the full notice.
    func toggleStar() {
        guard let preset = session.appliedPreset ?? presetAtStop else { return }
        if favourites.contains(preset.id) {
            favourites.remove(preset.id)
        } else if favourites.add(preset.id) == .full {
            isFavouritesFullNoticeShown = true
        }
    }

    func dismissFavouritesFullNotice() { isFavouritesFullNoticeShown = false }

    /// Replace a favourite › Replace: the applied preset takes that slot.
    func replaceFavourite(_ existingID: String) {
        guard let applied = session.appliedPreset else { return }
        favourites.replace(existingID, with: applied.id)
        isReplaceSheetShown = false
        isFavouritesFullNoticeShown = false
    }

    // MARK: - Debug (design captures)

    #if DEBUG
    func debugSetDragging(stop: Int, fine: Bool) {
        draggingStop = stop
        isFine = fine
        session.previewLook(stop == 0 ? nil : currentPresets[stop - 1])
    }
    func debugShowFavouritesFull() { isFavouritesFullNoticeShown = true }
    func debugOpenAmount() { isAmountOpen = true }
    #endif
}
