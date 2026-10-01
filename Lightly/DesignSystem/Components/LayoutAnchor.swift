import SwiftUI

/// Publishes a view's frame under a stable name.
///
/// Why this exists: layout tests must assert geometry (no overlap at large
/// Dynamic Type sizes, actions reachable), and SwiftUI does not expose its
/// accessibility tree to a unit-test host. Frames travel through a
/// preference that nothing in the app reads, so the cost is one geometry
/// read per anchored view.
struct LayoutAnchorKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, newer in newer }
    }
}

extension View {
    /// Reports this view's global frame as `name` (see `LayoutAnchorKey`).
    func layoutAnchor(_ name: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: LayoutAnchorKey.self, value: [name: proxy.frame(in: .global)])
            }
        )
    }
}
