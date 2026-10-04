import SwiftUI

/// UI state of the Effects panel (approved `effectsPanel`: prototype `ui.sub`).
@MainActor
@Observable
final class EffectsPanelModel {
    enum Sub: String, CaseIterable { case leak, grain, vignette }

    let session: EditorSession
    var sub: Sub = .leak

    init(session: EditorSession) { self.session = session }

    var effects: EditRecipe.Effects { session.recipe.tools.effects }

    /// Prototype `toolUsed(s, 'effects')`: any effect switched on.
    var isUsed: Bool { effects.lightLeak.enabled || effects.grain.enabled || effects.vignette.enabled }

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
                              (.vignette, "Vignette", effects.vignette.enabled)],
                      selected: model.sub, wraps: wraps, identifierPrefix: "effects.sub") { model.sub = $0 }
            if let notice = model.conflictNotice {
                DevelopNotice(icon: .info, bold: nil, text: notice, actions: [])
            }
            switch model.sub {
            case .leak: leak
            case .grain: grain
            case .vignette: vignette
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
        ApprovedNote(text: Text("Drag on the photo to move the leak."))
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

    private func slider(_ label: String, _ key: WritableKeyPath<EditRecipe.Effects, Double>, _ range: ClosedRange<Double>) -> some View {
        PanelSlider(label: label, value: effects[keyPath: key], range: range, identifier: "slider.\(label.lowercased())",
                    onChange: { v in session.previewEffects { $0[keyPath: key] = v.rounded() } },
                    onEnd: { v in session.commitEffects { $0[keyPath: key] = v.rounded() } })
    }
}
