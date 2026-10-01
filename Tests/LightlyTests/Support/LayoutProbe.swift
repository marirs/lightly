import SwiftUI
import UIKit
@testable import Lightly

/// Hosts a SwiftUI view in a window at a given size and Dynamic Type size,
/// and collects the frames its views publish with `.layoutAnchor(_:)`.
///
/// Geometry rather than pixels: overlap and reachability are layout facts,
/// and asserting them directly fails with a precise message instead of a
/// percentage of differing pixels.
@MainActor
final class LayoutProbe {

    private(set) var frames: [String: CGRect] = [:]
    private let window: UIWindow

    init(_ view: some View, size: CGSize, dynamicTypeSize: DynamicTypeSize) {
        window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let collector = FrameCollector()
        let controller = UIHostingController(rootView: AnyView(
            view
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .environment(\.locale, Locale(identifier: "en_US"))
                .onPreferenceChange(LayoutAnchorKey.self) { frames in
                    MainActor.assumeIsolated { collector.frames = frames }
                }
        ))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        // Preferences are delivered after layout, on the next run-loop turn.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        frames = collector.frames
    }

    func frame(_ name: String) -> CGRect? { frames[name] }

    func tearDown() { window.isHidden = true }
}

@MainActor
private final class FrameCollector {
    var frames: [String: CGRect] = [:]
}
