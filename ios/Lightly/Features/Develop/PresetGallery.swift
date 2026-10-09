import SwiftUI

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
                    ScrollView(.vertical) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) { tiles }
                            .padding(12)
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
                    ScrollView(.horizontal) {
                        LazyHGrid(rows: [GridItem(.fixed(104)), GridItem(.fixed(104))], spacing: 12) { tiles }
                            .padding(.horizontal, 16).padding(.vertical, 4)
                    }.frame(height: 220)
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

private struct PresetTile: View {
    let session: EditorSession
    let preset: PresetPack.Preset?
    let expanded: Bool
    let selected: Bool
    let apply: () -> Void
    @State private var image: CGImage?
    @Environment(\.colorScheme) private var theme
    var body: some View {
        Button(action: apply) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
                        else { Rectangle().fill(.quaternary).overlay { ProgressView().controlSize(.small) } }
                    }.frame(height: expanded ? 142 : 76).frame(maxWidth: .infinity).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? ApprovedColor.selection.resolved(theme) : .clear, lineWidth: 2))
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, ApprovedColor.selection.resolved(theme)).padding(5) }
                }
                Text(preset?.displayName ?? "Original").approvedText(12).lineLimit(1).foregroundStyle(ApprovedColor.ink.resolved(theme))
            }.frame(width: expanded ? nil : 96)
        }.buttonStyle(.plain).accessibilityLabel(preset?.displayName ?? "Original").accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("develop.thumbnail." + (preset?.id ?? "original"))
            .task(id: session.thumbnailKey) { image = await session.presetThumbnail(preset) }
    }
}

private struct PresetScrollTop: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
