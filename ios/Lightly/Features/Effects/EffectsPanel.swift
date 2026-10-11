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

    /// Lightly 2 `effectsPanel`, a 5 pt column: the tabs (orange dot on effects in use), the reset row, the preset
    /// conflict notice, the effect's controls. No On/Off switches: choosing a leak or style, or moving a slider, turns it on.
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            PanelTabs(items: [(EffectsPanelModel.Sub.leak, "Light Leaks", effects.lightLeak.enabled),
                              (.grain, "Grain", effects.grain.enabled),
                              (.vignette, "Vignette", effects.vignette.enabled),
                              (.selective, "Selective Colour", !effects.selectiveColour.colours.isEmpty)],
                      selected: model.sub, wraps: wraps, identifierPrefix: "effects.sub") { model.sub = $0 }
            PanelResetRow(session: session, section: "effects", title: ["leak": "Light Leaks", "grain": "Grain", "vignette": "Vignette", "selective": "Selective Colour"][model.sub.rawValue]!, adjustment: model.sub.rawValue)
            if let notice = model.conflictNotice {
                L2Notice(icon: .info, text: notice)
            }
            switch model.sub {
            case .leak: leak
            case .grain: grain
            case .vignette: vignette
            case .selective: selective
            }
        }
    }

    /// Owner amendment 2026-10-11 (mockup `effectsPanel` › `leakGallery`): the leak gallery replaces the four style
    /// chips; Intensity, Rotation and the note are unchanged.
    @ViewBuilder
    private var leak: some View {
        LeakGallery(session: session)
        slider("Intensity", \.lightLeak.intensity, 0...100)
        slider("Rotation", \.lightLeak.rotation, -180...180)
        ApprovedNote("Drag on the photo to move the leak.")
    }

    @ViewBuilder
    private var grain: some View {
        let g = effects.grain
        ChipRow(spacing: 6) {
            ForEach([(EditRecipe.Effects.Grain.Style.fine, "Fine"), (.film, "Film"), (.coarse, "Coarse")], id: \.0) { style, label in
                OptionChip(isOn: g.enabled && g.style == style, identifier: "effects.grain.\(style.rawValue)",
                           action: { session.commitEffects { $0.grain.style = style; $0.grain.enabled = true; if $0.grain.amount == 0 { $0.grain.amount = 25 } } }) {
                    Text(LocalizedStringKey(label))
                }
            }
        }
        slider("Amount", \.grain.amount, 0...100)
        slider("Size", \.grain.size, 0...100)
        slider("Roughness", \.grain.roughness, 0...100)
    }

    @ViewBuilder
    private var vignette: some View {
        slider("Amount", \.vignette.amount, 0...100)
        slider("Size", \.vignette.size, 0...100)
        slider("Softness", \.vignette.softness, 0...100)
    }

    // MARK: Selective Colour (reference: docs/ui/proposals/selective-colour at 330cf5b; status in its README)

    /// Nothing kept: one instruction. Then the kept colours, (+) and Clear on one row, Range and Strength below.
    /// No On switch: a kept colour applies the effect.
    /// Nothing kept: the picker icon and "Tap a colour in the photo to keep it." (14 pt ink2, 44 pt row). Then the kept
    /// colours (30 pt dots with a 2 pt sheet gap and a 1 pt line; × badges with several), the (+) circle (dashed ink3,
    /// solid accent while adding) and Clear at the end; the hint while adding; Range and Strength.
    @ViewBuilder
    private var selective: some View {
        let colours = effects.selectiveColour.colours
        let c = L2(scheme: colorScheme)
        if colours.isEmpty && !model.isAddingColour {
            HStack(spacing: 10) {
                ApprovedIconView(icon: .picker, size: 20)
                Text("Tap a colour in the photo to keep it.").l2Text(14)
            }
            .foregroundStyle(c(ApprovedColor.inkSecondary))
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("effects.selective.hint")
        } else {
            HStack(spacing: 10) {
                ForEach(Array(colours.enumerated()), id: \.offset) { index, kept in
                    keptColourDot(kept, index: index, removable: colours.count > 1)
                }
                addColourButton
                Spacer(minLength: 0)
                Button("Clear") { model.isAddingColour = false; session.clearSelectiveColour() }
                    .buttonStyle(L2LinkButtonStyle())
                    .accessibilityIdentifier("effects.selective.clear")
            }
            .frame(minHeight: 44)
            if model.isAddingColour { L2Note(text: Text("Tap another colour in the photo.")) }
        }
        if !colours.isEmpty || model.isAddingColour {
            selectiveSlider("Range", \.range)
            selectiveSlider("Strength", \.strength)
        }
    }

    @ViewBuilder
    private func keptColourDot(_ kept: EditRecipe.Effects.SelectiveColour.Kept, index: Int, removable: Bool) -> some View {
        let c = L2(scheme: colorScheme)
        let dot = Circle().fill(Self.displayColour(kept.oklab))
            .frame(width: 30, height: 30)
            .background(Circle().fill(c(ApprovedColor.sheet)).padding(-2))
            .overlay(Circle().stroke(c(ApprovedColor.hairline), lineWidth: 1).padding(-3))
        if removable {
            Button { session.removeSelectiveColour(at: index) } label: {
                dot.overlay(alignment: .topTrailing) {
                    ApprovedIconView(icon: .close, size: 10)
                        .foregroundStyle(c(ApprovedColor.background))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(c(ApprovedColor.ink)))
                        .offset(x: 6, y: -6)
                }
                .frame(width: 36, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove colour \(index + 1)"))
            .accessibilityIdentifier("effects.selective.remove.\(index)")
        } else {
            dot.frame(width: 36, height: 44)
                .accessibilityLabel(Text("Kept colour"))
                .accessibilityIdentifier("effects.selective.colour.\(index)")
        }
    }

    private var addColourButton: some View {
        let adding = model.isAddingColour
        let c = L2(scheme: colorScheme)
        let tint = adding ? c(ApprovedColor.selection) : c(ApprovedColor.inkSecondary)
        return Button { model.isAddingColour.toggle() } label: {
            ApprovedIconView(icon: .plus, size: 16)
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(adding ? c(ApprovedColor.selection) : c(ApprovedColor.inkTertiary),
                                               style: StrokeStyle(lineWidth: 1.5, dash: adding ? [] : [3, 2])))
                .frame(width: 36, height: 44)
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

    private func displayedEffectValue(_ key: WritableKeyPath<EditRecipe.Effects, Double>) -> Double {
        if key == \.lightLeak.intensity && !effects.lightLeak.enabled { return 0 }
        if key == \.grain.amount && !effects.grain.enabled { return 0 }
        if key == \.vignette.amount && !effects.vignette.enabled { return 0 }
        return effects[keyPath: key]
    }

    private func applyEffectValue(_ value: inout EditRecipe.Effects, _ key: WritableKeyPath<EditRecipe.Effects, Double>, _ amount: Double) {
        value[keyPath: key] = amount
        switch model.sub {
        case .leak:
            if key != \.lightLeak.intensity && value.lightLeak.intensity == 0 { value.lightLeak.intensity = 35 }
            value.lightLeak.enabled = value.lightLeak.intensity > 0
        case .grain:
            if key != \.grain.amount && value.grain.amount == 0 { value.grain.amount = 25 }
            value.grain.enabled = value.grain.amount > 0
        case .vignette:
            if key != \.vignette.amount && value.vignette.amount == 0 { value.vignette.amount = 25 }
            value.vignette.enabled = value.vignette.amount > 0
        case .selective: break
        }
    }

    private func slider(_ label: String, _ key: WritableKeyPath<EditRecipe.Effects, Double>, _ range: ClosedRange<Double>) -> some View {
        PanelSlider(label: label, value: displayedEffectValue(key), range: range, identifier: "slider.\(label.lowercased())",
                    onChange: { v in session.previewEffects { applyEffectValue(&$0, key, v.rounded()) } },
                    onEnd: { v in session.commitEffects { applyEffectValue(&$0, key, v.rounded()) } })
    }
}
