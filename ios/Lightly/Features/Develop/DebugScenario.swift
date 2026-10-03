#if DEBUG
import Foundation

/// DEBUG-only launch arguments that put the editor in one approved state, so design captures and
/// UI tests can photograph exactly the prototype's screens (`docs/ui/app/screens.js`):
///
/// - `--open-photo <path>`: opens that file through the normal open path (RootView);
/// - `--scenario <screen id>`: after Develop has run, applies the screen's setup — the preset by
///   category and stop, its Amount, favourites, the category browsed, the dragging stop and Fine,
///   the Amount control, the favourites notice or Replace sheet, Compare, saving or saved;
/// - `--hold-phase opening|developing`: stays on the loading screen in that phase.
///
/// Nothing here exists in release builds.
struct DebugScenario {
    let screenID: String

    static var current: DebugScenario? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--scenario"), arguments.indices.contains(flag + 1) else { return nil }
        return DebugScenario(screenID: arguments[flag + 1])
    }

    static var heldPhase: EditorSession.Phase? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--hold-phase"), arguments.indices.contains(flag + 1) else { return nil }
        switch arguments[flag + 1] {
        case "opening": return .opening
        case "developing": return .developing
        default: return nil
        }
    }

    /// The prototype's `PRIVATE_FAVS`: Portrait 13, Landscape 37, Film 12, Golden Hour 4, B&W 3.
    static let privateFavourites = [("portrait", 13), ("landscape", 37), ("film", 12), ("golden-hour", 4), ("black-white", 3)]

    @MainActor
    func apply(session: EditorSession, panel: DevelopPanelModel) async {
        await session.waitUntilReady()
        let pack = session.library.pack
        func preset(_ category: String, _ stop: Int) -> PresetPack.Preset? {
            pack.category(id: category)?.presets.first { $0.stop == stop }
        }
        func apply(_ category: String, _ stop: Int, amount: Double = 100) {
            if let p = preset(category, stop) { session.debugApply(p, amount: amount) }
        }
        func privateFavourites() -> [String] { Self.privateFavourites.compactMap { preset($0.0, $0.1)?.id } }

        switch screenID {
        case "dev-preset":
            apply("landscape", 37)
        case "dev-dragging":
            apply("landscape", 37)
            panel.debugSetDragging(stop: 41, fine: true)
        case "dev-browse":
            apply("landscape", 37)
            panel.selectCategory("cinematic")
        case "dev-large":
            apply("cinematic", 564)
        case "dev-long-name":
            if let stop = pack.category(id: "landscape")?.presets.first(where: { $0.displayName == "Landscape 15 - Winter Wonderland" })?.stop {
                apply("landscape", stop)
            }
        case "dev-amount":
            apply("landscape", 37, amount: 70)
            panel.debugOpenAmount()
        case "dev-starred":
            apply("landscape", 37)
            if let id = session.appliedPreset?.id { panel.favourites.replaceAll(with: [id]) }
        case "dev-favourites":
            panel.favourites.replaceAll(with: privateFavourites())
            apply("portrait", 13)
            panel.selectCategory(DevelopPanelModel.favouritesID)
        case "dev-fav-full":
            panel.favourites.replaceAll(with: privateFavourites())
            apply("travel", 5)
            panel.debugShowFavouritesFull()
        case "dev-fav-replace":
            panel.favourites.replaceAll(with: privateFavourites())
            apply("travel", 5)
            panel.isReplaceSheetShown = true
        case "dev-bw":
            apply("black-white", 8)
        case "dev-landscape-photo":
            apply("golden-hour", 12)
        case "dev-portrait-photo":
            apply("portrait", 13)
        case "compare":
            apply("landscape", 37)
            session.toggleCompare()
        case "saving", "saved":
            apply("landscape", 37)
            session.saveCopy()
        default:
            break
        }
    }
}
#endif
