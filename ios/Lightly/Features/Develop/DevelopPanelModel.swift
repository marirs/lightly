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
    private var startsAtFirst = false
    var isBrowsingStart: Bool { startsAtFirst && browsedAtHistoryRevision == session.historyRevision }
    /// The session's history revision when browsing began (or the panel last committed). Undo, Redo or a step made
    /// elsewhere moves it, and browsing then returns to the applied preset's category (owner amendment 2026-10-05:
    /// underline, dot and photo agree).
    private var browsedAtHistoryRevision: Int?
    /// The stop under the needle while dragging (`ui.stop`); nil when settled.
    private(set) var draggingStop: Int?
    /// The stop a drag started from; releasing there changes nothing.
    @ObservationIgnored private var dragStartStop: Int?
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

    /// A category tab. No preset count (owner amendment 2026-10-05): the position shows once, beside the name.
    struct CategoryItem: Equatable, Identifiable {
        let id: String
        let name: String
        let isFavourites: Bool
        /// The applied preset's category (the selection-coloured dot).
        let holdsAppliedPreset: Bool
    }

    var categoryItems: [CategoryItem] {
        let applied = session.appliedPreset
        let favouritesItem = CategoryItem(id: Self.favouritesID, name: "Favourites", isFavourites: true,
                                          holdsAppliedPreset: applied.map { favourites.contains($0.id) } ?? false)
        return [favouritesItem] + session.library.pack.categories.filter { $0.id != "portrait" || session.hasPerson == true }.map { category in
            CategoryItem(id: category.id, name: category.name, isFavourites: false,
                         holdsAppliedPreset: applied?.categoryID == category.id)
        }
    }

    /// The browsed category (the orange underline): the one chosen, until the history moves; then the applied
    /// preset's category.
    var currentCategoryID: String {
        let browsing = browsedAtHistoryRevision == session.historyRevision ? browsedCategoryID : nil
        let available = Set(categoryItems.map(\.id))
        if let browsing, available.contains(browsing) { return browsing }
        if let applied = session.appliedPreset?.categoryID, available.contains(applied) { return applied }
        return favourites.presetIDs.isEmpty ? Self.defaultCategoryID : Self.favouritesID
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
        startsAtFirst = true
        dragStartStop = nil
        session.cancelLookPreview()
        browsedCategoryID = id
        browsedAtHistoryRevision = session.historyRevision
        draggingStop = nil
        isAmountOpen = false
    }

    // MARK: - Ruler

    /// The settled stop: the applied preset's position in this list, else 0.
    var settledStop: Int {
        if isBrowsingStart { return currentPresets.isEmpty ? 0 : 1 }
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
    var baseName: String { "" }

    /// The applied preset while it is not on this category's ruler and the ruler is at rest: the name row then
    /// shows it, never "Original" (owner amendment 2026-10-05). Dragging to stop zero previews the original and says so.
    var appliedPresetOffRuler: PresetPack.Preset? {
        guard !isBrowsingStart, draggingStop == nil, presetAtStop == nil, let applied = session.appliedPreset else { return nil }
        return applied
    }

    /// The preset the name row, star and Amount refer to.
    var namedPreset: PresetPack.Preset? { presetAtStop ?? appliedPresetOffRuler }

    var displayedName: String { namedPreset?.displayName ?? baseName }

    /// The ruler's position beside the name ("12 / 158"). Empty while the name row shows a preset applied from
    /// another category: a position there would read as this ruler's, so the applied preset's own position goes
    /// into the context line instead (owner request 2026-10-05: name, position and ruler must not mix states).
    var positionText: String {
        appliedPresetOffRuler == nil ? "\(stop) / \(stopCount)" : ""
    }

    /// Under the name, while another category is browsed: the applied preset's category and its place there
    /// ("Applied from Landscape · 37 / 518").
    var contextLine: String? {
        guard let applied = appliedPresetOffRuler, let category = session.library.pack.category(id: applied.categoryID) else { return nil }
        guard let index = category.presets.firstIndex(where: { $0.id == applied.id }) else { return "Applied from \(category.name)" }
        return "Applied from \(category.name) · \(index + 1) / \(category.presets.count)"
    }

    /// The finger moved the needle to `stop`: preview it (photo and labels), commit nothing.
    func dragChanged(to stop: Int) {
        if draggingStop == nil { dragStartStop = self.stop }
        let clamped = min(max(stop, 0), stopCount)
        guard clamped != draggingStop else { return }
        draggingStop = clamped
        session.previewLook(clamped == 0 ? nil : currentPresets[clamped - 1])
        // The next stops either way, so a crossed stop rarely waits for its bake.
        let presets = currentPresets
        session.prefetchDragLooks([clamped + 1, clamped - 1, clamped + 2, clamped - 2].filter { $0 >= 1 && $0 <= presets.count }.map { presets[$0 - 1] })
    }

    func setFine(_ fine: Bool) { isFine = fine }

    /// Released on `stop`: one undo step if it differs from the applied Look, else nothing.
    func dragEnded(at stop: Int) {
        let clamped = min(max(stop, 0), stopCount)
        let startedAt = dragStartStop
        dragStartStop = nil
        session.endDragMeasurement()
        draggingStop = nil
        isFine = false
        // Released where the drag started: a cancel. Without this, browsing another category (whose ruler rests
        // at stop 0) and touching the ruler would commit "no Look" and drop the applied preset.
        if startedAt == clamped {
            session.cancelLookPreview()
            return
        }
        let target = clamped == 0 ? nil : currentPresets[clamped - 1]
        // Prototype `wireRuler`: commit only when the stop names another Look than the applied one
        // (stop zero means no Look). Releasing where it started changes nothing.
        let stillBrowsing = browsedAtHistoryRevision == session.historyRevision
        startsAtFirst = false
        session.applyLook(target)
        // Applying from the browsed category (Favourites included) keeps it browsed.
        if stillBrowsing { browsedAtHistoryRevision = session.historyRevision }
    }

    /// VoiceOver increment/decrement: one stop, committed.
    func step(by delta: Int) {
        dragEnded(at: stop + delta)
    }

    // MARK: - Amount

    var amountValue: Double { draggingAmount ?? session.appliedAmount }
    var amountButtonTitle: String { "Amount \(Int(amountValue.rounded()))" }

    func applyBrowsedPreset() {
        guard let preset = presetAtStop else { return }
        startsAtFirst = false
        session.applyLook(preset)
        browsedAtHistoryRevision = session.historyRevision
    }

    func clearPreset() {
        startsAtFirst = false
        let category = currentCategoryID
        draggingAmount = nil
        draggingStop = nil; dragStartStop = nil; isFine = false; isAmountOpen = false
        session.applyLook(nil)
        browsedCategoryID = category
        browsedAtHistoryRevision = session.historyRevision
    }

    func openAmount() { if namedPreset != nil { isAmountOpen = true } }
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

    var isPresetAtStopFavourite: Bool { namedPreset.map { favourites.contains($0.id) } ?? false }

    /// The star: add, remove, or (with five already) the full notice.
    func toggleStar() {
        guard let preset = namedPreset else { return }
        if favourites.contains(preset.id) {
            favourites.remove(preset.id)
        } else if favourites.add(preset.id) == .full {
            isFavouritesFullNoticeShown = true
        }
    }

    func dismissFavouritesFullNotice() { isFavouritesFullNoticeShown = false }

    /// Replace a favourite › Replace: the applied preset takes that slot.
    func replaceFavourite(_ existingID: String) {
        guard let applied = namedPreset else { return }
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
