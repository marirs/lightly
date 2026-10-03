import SwiftUI

/// The approved preset ruler (`.ruler`): one tick per preset stop, 12 pt apart, a longer tick every
/// ten, a number every fifty, a fixed needle in the middle and faded ends.
///
/// - Dragging previews the stop under the needle (photo and name row) and commits nothing.
/// - Releasing commits the stop it settles on: one undo step. A flick carries on to where it would
///   stop (the prototype ruler scrolls natively, with momentum) and commits there.
/// - No interpolation between presets and no previous/next arrows.
/// - Fine control: holding still for `fineHoldDelay` while dragging shows "Fine" and slows the
///   ruler to a quarter, so one stop at a time is easy to reach. It ends on release.
struct StopRuler: View {
    @Bindable var model: DevelopPanelModel

    static let tickSpacing: CGFloat = 12
    static let height: CGFloat = 52
    /// DEFERRED(confirm): the prototype shows the Fine state (`dev-dragging`) but not its timing or
    /// speed; half a second of stillness and quarter speed are this build's values.
    static let fineHoldDelay: Duration = .milliseconds(500)
    static let fineSpeed: CGFloat = 0.25

    @State private var visualOffset: CGFloat?
    @State private var lastTranslation: CGFloat = 0
    @State private var lastMovement = ContinuousClock.now
    @State private var holdTask: Task<Void, Never>?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let count = model.stopCount
        let offset = visualOffset ?? CGFloat(model.stop) * Self.tickSpacing
        ZStack(alignment: .top) {
            Canvas { context, size in
                drawTicks(context, size: size, offset: offset, count: count)
            }
            LinearGradient(stops: [
                .init(color: ApprovedColor.background.resolved(colorScheme), location: 0),
                .init(color: ApprovedColor.background.resolved(colorScheme).opacity(0), location: 0.16),
                .init(color: ApprovedColor.background.resolved(colorScheme).opacity(0), location: 0.84),
                .init(color: ApprovedColor.background.resolved(colorScheme), location: 1)
            ], startPoint: .leading, endPoint: .trailing)
            .allowsHitTesting(false)
            // `.needle`: 2 × 30, 10 pt above the bottom.
            RoundedRectangle(cornerRadius: 1)
                .fill(ApprovedColor.selection.resolved(colorScheme))
                .frame(width: 2, height: 30)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 10)
                .allowsHitTesting(false)
            if model.isFine {
                Text("Fine")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ApprovedColor.selection.resolved(colorScheme))
                    .accessibilityIdentifier("develop.ruler.fine")
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(dragGesture(count: count))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Presets"))
        .accessibilityValue(Text("\(model.displayedName), \(model.stop) of \(count)"))
        .accessibilityAdjustableAction { direction in
            model.step(by: direction == .increment ? 1 : -1)
        }
        .accessibilityIdentifier("develop.ruler")
    }

    // MARK: Drawing

    private func drawTicks(_ context: GraphicsContext, size: CGSize, offset: CGFloat, count: Int) {
        let centre = size.width / 2
        let first = max(0, Int(((offset - centre) / Self.tickSpacing).rounded(.down)) - 1)
        let last = min(count, Int(((offset + centre) / Self.tickSpacing).rounded(.up)) + 1)
        guard first <= last else { return }
        let tick = (colorScheme == .dark ? Color(hex: 0x45454B) : Color(hex: 0xC6C6CC))      // --tick
        let major = (colorScheme == .dark ? Color(hex: 0x85858D) : Color(hex: 0x8A8A92))     // --tickM
        let zero = ApprovedColor.inkSecondary.resolved(colorScheme)
        let label = ApprovedColor.inkTertiary.resolved(colorScheme)
        for index in first...last {
            let x = centre + CGFloat(index) * Self.tickSpacing - offset
            let isZero = index == 0, isMajor = index % 10 == 0
            let height: CGFloat = isZero ? 20 : isMajor ? 16 : 10
            let width: CGFloat = isZero ? 1.5 : 1
            let rect = CGRect(x: x - width / 2, y: size.height - 14 - height, width: width, height: height)
            context.fill(Path(rect), with: .color(isZero ? zero : isMajor ? major : tick))
            if index % 50 == 0, index > 0 {
                let text = context.resolve(Text("\(index)").font(.system(size: 9.5)).monospacedDigit().foregroundColor(label))
                context.draw(text, at: CGPoint(x: x, y: size.height), anchor: .bottom)
            }
        }
    }

    // MARK: Interaction

    private func dragGesture(count: Int) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if visualOffset == nil {
                    visualOffset = CGFloat(model.stop) * Self.tickSpacing
                    lastTranslation = 0
                    startHoldWatch()
                }
                let delta = value.translation.width - lastTranslation
                lastTranslation = value.translation.width
                if abs(delta) > 0.5 { lastMovement = .now }
                let speed = model.isFine ? Self.fineSpeed : 1
                let next = clampOffset((visualOffset ?? 0) - delta * speed, count: count)
                visualOffset = next
                model.dragChanged(to: Int((next / Self.tickSpacing).rounded()))
            }
            .onEnded { value in
                holdTask?.cancel()
                holdTask = nil
                var target = visualOffset ?? 0
                if !model.isFine {
                    // Momentum: where a native scroll view would come to rest.
                    target -= (value.predictedEndTranslation.width - value.translation.width)
                }
                let stop = Int((clampOffset(target, count: count) / Self.tickSpacing).rounded())
                withAnimation(.easeOut(duration: 0.25)) { visualOffset = CGFloat(stop) * Self.tickSpacing }
                model.dragEnded(at: stop)
                // Hand the position back to the model once the snap has settled.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(260))
                    if model.draggingStop == nil { visualOffset = nil }
                }
            }
    }

    private func clampOffset(_ value: CGFloat, count: Int) -> CGFloat {
        min(max(value, 0), CGFloat(count) * Self.tickSpacing)
    }

    /// Engages Fine once the finger has rested for `fineHoldDelay` during a drag.
    private func startHoldWatch() {
        holdTask?.cancel()
        lastMovement = .now
        holdTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if !model.isFine, ContinuousClock.now - lastMovement >= Self.fineHoldDelay {
                    model.setFine(true)
                }
            }
        }
    }
}
