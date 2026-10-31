import SwiftUI

/// Effects › Ink gallery (owner-approved 2026-10-31, docs/ui/proposals/ink-2026-10-31 `inkGallery`, screens `fx-ink-none`
/// and `fx-ink`): built as the Light Leaks gallery. "None" first (the photo without ink), then every ink of the pack in its
/// order, each showing this photo through that ink: a stroke ink on the chosen paper, an overlay ink multiplied over it.
/// Two 84 pt rows, 96 pt columns, filled column by column and scrolling sideways, the right edge fading while more inks
/// are that way. Without a bundled pack only None is offered.
struct InkGallery: View {
    let session: EditorSession
    var pack: InkPack = .bundled

    /// True while inks are hidden past the trailing edge: only then does the end fade.
    @State private var hidesMore = false

    var body: some View {
        let chosen = session.recipe.tools.effects.ink
        let base = session.leakGalleryBase()
        let paper = InkEvaluator.colour(chosen?.paper ?? EditRecipe.Effects.Ink.defaultPaper)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: [GridItem(.fixed(LeakGallery.rowHeight), spacing: LeakGallery.rowGap),
                                 GridItem(.fixed(LeakGallery.rowHeight), spacing: LeakGallery.rowGap)],
                          spacing: LeakGallery.columnGap) {
                    InkTile(ink: nil, pack: pack, base: base, paper: paper, selected: chosen == nil) { session.chooseInk(nil) }
                        .id("none")
                    ForEach(pack.inks) { ink in
                        InkTile(ink: ink, pack: pack, base: base, paper: paper, selected: chosen?.id == ink.id) { session.chooseInk(ink.id) }
                            .id(ink.id)
                    }
                }
                .reportsTrailingEdge(in: "inkgallery")
            }
            // Mockup: the gallery is drawn scrolled so the chosen ink is in view (`fx-ink-bloom`).
            .onAppear { if let id = chosen?.id { proxy.scrollTo(id, anchor: .center) } }
        }
        .frame(height: LeakGallery.rowHeight * 2 + LeakGallery.rowGap)
        .trailingOverflowFade(in: "inkgallery", hidesMore: $hidesMore)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("effects.ink.gallery")
        .trailingFadeAccessibilityValue(hidesMore)
    }
}

/// One ink tile, drawn as a leak tile (LeakTile): a 62 pt thumbnail with 14 pt corners; when chosen, a 2 pt inset accent
/// ring and the 20 pt lime check badge; the name below.
private struct InkTile: View {
    let ink: InkPack.Ink?
    let pack: InkPack
    let base: CGImage?
    let paper: SIMD3<Float>
    let selected: Bool
    let choose: () -> Void
    @State private var thumbnail: CGImage?
    @Environment(\.colorScheme) private var scheme

    private var name: String { ink?.name ?? "None" }

    @ViewBuilder
    private func photo(_ c: L2) -> some View {
        if let base { Image(decorative: base, scale: 1).resizable().scaledToFill() }
        else { Rectangle().fill(c(ApprovedColor.chip)) }
    }

    var body: some View {
        let c = L2(scheme: scheme)
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 5) {
                Color.clear
                    .frame(height: 62).frame(maxWidth: .infinity)
                    .overlay { art(c) }
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("effects.ink." + (ink?.id ?? "none"))
        .task(id: ink?.id) {
            guard let ink, let url = pack.thumbnailURL(ink) else { return }
            thumbnail = await Task.detached(priority: .utility) { InkPackLoader.decode(url) }.value
        }
    }

    /// Mockup `inkLayers`: a stroke ink is the paper, then the photo masked by the stroke fitted whole with a 6 % margin;
    /// an overlay ink is the photo with the ink multiplied over it.
    @ViewBuilder
    private func art(_ c: L2) -> some View {
        if let ink, let thumbnail {
            switch ink.kind {
            case .stroke:
                ZStack {
                    Rectangle().fill(Color(.sRGB, red: Double(paper.x), green: Double(paper.y), blue: Double(paper.z)))
                    photo(c).mask {
                        GeometryReader { g in
                            Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                                .luminanceToAlpha()
                                .frame(width: g.size.width * InkEvaluator.strokeFit, height: g.size.height * InkEvaluator.strokeFit)
                                .position(x: g.size.width / 2, y: g.size.height / 2)
                        }
                    }
                }
            case .overlay:
                photo(c).overlay { Image(decorative: thumbnail, scale: 1).resizable().scaledToFill().blendMode(.multiply) }
            }
        } else {
            photo(c)
        }
    }
}
