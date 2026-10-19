import SwiftUI

/// Portrait › Sunglasses (owner-approved design `docs/ui/proposals/portrait-sunglasses-v2.html`, 2026-10-13): the tab's
/// controls below the reset row, in the design's four states.
/// 1 · Add a pair: the pairs row (None first), Lenses, Darkness and Size.
/// 2 · Already wearing glasses: the "Glasses found." notice above the same controls, without Size (as the design shows).
/// 3 · Turned and side faces: as 1 (the renderer handles the turn).
/// 4 · Eyes not visible: the notice, and the pairs row dimmed with None chosen; nothing else.
struct SunglassesControls: View {
    @Bindable var model: PortraitPanelModel
    let pack: SunglassesPack?
    @Environment(\.colorScheme) private var colorScheme

    /// The approved lens chips and their dots (design `chips`): Dark, Brown, Green, Gradient, Mirror.
    static let lenses: [(lens: EditRecipe.FaceEdit.Sunglasses.Lens, title: String, dot: AnyShapeStyle)] = [
        (.dark, "Dark", AnyShapeStyle(Color(red: 0x2A / 255, green: 0x2E / 255, blue: 0x33 / 255))),
        (.brown, "Brown", AnyShapeStyle(Color(red: 0x6B / 255, green: 0x4A / 255, blue: 0x2F / 255))),
        (.green, "Green", AnyShapeStyle(Color(red: 0x3F / 255, green: 0x54 / 255, blue: 0x40 / 255))),
        (.gradient, "Gradient", AnyShapeStyle(LinearGradient(colors: [Color(red: 0x2A / 255, green: 0x2E / 255, blue: 0x33 / 255),
                                                                     Color(red: 0xC9 / 255, green: 0xC4 / 255, blue: 0xBB / 255)],
                                                            startPoint: .top, endPoint: .bottom))),
        (.mirror, "Mirror", AnyShapeStyle(LinearGradient(colors: [Color(red: 0x7F / 255, green: 0xB7 / 255, blue: 0xFF / 255),
                                                                 Color(red: 0x2B / 255, green: 0x5E / 255, blue: 0xA8 / 255)],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))),
    ]

    var body: some View {
        let state = model.sunglassesState
        let glasses = model.edit(forFace: model.selectedFace).sunglasses ?? .none
        VStack(alignment: .leading, spacing: 4) {
            switch state {
            case .eyesNotVisible:
                L2Notice(icon: .info, bold: "The eyes need to be visible.",
                         text: " The eyes are covered or the face is too small. Other faces in the photo can still have sunglasses.")
                pairsRow(selected: nil, enabled: false)
            case .glassesFound:
                L2Notice(icon: .info, bold: "Glasses found.", text: " Choose a pair to replace them; their own glasses are taken out first.")
                pairsRow(selected: glasses.pair, enabled: true)
                lensControls(glasses, showsSize: false)
            case .ready, .analysing:
                pairsRow(selected: glasses.pair, enabled: state == .ready)
                lensControls(glasses, showsSize: true)
            }
        }
    }

    // MARK: - Pairs (design `styles`)

    private func pairsRow(selected: String?, enabled: Bool) -> some View {
        let pairs = pack?.pairs ?? []
        // The chosen pair is scrolled into view (the design shows it in the row), as the other rows do.
        let selectedIndex = selected.flatMap { id in pairs.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        return ChipRow(spacing: 8, scrolledToIndex: selectedIndex) {
            PairTile(title: "None", thumbnail: nil, isOn: selected == nil, identifier: "sunglasses.pair.none") {
                model.setSunglassesPair(nil)
            }
            .id(0)
            ForEach(Array(pairs.enumerated()), id: \.element.id) { index, pair in
                PairTile(title: pair.name, thumbnail: pack?.thumbnail(pair, dark: colorScheme == .dark), isOn: selected == pair.id,
                         identifier: "sunglasses.pair.\(pair.name.lowercased())") {
                    model.setSunglassesPair(pair.id)
                }
                .id(index + 1)
            }
        }
        .opacity(enabled ? 1 : 0.4)
        .allowsHitTesting(enabled)
    }

    // MARK: - Lenses, Darkness, Size

    @ViewBuilder
    private func lensControls(_ glasses: EditRecipe.FaceEdit.Sunglasses, showsSize: Bool) -> some View {
        let c = L2(scheme: colorScheme)
        Text("Lenses")
            .l2Text(11.5, weight: .semibold)
            .foregroundStyle(c(ApprovedColor.inkSecondary))
            .padding(.top, 6)
        ChipRow(spacing: 6) {
            ForEach(Self.lenses, id: \.title) { lens in
                OptionChip(isOn: glasses.lens == lens.lens, identifier: "sunglasses.lens.\(lens.lens.rawValue)",
                           action: { model.updateSunglasses({ $0.lens = lens.lens }, commit: true) }) {
                    Circle().fill(lens.dot).frame(width: 12, height: 12)
                    Text(lens.title)
                }
            }
        }
        PanelSlider(label: "Darkness", value: glasses.darkness, range: 0...100, identifier: "slider.darkness",
                    onChange: { v in model.updateSunglasses({ $0.darkness = v.rounded() }, commit: false) },
                    onEnd: { v in model.updateSunglasses({ $0.darkness = v.rounded() }, commit: true) })
        if showsSize {
            // Size fine-tunes the automatic fit, centred on it (−50 … 50).
            PanelSlider(label: "Size", value: glasses.size, range: -50...50, identifier: "slider.size",
                        onChange: { v in model.updateSunglasses({ $0.size = v.rounded() }, commit: false) },
                        onEnd: { v in model.updateSunglasses({ $0.size = v.rounded() }, commit: true) })
        }
    }
}

/// One pair (design `.st`): a 66 × 54 pt tile, 14 pt corners, the pair's picture above its name (10.5 pt semibold);
/// a 1 pt hairline border, or a 2 pt selection border with the name in ink when chosen. None shows a short line.
/// In dark mode the picture is the pack's studio-lit dark-mode render (owner choice A, 2026-10-19; the design shows
/// light mode only), so black frames show their edges on the dark tile.
private struct PairTile: View {
    let title: String
    let thumbnail: UIImage?
    let isOn: Bool
    let identifier: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let c = L2(scheme: colorScheme)
        Button(action: action) {
            VStack(spacing: 3) {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFit()
                    } else {
                        Rectangle().fill(c(ApprovedColor.inkTertiary)).frame(width: 32, height: 1.5)
                    }
                }
                .frame(width: 52, height: 22)
                Text(verbatim: title)
                    .l2Text(10.5, weight: .semibold)
                    .lineLimit(1)
                    .foregroundStyle(isOn ? c(ApprovedColor.ink) : c(ApprovedColor.inkSecondary))
            }
            .frame(width: 66, height: 54)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isOn ? c(ApprovedColor.selection) : c(ApprovedColor.hairline), lineWidth: isOn ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
