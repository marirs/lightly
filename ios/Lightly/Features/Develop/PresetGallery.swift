import SwiftUI

struct PresetGallery: View {
    @Bindable var model: DevelopPanelModel
    let expanded: Bool
    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if expanded {
                    ScrollView(.vertical) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) { tiles }
                            .padding(12)
                    }
                } else {
                    ScrollView(.horizontal) {
                        LazyHGrid(rows: [GridItem(.fixed(104)), GridItem(.fixed(104))], spacing: 12) { tiles }
                            .padding(.horizontal, 16).padding(.vertical, 4)
                    }.frame(height: 220)
                }
            }
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
