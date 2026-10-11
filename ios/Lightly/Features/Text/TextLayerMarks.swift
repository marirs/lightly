import SwiftUI

/// The Text tool on the photo (owner amendment 2026-10-11; mockup tx-selected): the texts themselves are drawn by the
/// rendered photo (stage 11); this view adds only the selected text's frame and touches. The frame is a 1.5 pt dashed
/// white outline 2 pt outside the text's box (the block with the mockup's 4/10 pt padding), a 22 pt white circle with ✕ at its top-leading corner (deletes the layer)
/// and a 22 pt white circle handle at its bottom-trailing corner (drag: resize and turn about the centre). Tapping a
/// text selects it, tapping elsewhere on the photo deselects; dragging inside a text moves it; two fingers on the
/// selected text pinch and turn it. Each finished gesture is one undo step (`TextPanelModel`).
///
/// While a finger moves a text, this view also draws that text itself (`TextPanelModel.liveLayer`, with the stage's
/// own `TextStage.draw`) over a photo rendered without it, so the text follows the finger on every frame.
///
/// The ✕ and the handle sit on the outline's corners; when a corner falls outside the stage (a text near or past the
/// photo's edge) the knob is kept just inside the stage instead of being cut off (owner report 2026-10-11, "did not see
/// the handle properly"). The marks are not clipped to the photo for this tool (`PhotoStage.clipsMarks`).
///
/// Laid over the canvas; `frameRect` is the photo frame inside it (a border's margin around), in this view's points.
struct TextLayerMarks: View {
    @Bindable var model: TextPanelModel
    let frameRect: CGRect

    /// `outline-offset: 2px`, and the outline's width.
    private static let outlineOffset: CGFloat = 2
    private static let outlineWidth: CGFloat = 1.5
    /// The mockup's text box padding (`padding: 4px 10px`) inside the outline.
    private static let boxPadding = CGSize(width: 10, height: 4)
    /// The ✕ and the corner handle.
    private static let knobSize: CGFloat = 22

    /// How far the stage reaches past the canvas on every side, at least (`PhotoStage`'s 8 pt top and bottom inset):
    /// a knob's centre may sit this far out, less its radius, and still show whole.
    private static let stageMargin: CGFloat = 8

    @State private var dragTargetID: String?
    @State private var isPinching = false
    @State private var handleStart: CGPoint?
    /// Each gesture's own touch state. These reset when the system cancels a touch, which `onEnded` never reports;
    /// once all three are idle, a gesture still open in the model is finished there (`endAllGestures`).
    @GestureState private var isMoveTouching = false
    @GestureState private var isPinchTouching = false
    @GestureState private var isHandleTouching = false
    private var isTouching: Bool { isMoveTouching || isPinchTouching || isHandleTouching }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        model.select(model.layer(at: framePoint(value.location), frameSize: frameRect.size)?.id)
                    })
                    .simultaneousGesture(moveGesture)
                    .simultaneousGesture(pinchGesture)
                    .accessibilityHidden(true)
                if let live = model.liveLayer {
                    liveText(live)
                }
                if let layer = model.shownSelectedLayer {
                    selectionFrame(layer, canvas: geometry.size)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .coordinateSpace(name: Self.space)
        .onChange(of: isTouching) { _, touching in
            guard !touching else { return }
            // A gesture that ended normally has already been finished by its `onEnded` in this update; one still open
            // on the next turn of the run loop was cancelled by the system and is committed as it stands.
            DispatchQueue.main.async {
                guard !isTouching, model.isGestureActive else { return }
                dragTargetID = nil; isPinching = false; handleStart = nil
                model.endAllGestures()
            }
        }
    }

    /// The text under the finger, drawn by the stage's own text code at display resolution, clipped to the photo frame
    /// as the rendered stage clips it.
    private func liveText(_ layer: EditRecipe.TextLayer) -> some View {
        Canvas { context, _ in
            guard layer.opacity > 0 else { return }
            context.withCGContext { cg in
                TextStage.draw(layer, frameSize: frameRect.size, in: cg)
            }
        }
        .frame(width: frameRect.width, height: frameRect.height)
        .clipped()
        .offset(x: frameRect.minX, y: frameRect.minY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Geometry

    private func framePoint(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x - frameRect.minX, y: location.y - frameRect.minY)
    }

    // MARK: Gestures

    /// Dragging inside a text moves it (and selects it); a drag that starts elsewhere does nothing.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($isMoveTouching) { _, touching, _ in touching = true }
            .onChanged { value in
                if dragTargetID == nil {
                    guard let hit = model.layer(at: framePoint(value.startLocation), frameSize: frameRect.size) else { return }
                    dragTargetID = hit.id
                    model.beginGesture(on: hit.id)
                }
                guard !isPinching else { return }
                model.moveDraft(byFraction: CGSize(width: value.translation.width / max(frameRect.width, 1),
                                                   height: value.translation.height / max(frameRect.height, 1)))
            }
            .onEnded { _ in
                guard dragTargetID != nil else { return }
                dragTargetID = nil
                model.endGesture()
            }
    }

    /// Two fingers on the photo while a text is selected: pinch resizes, turning rotates the selected text.
    private var pinchGesture: some Gesture {
        MagnifyGesture().simultaneously(with: RotateGesture())
            .updating($isPinchTouching) { _, touching, _ in touching = true }
            .onChanged { value in
                guard let selected = model.selectedLayer else { return }
                if !isPinching {
                    isPinching = true
                    model.beginGesture(on: selected.id)
                }
                model.transformDraft(scale: Double(value.first?.magnification ?? 1),
                                     degrees: value.second?.rotation.degrees ?? 0)
            }
            .onEnded { _ in
                guard isPinching else { return }
                isPinching = false
                model.endTransform()
                model.endGesture()
            }
    }

    // MARK: Selection frame

    /// The outline around the (turned) text block, placed on the block's centre and turned with it; the ✕ on its
    /// top-leading corner and the handle on its bottom-trailing corner, each turned with the block and kept inside the
    /// stage (`knobCentre`).
    @ViewBuilder
    private func selectionFrame(_ layer: EditRecipe.TextLayer, canvas: CGSize) -> some View {
        let layout = TextStage.layout(layer, frameSize: frameRect.size)
        let outlined = CGSize(width: layout.blockSize.width + 2 * (Self.boxPadding.width + Self.outlineOffset) + Self.outlineWidth,
                              height: layout.blockSize.height + 2 * (Self.boxPadding.height + Self.outlineOffset) + Self.outlineWidth)
        let centre = CGPoint(x: frameRect.minX + layout.centre.x, y: frameRect.minY + layout.centre.y)
        Rectangle()
            .strokeBorder(.white.opacity(0.95), style: StrokeStyle(lineWidth: Self.outlineWidth, dash: [4, 3]))
            .frame(width: outlined.width, height: outlined.height)
            .rotationEffect(.radians(layout.rotation))
            .position(centre)
            .allowsHitTesting(false)
        deleteKnob(layer)
            .rotationEffect(.radians(layout.rotation))
            .position(Self.knobCentre(corner: CGPoint(x: -outlined.width / 2, y: -outlined.height / 2), centre: centre,
                                      rotation: layout.rotation, canvas: canvas))
        resizeHandle(layer, centre: centre)
            .rotationEffect(.radians(layout.rotation))
            .position(Self.knobCentre(corner: CGPoint(x: outlined.width / 2, y: outlined.height / 2), centre: centre,
                                      rotation: layout.rotation, canvas: canvas))
    }

    /// Where a knob's centre goes: the outline's corner (`corner`, from the block's centre before turning) turned
    /// clockwise by `rotation` about `centre`, then kept far enough inside the canvas grown by the stage margin that the
    /// whole 22 pt circle shows.
    static func knobCentre(corner: CGPoint, centre: CGPoint, rotation: Double, canvas: CGSize) -> CGPoint {
        let c = CGFloat(cos(rotation)), s = CGFloat(sin(rotation))
        // y grows downwards, so a clockwise turn maps (x, y) to (x cos θ − y sin θ, x sin θ + y cos θ).
        let turned = CGPoint(x: centre.x + corner.x * c - corner.y * s, y: centre.y + corner.x * s + corner.y * c)
        let inset = knobSize / 2 - stageMargin
        return CGPoint(x: min(max(turned.x, inset), max(inset, canvas.width - inset)),
                       y: min(max(turned.y, inset), max(inset, canvas.height - inset)))
    }

    private func knob(_ icon: ApprovedIcon) -> some View {
        ApprovedIconView(icon: icon, size: 12)
            .foregroundStyle(Color(hex: 0x141513))
            .frame(width: Self.knobSize, height: Self.knobSize)
            .background(Circle().fill(.white))
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
            // A 44 pt touch target around the 22 pt circle.
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }

    private func deleteKnob(_ layer: EditRecipe.TextLayer) -> some View {
        Button { model.deleteLayer(layer.id) } label: { knob(.close) }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Delete text"))
            .accessibilityIdentifier("text.delete")
    }

    /// Drag the handle: the text scales by the finger's distance from the centre and turns with its angle. Touches are
    /// read in the stage's own (unturned) space so the turn being applied does not feed back into the drag.
    private func resizeHandle(_ layer: EditRecipe.TextLayer, centre: CGPoint) -> some View {
        knob(.redo)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                .updating($isHandleTouching) { _, touching, _ in touching = true }
                .onChanged { value in
                    if handleStart == nil {
                        handleStart = value.startLocation
                        model.beginGesture(on: layer.id)
                    }
                    guard let start = handleStart else { return }
                    model.transformDraft(handleFrom: start, to: value.location, centre: centre)
                }
                .onEnded { _ in
                    guard handleStart != nil else { return }
                    handleStart = nil
                    model.endTransform()
                    model.endGesture()
                })
            .accessibilityLabel(Text("Resize or turn text"))
            .accessibilityIdentifier("text.handle")
    }

    static let space = "textmarks"
}
