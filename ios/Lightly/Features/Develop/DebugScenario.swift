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
        let arguments = DebugArguments.current
        guard let flag = arguments.firstIndex(of: "--scenario"), arguments.indices.contains(flag + 1) else { return nil }
        return DebugScenario(screenID: arguments[flag + 1])
    }

    static var heldPhase: EditorSession.Phase? {
        let arguments = DebugArguments.current
        guard let flag = arguments.firstIndex(of: "--hold-phase"), arguments.indices.contains(flag + 1) else { return nil }
        switch arguments[flag + 1] {
        case "opening": return .opening
        case "developing": return .developing
        default: return nil
        }
    }

    /// The prototype's `PRIVATE_FAVS`: Portrait 13, Landscape 37, Film 12, Golden Hour 4, B&W 3.
    static let privateFavourites = [("portrait", 13), ("landscape", 37), ("film", 12), ("golden-hour", 4), ("black-white", 3)]

    /// The editor UI a slice-3 screen opens on (prototype `ui.tool`, `ui.sub`, `ui.bgKind`).
    struct EditorUI {
        var tool: EditorTool = .develop
        var backgroundMode: BackgroundPanelModel.Mode = .focus
        var backgroundKind: BackgroundPanelModel.Kind?
        var portraitTab: PortraitPanelModel.Tab = .skin
        var editSub: EditPanelModel.Sub = .crop
        var editGroup: EditPanelModel.Group = .light
        var effectsSub: EffectsPanelModel.Sub = .leak
    }

    var editorUI: EditorUI {
        switch screenID {
        case "bg-focus", "bg-soft", "bg-swirl", "bg-motion", "bg-replaced-blur", "bg-no-subject": return EditorUI(tool: .background)
        case "bg-refine": return EditorUI(tool: .background, backgroundMode: .refine)
        case "bg-change-image", "bg-separating", "bg-failed": return EditorUI(tool: .background, backgroundMode: .change, backgroundKind: .image)
        case "bg-change-colour": return EditorUI(tool: .background, backgroundMode: .change, backgroundKind: .colour)
        case "bg-change-gradient": return EditorUI(tool: .background, backgroundMode: .change, backgroundKind: .gradient)
        case "pt-skin", "pt-landscape-photo", "pt-multi", "pt-no-usable-face": return EditorUI(tool: .portrait)
        case "pt-under": return EditorUI(tool: .portrait, portraitTab: .under)
        case "pt-eyes": return EditorUI(tool: .portrait, portraitTab: .eyes)
        case "pt-teeth": return EditorUI(tool: .portrait, portraitTab: .teeth)
        case "pt-hair": return EditorUI(tool: .portrait, portraitTab: .hair)
        case "ed-crop": return EditorUI(tool: .edit, editSub: .crop)
        case "ed-rotate": return EditorUI(tool: .edit, editSub: .rotate)
        case "ed-straighten": return EditorUI(tool: .edit, editSub: .straighten)
        case "ed-perspective": return EditorUI(tool: .edit, editSub: .perspective)
        case "ed-adjust-light": return EditorUI(tool: .edit, editSub: .adjust, editGroup: .light)
        case "ed-adjust-colour": return EditorUI(tool: .edit, editSub: .adjust, editGroup: .colour)
        case "ed-adjust-detail": return EditorUI(tool: .edit, editSub: .adjust, editGroup: .detail)
        case "ed-remove", "ed-removing", "ed-remove-failed": return EditorUI(tool: .edit, editSub: .remove)
        case "fx-leak": return EditorUI(tool: .effects, effectsSub: .leak)
        case "fx-grain", "fx-preset-conflict": return EditorUI(tool: .effects, effectsSub: .grain)
        case "fx-vignette", "fx-combined": return EditorUI(tool: .effects, effectsSub: .vignette)
        case "bd-none", "bd-solid", "bd-frame", "bd-polaroid": return EditorUI(tool: .border)
        default: return EditorUI()
        }
    }

    /// Slice-3 setups (prototype `screens.js`): the recipe the screen shows, as the initial state.
    @MainActor
    func applyBackgroundAndPortrait(session: EditorSession) async {
        func background(_ change: @escaping (inout EditRecipe.Background) -> Void) { session.debugSetInitial { change(&$0.tools.background) } }
        func face(_ change: @escaping (inout EditRecipe.FaceEdit) -> Void) {
            session.debugSetInitial { recipe in
                guard let first = session.people?.usableFaces.first else { return }
                var entry = PortraitPanelModel.neutral(for: first)
                change(&entry)
                recipe.tools.portrait.faces = [entry]
            }
        }
        let image0 = EditRecipe.Replacement.image(.bundled(id: BackgroundPanelModel.bundledImages[0]), x: 50, y: 50, scale: 120)
        switch screenID {
        case "bg-focus", "bg-refine": background { $0.focus.blur = 55 }
        case "bg-soft": background { $0.focus.blur = 55; $0.focus.style = .soft }
        case "bg-swirl": background { $0.focus.blur = 55; $0.focus.style = .swirl }
        case "bg-motion": background { $0.focus.blur = 55; $0.focus.style = .motion }
        case "bg-change-image": background { $0.replacement = image0 }
        case "bg-change-colour": background { $0.replacement = .colour(BackgroundPanelModel.swatches[3]) }
        case "bg-change-gradient":
            let g = BackgroundPanelModel.gradients[0]
            background { $0.replacement = .gradient(angle: g.angle, stops: g.stops) }
        case "bg-replaced-blur": background { $0.replacement = image0; $0.focus.blur = 60 }
        case "bg-separating": session.debugHoldSubjectState(.separating)
        case "bg-failed":
            if let p = session.library.pack.category(id: "portrait")?.presets.first(where: { $0.stop == 13 }) { session.debugApply(p, amount: 100) }
            session.debugHoldSubjectState(.failed)
        case "pt-skin": face { $0.skin.smoothing = 24; $0.skin.blemishes = 40; $0.skin.evenTone = 18 }
        case "pt-under": face { $0.underEye.brighten = 20; $0.underEye.softenLines = 15 }
        case "pt-eyes": face { $0.eyes.brighten = 15 }
        case "pt-teeth": face { $0.teeth.brighten = 20 }
        case "pt-hair": face { $0.hair.definition = 30 }
        case "pt-landscape-photo", "pt-multi": face { $0.skin.smoothing = 20 }
        case "pt-hidden":
            if let p = session.library.pack.category(id: "landscape")?.presets.first(where: { $0.stop == 120 }) { session.debugApply(p, amount: 100) }
        default: break
        }
    }

    /// The prototype's `ed-remove` stroke mark (`.stroke` at left 62 %, top 30 %, 16 % × 5 % of the
    /// photo, rotated −12°, fully rounded) as a Remove stroke: its centre line and radius, in
    /// source coordinates for a photo of `width × height`.
    static func prototypeStroke(width: Int, height: Int) -> (points: [EditRecipe.Point], radius: Double) {
        let w = Double(width), h = Double(height)
        let boxWidth = 0.16 * w, boxHeight = 0.05 * h
        let radius = min(boxHeight / 2, boxWidth / 2)
        let centre = SIMD2(0.62 * w + boxWidth / 2, 0.30 * h + boxHeight / 2)
        let half = boxWidth / 2 - radius
        let angle = -12 * Double.pi / 180
        let axis = SIMD2(cos(angle), sin(angle))
        let ends = [centre - axis * half, centre + axis * half]
        let points = stride(from: 0.0, through: 1.0, by: 0.125).map { t -> EditRecipe.Point in
            let p = ends[0] + (ends[1] - ends[0]) * t
            return EditRecipe.Point(x: p.x / w, y: p.y / h)
        }
        return (points, radius / max(w, h))
    }

    /// Slice-4 setups (prototype `screens.js`, Edit and Effects): the recipe the screen shows, as
    /// the session's initial state.
    @MainActor
    func applyEditAndEffects(session: EditorSession, brushRadius: Double) async {
        func preset(_ category: String, _ stop: Int) {
            if let p = session.library.pack.category(id: category)?.presets.first(where: { $0.stop == stop }) { session.debugApply(p, amount: 100) }
        }
        func edit(_ change: @escaping (inout EditRecipe.Edit) -> Void) { session.debugSetInitial { change(&$0.tools.edit) } }
        func effects(_ change: @escaping (inout EditRecipe.Effects) -> Void) { session.debugSetInitial { change(&$0.tools.effects) } }
        let stroke = Self.prototypeStroke(width: session.photo.image.width, height: session.photo.image.height)
        switch screenID {
        case "ed-crop":
            edit { e in
                e.geometry.cropAspect = .fourFive
                e.geometry.cropRect = EditorSession.cropRect(for: .fourFive, geometry: e.geometry, photo: session.photo)
            }
        case "ed-rotate": edit { $0.geometry.flipHorizontal = true }
        case "ed-straighten": edit { $0.geometry.straighten = -3 }
        case "ed-perspective": edit { $0.geometry.perspectiveVertical = 18 }
        case "ed-adjust-light": edit { $0.adjust.exposure = 12; $0.adjust.contrast = 10; $0.adjust.highlights = -20; $0.adjust.shadows = 25 }
        case "ed-adjust-colour": edit { $0.adjust.temp = 15; $0.adjust.tint = -4; $0.adjust.vibrance = 12 }
        case "ed-adjust-detail": edit { $0.adjust.sharpness = 30; $0.adjust.clarity = 15; $0.adjust.noise = 20 }
        case "ed-remove":
            // One stroke, removed by the real model (LaMa); the capture waits for its patch.
            await session.debugRemoveAsInitial(points: stroke.points, radius: stroke.radius)
        case "ed-removing", "ed-remove-failed":
            if screenID == "ed-remove-failed" { preset("landscape", 37) }
            session.debugHoldRemoveState(screenID == "ed-removing" ? .removing : .failed,
                                         stroke: .init(radius: stroke.radius, points: stroke.points, status: .applied, patch: nil))
        case "fx-leak": effects { $0.lightLeak.enabled = true }
        case "fx-grain": effects { $0.grain.enabled = true; $0.grain.amount = 45 }
        case "fx-vignette": effects { $0.vignette.enabled = true }
        case "fx-combined": effects { $0.lightLeak.enabled = true; $0.grain.enabled = true; $0.vignette.enabled = true }
        case "fx-preset-conflict":
            // The prototype picks Film 5 with a stand-in hash (`presetHasEffect`); Film 5's real
            // recipe has no grain. Film 3 ("01 Vintage 01") is the first Film preset that carries
            // its own grain, so the approved state can be shown (deviation F1, owner decision).
            preset("film", 3)
            effects { $0.grain.enabled = true }
        case "bd-solid": session.debugSetInitial { $0.tools.border.type = .solid; $0.tools.border.width = 5 }
        case "bd-frame":
            session.debugSetInitial { r in
                r.tools.border.type = .frame; r.tools.border.colour = "#111111"; r.tools.border.width = 3; r.tools.border.spacing = 5
            }
        case "bd-polaroid":
            // DEFERRED(Watermark): the approved setup also puts the saved signature on the margin
            // (`s.wm.type = 'signature'; s.wm.place = 'border'`); that needs the signature store.
            session.debugSetInitial { $0.tools.border.type = .polaroid }
        default: break
        }
    }

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
            // Prototype `edited`: the preset and a vignette (the Effects dot shows).
            apply("landscape", 37)
            session.debugSetInitial { $0.tools.effects.vignette.enabled = true }
            session.toggleCompare()
        case "saving", "saved":
            apply("landscape", 37)
            session.debugSetInitial { $0.tools.effects.vignette.enabled = true }
            session.saveCopy()
        default:
            break
        }
    }
}
#endif
