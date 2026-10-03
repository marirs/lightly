import SwiftUI

/// The phone's single row of category tabs (`.devhead .tabs`): scrolls sideways, fades at both
/// ends, and after every change brings the selected tab to 120 pt from the screen's leading edge
/// when the row overflows (prototype `buildRulers`: `scrollLeft = on.offsetLeft - 120`).
///
/// Drawn as an offset row rather than a `ScrollView` so that exact offset can be set.
struct CategoryTabStrip: View {
    @Bindable var model: DevelopPanelModel

    @State private var offset: CGFloat = 0
    @State private var dragStartOffset: CGFloat?
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var viewportMinX: CGFloat = 0
    @State private var selectedTabMinX: CGFloat = 0

    /// The prototype's target for the selected tab, in points from the screen edge.
    static let selectedTabScreenX: CGFloat = 120

    var body: some View {
        let panel = DevelopPanelView(model: model, style: .tabs)
        // The row sits in an overlay so its full (ideal) width never widens the panel: only the
        // strip's own frame takes part in layout.
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 44)
            .overlay(alignment: .leading) {
                HStack(spacing: 20) {
                    ForEach(model.categoryItems) { item in
                        panel.categoryTab(item)
                            .background {
                                if item.id == model.currentCategoryID {
                                    GeometryReader { proxy in
                                        Color.clear.preference(key: SelectedTabX.self, value: proxy.frame(in: .named("tabStrip")).minX)
                                    }
                                }
                            }
                    }
                }
                .padding(.leading, 14).padding(.trailing, 18)
                .fixedSize()
                .coordinateSpace(name: "tabStrip")
                .background(GeometryReader { proxy in Color.clear.preference(key: ContentWidth.self, value: proxy.size.width) })
                .offset(x: -offset)
            }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: Viewport.self, value: proxy.frame(in: .global))
        })
        .clipped()
        .mask(LinearGradient(stops: maskStops, startPoint: .leading, endPoint: .trailing))
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 8)
            .onChanged { value in
                let start = dragStartOffset ?? offset
                dragStartOffset = start
                offset = clamp(start - value.translation.width)
            }
            .onEnded { value in
                let start = dragStartOffset ?? offset
                dragStartOffset = nil
                withAnimation(.easeOut(duration: 0.35)) { offset = clamp(start - value.predictedEndTranslation.width) }
            })
        .onPreferenceChange(ContentWidth.self) { contentWidth = $0; reposition() }
        .onPreferenceChange(Viewport.self) { viewportWidth = $0.width; viewportMinX = $0.minX; reposition() }
        .onPreferenceChange(SelectedTabX.self) { selectedTabMinX = $0; reposition() }
        .onChange(of: model.currentCategoryID) { reposition() }
        .onChange(of: model.session.history.count) { reposition() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Categories"))
    }

    /// `mask-image: linear-gradient(90deg, transparent 0, #000 16px, #000 calc(100% - 24px), transparent)`.
    private var maskStops: [Gradient.Stop] {
        let width = max(viewportWidth, 1)
        return [.init(color: .clear, location: 0), .init(color: .black, location: min(16 / width, 0.5)),
                .init(color: .black, location: max(1 - 24 / width, 0.5)), .init(color: .clear, location: 1)]
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), max(contentWidth - viewportWidth, 0))
    }

    private func reposition() {
        guard dragStartOffset == nil, contentWidth > viewportWidth else { offset = 0; return }
        // The selected tab's screen x with the row unscrolled.
        let screenX = viewportMinX + selectedTabMinX
        offset = clamp(screenX - Self.selectedTabScreenX)
    }

    private struct ContentWidth: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private struct SelectedTabX: PreferenceKey {
        static let defaultValue: CGFloat = 0
        // Siblings without the preference report the default (0): keep the one real value.
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
