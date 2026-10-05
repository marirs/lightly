import SwiftUI
import simd

/// UI state of the Effects panel (approved `effectsPanel`: prototype `ui.sub`).
@MainActor
@Observable
final class EffectsPanelModel {
    enum Sub: String, CaseIterable { case leak, grain, vignette, selective }

    let session: EditorSession
    var sub: Sub = .leak
    /// Selective Colour: (+) was tapped, so the next tap on the photo keeps another colour.
    var isAddingColour = false

    /// Selective Colour: a tap on the photo picks a colour (the first one, or after (+)).
    var picksOnTap: Bool { sub == .selective && (effects.selectiveColour.colours.isEmpty || isAddingColour) }

    init(session: EditorSession) { self.session = session }

    var effects: EditRecipe.Effects { session.recipe.tools.effects }

    /// Prototype `toolUsed(s, 'effects')`: any effect switched on.
    var isUsed: Bool {
        effects.lightLeak.enabled || effects.grain.enabled || effects.vignette.enabled || !effects.selectiveColour.colours.isEmpty
    }

    /// The approved notice when the applied preset carries its own grain or vignette and the
    /// person's is on too: the two are composed, never one replacing the other.
    // v3 differs: the prototype decides "carries its own" with a stand-in hash (`presetHasEffect`,
    // which the review marks as an open question); native reads the preset's real recipe
    // (`recipe.finishing`).
    var conflictNotice: String? {
        guard let finishing = session.appliedPresetFinishing else { return nil }
        switch sub {
        case .grain where effects.grain.enabled && finishing.grain != nil:
            return "The applied preset already includes its own grain. This one is added to it, not replaced."
        case .vignette where effects.vignette.enabled && finishing.vignette != nil:
            return "The applied preset already includes its own vignette. This one is added to it, not replaced."
        default:
            return nil
        }
    }
}

/// The approved Effects panel.
struct EffectsPanelView: View {
    @Bindable var model: EffectsPanelModel
    let roomy: Bool
    let wraps: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var session: EditorSession { model.session }
    private var effects: EditRecipe.Effects { model.effects }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if roomy { PanelTitle(text: "Effects") }
            PanelTabs(items: [(EffectsPanelModel.Sub.leak, "Light Leaks", effects.lightLeak.enabled),
                              (.grain, "Grain", effects.grain.enabled),
                              (.vignette, "Vignette", effects.vignette.enabled),
                              (.selective, "Selective Colour", !effects.selectiveColour.colours.isEmpty)],
                      selected: model.sub, wraps: wraps, identifierPrefix: "effects.sub") { model.sub = $0 }
            if let notice = model.conflictNotice {
                DevelopNotice(icon: .info, bold: nil, text: notice, actions: [])
            }
            switch model.sub {
            case .leak: leak
            case .grain: grain
            case .vignette: vignette
            case .selective: selective
            }
        }
    }

    /// `.listrow` "On"/"Off" with the switch (`onRow`), 44 pt high, no rule.
    /// VoiceOver names the effect ("Vignette, switch, on"); the row itself shows only On/Off.
    private func onRow(_ isOn: Bool, name: String, identifier: String, toggle: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in toggle() })) {
            Text(isOn ? "On" : "Off").approvedText(15).foregroundStyle(ApprovedColor.ink.resolved(colorScheme))
        }
        .toggleStyle(ApprovedSwitchToggleStyle())
        .padding(.horizontal, ApprovedMetrics.rowHorizontalPadding)
        .frame(minHeight: 44)
        .accessibilityLabel(Text(name))
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var leak: some View {
        let l = effects.lightLeak
        onRow(l.enabled, name: "Light Leaks", identifier: "effects.leak.toggle") { session.commitEffects { $0.lightLeak.enabled.toggle() } }
        ChipRow {
            ForEach(Self.leakStyles, id: \.style) { option in
                OptionChip(isOn: l.style == option.style, identifier: "effects.leak.\(option.style.rawValue)",
                           action: { session.commitEffects { $0.lightLeak.style = option.style } }) {
                    Text(option.label).approvedText(15)
                }
            }
        }
        slider("Intensity", \.lightLeak.intensity, 0...100)
        slider("Rotation", \.lightLeak.rotation, -180...180)
        ApprovedNote("Drag on the photo to move the leak.")
    }

    static let leakStyles: [(style: EditRecipe.Effects.LightLeak.Style, label: String)] = [
        (.warm, "Warm edge"), (.amber, "Amber flare"), (.rose, "Rose"), (.prism, "Prism")
    ]

    @ViewBuilder
    private var grain: some View {
        let g = effects.grain
        onRow(g.enabled, name: "Grain", identifier: "effects.grain.toggle") { session.commitEffects { $0.grain.enabled.toggle() } }
        ChipRow {
            ForEach([(EditRecipe.Effects.Grain.Style.fine, "Fine"), (.film, "Film"), (.coarse, "Coarse")], id: \.0) { style, label in
                OptionChip(isOn: g.style == style, identifier: "effects.grain.\(style.rawValue)",
                           action: { session.commitEffects { $0.grain.style = style } }) {
                    Text(label).approvedText(15)
                }
            }
        }
        slider("Amount", \.grain.amount, 0...100)
        slider("Size", \.grain.size, 0...100)
        slider("Roughness", \.grain.roughness, 0...100)
    }

    @ViewBuilder
    private var vignette: some View {
        onRow(effects.vignette.enabled, name: "Vignette", identifier: "effects.vignette.toggle") { session.commitEffects { $0.vignette.enabled.toggle() } }
        slider("Amount", \.vignette.amount, 0...100)
        slider("Size", \.vignette.size, 0...100)
        slider("Softness", \.vignette.softness, 0...100)
    }

    // MARK: Selective Colour (owner-approved layout, 2026-10-05)

    /// Nothing kept: one instruction. Then the kept colours, (+) and Clear on one row, Range and Strength below.
    /// No On switch: a kept colour applies the effect.
    @ViewBuilder
    private var selective: some View {
        let colours = effects.selectiveColour.colours
        if colours.isEmpty {
            HStack(spacing: 10) {
                ApprovedIconView(icon: .picker, size: 20)
                Text("Tap a colour in the photo to keep it.").approvedText(15)
            }
            .foregroundStyle(ApprovedColor.inkSecondary.resolved(colorScheme))
            .padding(.horizontal, ApprovedMetrics.rowHorizontalPadding)
            .padding(.vertical, 14)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("effects.selective.hint")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(colours.enumerated()), id: \.offset) { index, kept in
                        keptColourDot(kept, index: index, removable: colours.count > 1)
                    }
                    addColourButton
                    Button("Clear") { model.isAddingColour = false; session.clearSelectiveColour() }
                        .buttonStyle(ApprovedSmallQuietButtonStyle())
                        .accessibilityIdentifier("effects.selective.clear")
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
            }
            if model.isAddingColour { ApprovedNote("Tap another colour in the photo.") }
            selectiveSlider("Range", \.range)
            selectiveSlider("Strength", \.strength)
        }
    }

    /// A kept colour: a 28 pt dot in a 44 pt target. With more than one colour, a small × removes just this one.
    @ViewBuilder
    private func keptColourDot(_ kept: EditRecipe.Effects.SelectiveColour.Kept, index: Int, removable: Bool) -> some View {
        let dot = Circle().fill(Self.displayColour(kept.oklab))
            .overlay(Circle().strokeBorder(ApprovedColor.hairline.resolved(colorScheme), lineWidth: 1))
            .frame(width: 28, height: 28)
        if removable {
            Button { session.removeSelectiveColour(at: index) } label: {
                dot.overlay(alignment: .topTrailing) {
                    ApprovedIconView(icon: .close, size: 10)
                        .foregroundStyle(ApprovedColor.background.resolved(colorScheme))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(ApprovedColor.ink.resolved(colorScheme)))
                        .offset(x: 4, y: -4)
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove colour \(index + 1)"))
            .accessibilityIdentifier("effects.selective.remove.\(index)")
        } else {
            dot.frame(width: 44, height: 44)
                .accessibilityLabel(Text("Kept colour"))
                .accessibilityIdentifier("effects.selective.colour.\(index)")
        }
    }

    /// (+): the next tap on the photo keeps another colour.
    private var addColourButton: some View {
        let adding = model.isAddingColour
        let tint = (adding ? ApprovedColor.selection : ApprovedColor.inkSecondary).resolved(colorScheme)
        return Button { model.isAddingColour.toggle() } label: {
            ApprovedIconView(icon: .plus, size: 15)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(tint, style: StrokeStyle(lineWidth: 1, dash: adding ? [] : [2, 2])))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(effects.selectiveColour.colours.count >= EditorSession.maximumKeptColours)
        .accessibilityLabel(Text("Add another colour"))
        .accessibilityAddTraits(adding ? .isSelected : [])
        .accessibilityIdentifier("effects.selective.add")
    }

    private func selectiveSlider(_ label: String, _ key: WritableKeyPath<EditRecipe.Effects.SelectiveColour, Double>) -> some View {
        PanelSlider(label: label, value: effects.selectiveColour[keyPath: key], range: 0...100, identifier: "slider.\(label.lowercased())",
                    onChange: { v in session.previewEffects { $0.selectiveColour[keyPath: key] = v.rounded() } },
                    onEnd: { v in session.commitEffects { $0.selectiveColour[keyPath: key] = v.rounded() } })
    }

    /// A kept colour as shown on its dot (its OKLab, in sRGB).
    static func displayColour(_ oklab: SIMD3<Double>) -> Color {
        let rgb = simd_clamp(DevelopGlobalProgram.linearToSRGB(DevelopGlobalProgram.okLabToLinear(oklab)), .zero, .one)
        return Color(.sRGB, red: rgb.x, green: rgb.y, blue: rgb.z)
    }

    private func slider(_ label: String, _ key: WritableKeyPath<EditRecipe.Effects, Double>, _ range: ClosedRange<Double>) -> some View {
        PanelSlider(label: label, value: effects[keyPath: key], range: range, identifier: "slider.\(label.lowercased())",
                    onChange: { v in session.previewEffects { $0[keyPath: key] = v.rounded() } },
                    onEnd: { v in session.commitEffects { $0[keyPath: key] = v.rounded() } })
    }
}
