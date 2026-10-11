import SwiftUI

/// UI state of the Portrait panel (approved `portraitPanel`): the tab and the chosen face.
@MainActor
@Observable
final class PortraitPanelModel {
    /// Owner amendment 2026-10-11: Smile sits between Teeth and Hair & Beard (mockup `portraitPanel`).
    enum Tab: String, CaseIterable { case skin, under, eyes, teeth, smile, hair }

    let session: EditorSession
    var tab: Tab = .skin
    /// Index into the usable faces; one face is selected automatically.
    var selectedFace = 0

    init(session: EditorSession) { self.session = session }

    var faces: [DetectedFace] { session.people?.usableFaces ?? [] }

    /// The recipe entry for a usable face (matched by box and detector), or a new neutral one.
    func edit(forFace index: Int) -> EditRecipe.FaceEdit {
        guard faces.indices.contains(index) else { return Self.neutral(for: nil) }
        let face = faces[index]
        return session.recipe.tools.portrait.faces.first { $0.face.box == face.box && $0.face.detector == DetectedFace.detector }
            ?? Self.neutral(for: face)
    }

    /// Prototype `countChanges`: the settings away from their defaults.
    func changeCount(forFace index: Int) -> Int { changeCount(for: edit(forFace: index)) }

    func changeCount(for e: EditRecipe.FaceEdit) -> Int {
        let values = [e.skin.smoothing, e.skin.blemishes, e.skin.evenTone, e.underEye.brighten, e.underEye.softenLines, e.eyes.brighten,
                      e.eyes.clarity, e.teeth.brighten, e.hair.definition, e.hair.flyaways, e.hair.shine, e.smile.amount]
        return values.filter { $0 != 0 }.count + (e.skin.keepTexture != 85 ? 1 : 0)
    }

    /// Smile needs both mouth corners of the selected face (rendering-v2 §7.3); without them the warp leaves the face
    /// unchanged and the tab says so.
    var selectedFaceHasMouth: Bool {
        faces.indices.contains(selectedFace) && faces[selectedFace].mouthCorners != nil
    }

    nonisolated static func neutral(for face: DetectedFace?) -> EditRecipe.FaceEdit {
        EditRecipe.FaceEdit(
            face: .init(box: face?.box ?? .init(x: 0, y: 0, width: 0, height: 0), detector: DetectedFace.detector),
            skin: .init(smoothing: 0, blemishes: 0, evenTone: 0, keepTexture: 85), underEye: .init(brighten: 0, softenLines: 0),
            eyes: .init(brighten: 0, clarity: 0), teeth: .init(brighten: 0), hair: .init(definition: 0, flyaways: 0, shine: 0))
    }

    func update(_ transform: @escaping (inout EditRecipe.FaceEdit) -> Void, commit: Bool) {
        guard faces.indices.contains(selectedFace) else { return }
        let face = faces[selectedFace]
        let apply: (inout EditRecipe.Portrait) -> Void = { portrait in
            if let i = portrait.faces.firstIndex(where: { $0.face.box == face.box && $0.face.detector == DetectedFace.detector }) {
                transform(&portrait.faces[i])
            } else {
                var entry = Self.neutral(for: face)
                transform(&entry)
                portrait.faces.append(entry)
            }
        }
        if commit { session.commitPortrait(apply) } else { session.previewPortrait(apply) }
    }
}

/// The approved Portrait panel.
struct PortraitPanelView: View {
    @Bindable var model: PortraitPanelModel
    let roomy: Bool
    let wraps: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// Lightly 2 `portraitPanel`, a 4 pt column: the faces (several faces only), the tabs (an orange dot on tabs with
    /// changes for this face), the reset row, the sliders and notes.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.faces.isEmpty {
                L2Notice(icon: .info, bold: "No face can be edited in this photo.",
                         text: " Faces are too small, turned away or too dark. Portrait controls need a clear face.")
            } else {
                if model.faces.count > 1 { faceStrip }
                let e = model.edit(forFace: model.selectedFace)
                PanelTabs(items: [(PortraitPanelModel.Tab.skin, "Skin", e.skin.smoothing != 0 || e.skin.blemishes != 0 || e.skin.evenTone != 0 || e.skin.keepTexture != 85),
                                  (.under, "Under-eye", e.underEye.brighten != 0 || e.underEye.softenLines != 0),
                                  (.eyes, "Eyes", e.eyes.brighten != 0 || e.eyes.clarity != 0),
                                  (.teeth, "Teeth", e.teeth.brighten != 0),
                                  (.smile, "Smile", e.smile.amount != 0),
                                  (.hair, "Hair & Beard", e.hair.definition != 0 || e.hair.flyaways != 0 || e.hair.shine != 0)],
                          selected: model.tab, wraps: wraps, identifierPrefix: "portrait.tab") { model.tab = $0 }
                PanelResetRow(session: model.session, section: "portrait", title: ["skin": "Skin", "under": "Under-eye", "eyes": "Eyes", "teeth": "Teeth", "smile": "Smile", "hair": "Hair & Beard"][model.tab.rawValue]!, adjustment: model.tab.rawValue, resetAdjustment: {
                    model.update({ edit in
                        let neutral = PortraitPanelModel.neutral(for: nil)
                        switch model.tab {
                        case .skin: edit.skin = neutral.skin
                        case .under: edit.underEye = neutral.underEye
                        case .eyes: edit.eyes = neutral.eyes
                        case .teeth: edit.teeth = neutral.teeth
                        case .smile: edit.smile = neutral.smile
                        case .hair: edit.hair = neutral.hair
                        }
                    }, commit: true)
                })
                sliders
            }
        }
    }

    /// The faces: chips ("Face 1 · 4" with changes), then "Each face keeps its own settings.", 10 pt apart.
    private var faceStrip: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(model.faces.indices, id: \.self) { index in
                    let count = model.changeCount(forFace: index)
                    OptionChip(isOn: index == model.selectedFace, identifier: "portrait.face.\(index + 1)",
                               action: { model.selectedFace = index }) {
                        Text(count > 0 ? "Face \(index + 1) · \(count)" : "Face \(index + 1)")
                    }
                }
            }
            L2Note(text: Text("Each face keeps its own settings."))
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var sliders: some View {
        let e = model.edit(forFace: model.selectedFace)
        switch model.tab {
        case .skin:
            slider("Smoothing", e.skin.smoothing) { $0.skin.smoothing = $1 }
            slider("Blemishes", e.skin.blemishes) { $0.skin.blemishes = $1 }
            slider("Even tone", e.skin.evenTone) { $0.skin.evenTone = $1 }
            slider("Keep texture", e.skin.keepTexture) { $0.skin.keepTexture = $1 }
            ApprovedNote("Blemish reduction is temporary marks only. Pores, freckles, moles and skin tone colour stay.")
        case .under:
            slider("Brighten", e.underEye.brighten) { $0.underEye.brighten = $1 }
            slider("Soften lines", e.underEye.softenLines) { $0.underEye.softenLines = $1 }
        case .eyes:
            slider("Brighten", e.eyes.brighten) { $0.eyes.brighten = $1 }
            slider("Clarity", e.eyes.clarity) { $0.eyes.clarity = $1 }
            ApprovedNote("Eye colour and shape are never changed.")
        case .teeth:
            slider("Brighten", e.teeth.brighten) { $0.teeth.brighten = $1 }
            ApprovedNote("Stays within a natural range. There is no automatic whitening.")
        case .smile:
            // A centred ±100 slider like the other bipolar sliders; 0 is the photo as taken.
            slider("Smile", e.smile.amount, range: -100...100) { $0.smile.amount = $1 }
            if model.selectedFaceHasMouth {
                ApprovedNote("Lifts or relaxes the corners of the mouth. Stays within a natural range; the rest of the face is unchanged.")
            } else {
                ApprovedNote("Smile needs a visible mouth.")
            }
        case .hair:
            slider("Definition", e.hair.definition) { $0.hair.definition = $1 }
            slider("Flyaways", e.hair.flyaways) { $0.hair.flyaways = $1 }
            slider("Shine", e.hair.shine) { $0.hair.shine = $1 }
        }
    }

    private func slider(_ label: String, _ value: Double, range: ClosedRange<Double> = 0...100,
                        _ set: @escaping (inout EditRecipe.FaceEdit, Double) -> Void) -> some View {
        PanelSlider(label: label, value: value, range: range,
                    identifier: "slider.\(label.lowercased().replacingOccurrences(of: " ", with: ""))",
                    onChange: { v in model.update({ set(&$0, v.rounded()) }, commit: false) },
                    onEnd: { v in model.update({ set(&$0, v.rounded()) }, commit: true) })
    }
}
