import SwiftUI

/// Effects › Light Leaks gallery (owner, 2026-10-11; mockup `leakGallery`, screens `fx-leak` and `fx-leak-none`): it
/// replaces the four style chips. "None" first (the photo without a leak), then every leak of the pack in its order,
/// each the photo with that leak screened over it at 85 %. Two 84 pt rows, 96 pt columns, 10 pt between rows and 12 pt
/// between columns, filled column by column and scrolling sideways, the right edge fading (88 %, the mockup's
/// `fadeRight`) while there are more leaks that way. Without a bundled pack only None is offered.
struct LeakGallery: View {
    let session: EditorSession
    var pack: LeakPack = .bundled

    static let rowHeight: CGFloat = 84
    static let columnWidth: CGFloat = 96
    static let rowGap: CGFloat = 10
    static let columnGap: CGFloat = 12

    /// True while leaks are hidden past the trailing edge: only then does the end fade (owner report 2026-10-11).
    @State private var hidesMore = false

    /// The tiles in order: nil is None.
    static func tileIDs(_ pack: LeakPack) -> [String?] { [nil] + pack.leaks.map(\.id) }

    /// The leak the gallery shows as chosen; nil (None) while the effect is off. A drawn style from an earlier edit
    /// matches no tile.
    static func selectedLeakID(_ leak: EditRecipe.Effects.LightLeak) -> String? {
        leak.enabled ? leak.style.leakImageID : nil
    }

    var body: some View {
        let lightLeak = session.recipe.tools.effects.lightLeak
        let base = session.leakGalleryBase()
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: [GridItem(.fixed(Self.rowHeight), spacing: Self.rowGap), GridItem(.fixed(Self.rowHeight), spacing: Self.rowGap)],
                      spacing: Self.columnGap) {
                LeakTile(leak: nil, pack: pack, base: base, selected: !lightLeak.enabled) { session.chooseLightLeak(nil) }
                ForEach(pack.leaks) { leak in
                    LeakTile(leak: leak, pack: pack, base: base, selected: lightLeak.enabled && lightLeak.style.leakImageID == leak.id) {
                        session.chooseLightLeak(leak.id)
                    }
                }
            }
            .reportsTrailingEdge(in: "leakgallery")
        }
        .frame(height: Self.rowHeight * 2 + Self.rowGap)
        .trailingOverflowFade(in: "leakgallery", hidesMore: $hidesMore)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("effects.leak.gallery")
        .trailingFadeAccessibilityValue(hidesMore)
    }
}

/// One leak tile, drawn as the preset gallery's compact tile (PresetTile): a 62 pt thumbnail with 14 pt corners; when
/// chosen, a 2 pt inset accent ring and a 20 pt lime check badge 6 pt in from the top-trailing corner; the name below
/// (11.5 pt; bold ink when chosen, medium ink2 otherwise), 5 pt between.
private struct LeakTile: View {
    let leak: LeakPack.Leak?
    let pack: LeakPack
    let base: CGImage?
    let selected: Bool
    let choose: () -> Void
    @State private var thumbnail: CGImage?
    @Environment(\.colorScheme) private var scheme

    private var name: String { leak?.name ?? "None" }

    var body: some View {
        let c = L2(scheme: scheme)
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 5) {
                Color.clear
                    .frame(height: 62).frame(maxWidth: .infinity)
                    .overlay {
                        if let base { Image(decorative: base, scale: 1).resizable().scaledToFill() }
                        else { Rectangle().fill(c(ApprovedColor.chip)) }
                    }
                    .overlay {
                        // Mockup: the leak thumbnail `center/cover`, `mix-blend-mode: screen; opacity: 0.85`.
                        if let thumbnail {
                            Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                                .opacity(0.85).blendMode(.screen)
                        }
                    }
                    // The screen blend stays inside the tile.
                    .compositingGroup()
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c(ApprovedColor.selection), lineWidth: 2)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            ApprovedIconView(icon: .check, size: 13).foregroundStyle(c(ApprovedColor.onAccent))
                                .frame(width: 20, height: 20).background(Circle().fill(c(ApprovedColor.accent)))
                                .padding(6)
                        }
                    }
                Text(verbatim: name)
                    .l2Text(11.5, weight: selected ? .bold : .medium)
                    .foregroundStyle(selected ? c(ApprovedColor.ink) : c(ApprovedColor.inkSecondary))
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(width: LeakGallery.columnWidth, alignment: .leading)
            // As PresetTile: the tap area is the tile's own box, never a filled image's overflow.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("effects.leak." + (leak?.id ?? "none"))
        .task(id: leak?.id) {
            guard let leak, let url = pack.thumbnailURL(leak) else { return }
            thumbnail = await Task.detached(priority: .utility) { LeakPackLoader.decode(url) }.value
        }
    }
}
