import CoreGraphics
import Foundation
import Observation

/// UI state and edits of the Text tool (owner amendment 2026-10-11; mockup `textPanel`, tx-* screens).
///
/// Every finished change is one undo step: adding, editing the words, a font, a slider's release, a colour, deleting,
/// and each gesture on the photo (a move, a pinch or turn, a corner-handle drag) from touch-down to the last finger up.
/// While a slider or finger moves the change is only previewed.
@MainActor
@Observable
final class TextPanelModel {
    let session: EditorSession

    /// The layer the panel edits and the photo outlines. Ids are stable, so the selection survives Undo and Redo.
    var selectedLayerID: String?

    /// The text sheet: adding a new layer, or editing the selected one's words.
    enum SheetPurpose: Equatable {
        case add
        case edit(layerID: String)
    }
    var sheet: SheetPurpose?

    /// A gesture on the photo in progress: the layer as it was at touch-down and as it is previewed now.
    @ObservationIgnored private var gestureStart: EditRecipe.TextLayer?
    private(set) var gestureDraft: EditRecipe.TextLayer?
    /// Fingers' gestures still running in this touch sequence (a drag and a pinch can overlap): the one undo step is
    /// committed when the last of them ends.
    @ObservationIgnored private var activeGestures = 0
    /// The draft when a pinch or turn began (a drag may already have moved it).
    @ObservationIgnored private var transformStart: EditRecipe.TextLayer?

    /// New layers (mockup and owner spec): centred, size 42, Playfair Display, white, fully opaque, upright.
    static let newLayerSize = 42.0
    static let newLayerFont = EditRecipe.TextLayer.Font.playfairDisplay
    static let newLayerColour = "#FFFFFF"

    init(session: EditorSession) { self.session = session }

    var layers: [EditRecipe.TextLayer] { session.recipe.tools.text.layers }
    var hasLayers: Bool { !layers.isEmpty }

    /// The selected layer: the chosen one while it exists (an Undo can remove it), else the top layer.
    var selectedLayer: EditRecipe.TextLayer? {
        if let selectedLayerID, let chosen = layers.first(where: { $0.id == selectedLayerID }) { return chosen }
        return layers.last
    }

    /// The selected layer as the photo shows it right now (with a gesture's draft applied).
    var shownSelectedLayer: EditRecipe.TextLayer? {
        if let gestureDraft, gestureDraft.id == selectedLayer?.id { return gestureDraft }
        return selectedLayer
    }

    var canAddLayer: Bool { layers.count < EditRecipe.TextTool.maximumLayers }

    // MARK: - Sheet

    func openAdd() {
        guard canAddLayer else { return }
        sheet = .add
    }

    func openEditSelected() {
        guard let layer = selectedLayer else { return }
        sheet = .edit(layerID: layer.id)
    }

    /// The words the sheet starts with.
    var sheetInitialText: String {
        guard case .edit(let id)? = sheet else { return "" }
        return layers.first { $0.id == id }?.text ?? ""
    }

    /// Done: a blank text never commits (Done is disabled for it); otherwise one undo step.
    func finishSheet(with typed: String) {
        defer { sheet = nil }
        let text = Self.cleaned(typed)
        guard !text.isEmpty else { return }
        switch sheet {
        case .add?: addLayer(text: text)
        case .edit(let id)?: update(id) { $0.text = text }
        case nil: break
        }
    }

    func cancelSheet() { sheet = nil }

    /// Surrounding spaces and blank lines dropped, at most 120 characters (`textLayer.text.maxLength`).
    static func cleaned(_ typed: String) -> String {
        String(typed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(EditRecipe.TextLayer.maximumTextLength))
    }

    // MARK: - Layers

    func addLayer(text: String) {
        guard canAddLayer else { return }
        let layer = EditRecipe.TextLayer(id: Self.newLayerID(avoiding: Set(layers.map(\.id))), text: text, font: Self.newLayerFont,
                                         size: Self.newLayerSize, colour: Self.newLayerColour, opacity: 100,
                                         centre: .init(x: 0.5, y: 0.5), rotation: 0)
        session.commitText { $0.layers.append(layer) }
        selectedLayerID = layer.id
    }

    /// ✕ on the photo.
    func deleteLayer(_ id: String) {
        guard layers.contains(where: { $0.id == id }) else { return }
        session.commitText { $0.layers.removeAll { $0.id == id } }
        if selectedLayerID == id { selectedLayerID = layers.last?.id }
    }

    func select(_ id: String?) { selectedLayerID = id }

    func chooseFont(_ font: EditRecipe.TextLayer.Font) { updateSelected { $0.font = font } }

    func setColour(_ hex: String) { updateSelected { $0.colour = hex } }

    func previewColour(_ hex: String) { previewSelected { $0.colour = hex } }

    func previewSize(_ value: Double) { previewSelected { $0.size = Self.clampedSize(value) } }
    func commitSize(_ value: Double) { updateSelected { $0.size = Self.clampedSize(value) } }
    func previewOpacity(_ value: Double) { previewSelected { $0.opacity = min(max(value.rounded(), 0), 100) } }
    func commitOpacity(_ value: Double) { updateSelected { $0.opacity = min(max(value.rounded(), 0), 100) } }

    private func updateSelected(_ change: (inout EditRecipe.TextLayer) -> Void) {
        guard let id = selectedLayer?.id else { return }
        update(id, change)
    }

    private func update(_ id: String, _ change: (inout EditRecipe.TextLayer) -> Void) {
        session.commitText { tool in
            guard let index = tool.layers.firstIndex(where: { $0.id == id }) else { return }
            change(&tool.layers[index])
        }
    }

    private func previewSelected(_ change: (inout EditRecipe.TextLayer) -> Void) {
        guard let id = selectedLayer?.id else { return }
        session.previewText { tool in
            guard let index = tool.layers.firstIndex(where: { $0.id == id }) else { return }
            change(&tool.layers[index])
        }
    }

    // MARK: - Gestures on the photo

    /// A finger (or pinch) begins on a layer: it becomes selected; the gesture works on it until every finger lifts.
    func beginGesture(on id: String) {
        if activeGestures == 0 {
            guard let layer = layers.first(where: { $0.id == id }) else { return }
            selectedLayerID = id
            gestureStart = layer
            gestureDraft = layer
        }
        activeGestures += 1
    }

    /// Dragging inside a text: its centre follows the finger, clamped to the frame (fractions of the frame).
    func moveDraft(byFraction translation: CGSize) {
        guard let start = gestureStart, var draft = gestureDraft, transformStart == nil else { return }
        draft.centre = .init(x: min(max(start.centre.x + Double(translation.width), 0), 1),
                             y: min(max(start.centre.y + Double(translation.height), 0), 1))
        preview(draft)
    }

    /// A pinch and turn on the selected text, or the corner handle: size × `scale` and `degrees` clockwise added,
    /// measured from where this transform began.
    func transformDraft(scale: Double, degrees: Double) {
        guard let draft = gestureDraft else { return }
        if transformStart == nil { transformStart = draft }
        guard let start = transformStart else { return }
        var next = draft
        next.size = Self.clampedSize(start.size * scale)
        next.rotation = Self.normalisedDegrees(start.rotation + degrees)
        preview(next)
    }

    /// The corner handle (bottom-trailing) dragged from `from` to `to` around the block's centre (any one coordinate
    /// space): resize by the distance ratio and turn by the angle swept.
    func transformDraft(handleFrom from: CGPoint, to point: CGPoint, centre: CGPoint) {
        let start = hypot(from.x - centre.x, from.y - centre.y), now = hypot(point.x - centre.x, point.y - centre.y)
        guard start > 1 else { return }
        let swept = atan2(point.y - centre.y, point.x - centre.x) - atan2(from.y - centre.y, from.x - centre.x)
        transformDraft(scale: Double(now / start), degrees: Double(swept) * 180 / .pi)
    }

    /// A pinch or handle drag ended (the drag may continue).
    func endTransform() { transformStart = nil }

    /// One gesture ended; the last one commits the draft as one undo step (nothing if it did not change).
    func endGesture() {
        guard activeGestures > 0 else { return }
        activeGestures -= 1
        guard activeGestures == 0 else { return }
        let draft = gestureDraft, start = gestureStart
        gestureStart = nil; gestureDraft = nil; transformStart = nil
        guard let draft, draft != start else { return }
        session.commitText { tool in
            guard let index = tool.layers.firstIndex(where: { $0.id == draft.id }) else { return }
            tool.layers[index] = draft
        }
    }

    private func preview(_ layer: EditRecipe.TextLayer) {
        gestureDraft = layer
        session.previewText { tool in
            guard let index = tool.layers.firstIndex(where: { $0.id == layer.id }) else { return }
            tool.layers[index] = layer
        }
    }

    // MARK: - Values

    static func clampedSize(_ value: Double) -> Double {
        min(max(value.rounded(), EditRecipe.TextLayer.sizeRange.lowerBound), EditRecipe.TextLayer.sizeRange.upperBound)
    }

    /// −180…180, as the recipe stores rotation.
    static func normalisedDegrees(_ value: Double) -> Double {
        var degrees = value.truncatingRemainder(dividingBy: 360)
        if degrees > 180 { degrees -= 360 }
        if degrees < -180 { degrees += 360 }
        return degrees
    }

    /// Eight random lowercase hex digits not used by another layer (`textLayer.id`).
    static func newLayerID(avoiding used: Set<String>) -> String {
        var id: String
        repeat { id = String(format: "%08x", UInt32.random(in: .min ... .max)) } while used.contains(id)
        return id
    }

    /// The topmost layer under `point` (frame coordinates in `frameSize` units), grown by `slop` for small texts.
    func layer(at point: CGPoint, frameSize: CGSize, slop: Double = 8) -> EditRecipe.TextLayer? {
        layers.reversed().first { TextStage.layout($0, frameSize: frameSize).contains(point, slop: slop) }
    }
}
