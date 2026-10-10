import SwiftUI

/// The preset gallery (Lightly 2 `developPanel` gallery): "Original" first, then the browsed category's presets as
/// live thumbnails of this photo.
/// - Compact (phone panel): two 84 pt rows, 96 pt columns, 10 pt between rows and 12 pt between columns, scrolling
///   sideways, the right edge fading (90 %). Swiping up expands it.
/// - Expanded (the overlay, and landscape iPad): two equal columns, 14 pt rows, 12 pt columns, 142 pt thumbnails,
///   scrolling down; pulling down from the top collapses it.
struct PresetGallery: View {
    @Bindable var model: DevelopPanelModel
    let expanded: Bool
    @State private var scrollSpace = UUID()
    @State private var atTop = true
    @State private var dragStartedAtTop: Bool?

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if expanded {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 14) { tiles }
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: PresetScrollTop.self, value: geometry.frame(in: .named(scrollSpace)).minY)
                            })
                    }
                    .coordinateSpace(name: scrollSpace)
                    .onPreferenceChange(PresetScrollTop.self) { atTop = $0 >= -1 }
                    .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { value in
                        if dragStartedAtTop == nil { dragStartedAtTop = atTop }
                        if dragStartedAtTop == true && value.translation.height > 0 && abs(value.translation.height) > abs(value.translation.width) {
                            model.galleryPull = value.translation.height
                        }
                    }.onEnded { _ in
                        withAnimation(.snappy(duration: 0.25)) {
                            if model.galleryPull > 60 { model.isExpanded = false }
                            model.galleryPull = 0
                        }
                        dragStartedAtTop = nil
                    })
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(rows: [GridItem(.fixed(84), spacing: 10), GridItem(.fixed(84), spacing: 10)], spacing: 12) { tiles }
                    }
                    .frame(height: 84 * 2 + 10)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                    .simultaneousGesture(DragGesture(minimumDistance: 16).onChanged { value in
                        if value.translation.height < -32 && abs(value.translation.height) > abs(value.translation.width) * 1.3 {
                            withAnimation(.snappy(duration: 0.25)) { model.isExpanded = true }
                        }
                    })
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(expanded ? "develop.gallery.expanded" : "develop.gallery.compact")
            .accessibilityAction(named: expanded ? "Collapse presets" : "Expand presets") { model.isExpanded.toggle() }
            .onChange(of: model.currentCategoryID) { _, _ in proxy.scrollTo("original", anchor: .topLeading) }
        }
    }

    @ViewBuilder private var tiles: some View {
        tile(nil).id("original")
        ForEach(model.currentPresets, id: \.id) { preset in tile(preset).id(preset.id) }
    }

    private func tile(_ preset: PresetPack.Preset?) -> some View {
        PresetTile(session: model.session, preset: preset, expanded: expanded,
                   selected: model.session.recipe.look?.lookId == preset?.id) { model.selectThumbnail(preset) }
    }
}

/// One gallery tile: the thumbnail (62 pt compact, 142 pt expanded; 14 pt corners), the selected one with a 2 pt
/// inset accent ring and a 20 pt lime check badge 6 pt in from the top-trailing corner; the name below (11.5 pt;
/// bold ink when selected, medium ink2 otherwise), 5 pt between.
private struct PresetTile: View {
    let session: EditorSession
    let preset: PresetPack.Preset?
    let expanded: Bool
    let selected: Bool
    let apply: () -> Void
    @State private var image: CGImage?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = L2(scheme: scheme)
        Button(action: apply) {
            VStack(alignment: .leading, spacing: 5) {
                Group {
                    if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
                    else { Rectangle().fill(c(ApprovedColor.chip)).overlay { ProgressView().controlSize(.small) } }
                }
                .frame(height: expanded ? 142 : 62).frame(maxWidth: .infinity)
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
                Text(preset?.displayName ?? "Original")
                    .l2Text(11.5, weight: selected ? .bold : .medium)
                    .foregroundStyle(selected ? c(ApprovedColor.ink) : c(ApprovedColor.inkSecondary))
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(width: expanded ? nil : 96, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset?.displayName ?? "Original")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("develop.thumbnail." + (preset?.id ?? "original"))
        .task(id: session.thumbnailKey) { image = await session.presetThumbnail(preset) }
    }
}

private struct PresetScrollTop: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
