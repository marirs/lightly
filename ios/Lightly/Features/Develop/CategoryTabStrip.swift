import SwiftUI

/// The phone's single row of category tabs (`.devhead .tabs`): scrolls sideways, fades at both
/// ends, and after every change brings the selected tab to 120 pt from the screen's leading edge
/// when the row overflows (prototype `buildRulers`: `scrollLeft = on.offsetLeft - 120`).
///
/// A native horizontal scroll view (so dragging and momentum behave as the prototype's
/// `overflow-x: auto` row does); the selected tab is placed with `scrollTo` and an anchor computed
/// so its leading edge lands 120 pt from the screen edge. The scroll view clamps at both ends as
/// the browser clamps `scrollLeft`.
struct CategoryTabStrip: View {
    @Bindable var model: DevelopPanelModel

    @State private var viewport: CGRect = .zero
    @State private var tabWidths: [String: CGFloat] = [:]

    /// The prototype's target for the selected tab, in points from the screen edge.
    static let selectedTabScreenX: CGFloat = 120

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(model.categoryItems) { item in
                        CategoryTab(model: model, item: item)
                            .id(item.id)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: TabWidths.self, value: [item.id: proxy.size.width])
                            })
                    }
                }
                // 18 pt: the first tab starts past the 16 pt fade of the mask, so Favourites is not half hidden beside
                // Auto (owner feedback 2026-10-05); the fade still hints that the row scrolls.
                .padding(.leading, 18).padding(.trailing, 18)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: Viewport.self, value: proxy.frame(in: .global))
            })
            .mask(LinearGradient(stops: maskStops, startPoint: .leading, endPoint: .trailing))
            .onPreferenceChange(TabWidths.self) { tabWidths = $0; position(reader) }
            .onPreferenceChange(Viewport.self) { viewport = $0; position(reader) }
            .onChange(of: model.currentCategoryID) { position(reader) }
            .onChange(of: model.session.history.count) { position(reader) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Categories"))
    }

    /// `mask-image: linear-gradient(90deg, transparent 0, #000 16px, #000 calc(100% - 24px), transparent)`.
    private var maskStops: [Gradient.Stop] {
        let width = max(viewport.width, 1)
        return [.init(color: .clear, location: 0), .init(color: .black, location: min(16 / width, 0.5)),
                .init(color: .black, location: max(1 - 24 / width, 0.5)), .init(color: .clear, location: 1)]
    }

    /// Scrolls so the selected tab's leading edge sits 120 pt from the screen edge: with
    /// `scrollTo(anchor: x)`, the point at fraction x of the tab meets fraction x of the viewport,
    /// so x = target / (viewport width − tab width).
    private func position(_ reader: ScrollViewProxy) {
        let id = model.currentCategoryID
        guard let width = tabWidths[id], viewport.width > width else { return }
        let target = Self.selectedTabScreenX - viewport.minX
        let fraction = min(max(target / (viewport.width - width), 0), 1)
        reader.scrollTo(id, anchor: UnitPoint(x: fraction, y: 0.5))
    }

    private struct TabWidths: PreferenceKey {
        static let defaultValue: [String: CGFloat] = [:]
        static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
            value.merge(nextValue()) { $1 }
        }
    }

    private struct Viewport: PreferenceKey {
        static let defaultValue: CGRect = .zero
        // Subtrees without the preference report `.zero`; keep the measured frame.
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
            let next = nextValue()
            if next != .zero { value = next }
        }
    }
}
