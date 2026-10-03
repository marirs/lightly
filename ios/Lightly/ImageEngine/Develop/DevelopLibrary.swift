import Foundation
import Observation
import OSLog

/// Everything Develop renders with: the model constants, the preset pack, the bake cache and the
/// frame renderer. Loaded once per launch, off the main actor (the manifest is 6.5 MB), and shared
/// by every editing session.
@MainActor
@Observable
final class DevelopLibrary {

    enum State: Equatable {
        case loading
        case ready
        /// No presets can be offered; the reason is logged. Develop still opens (Original only).
        case unavailable(String)
    }

    private(set) var state: State = .loading
    private(set) var pack: PresetPack = .empty
    @ObservationIgnored private(set) var cache: DevelopLUTCache?
    @ObservationIgnored private(set) var renderer: DevelopFrameRenderer?
    /// Manifest read + index time (performance evidence; target ≤ 300 ms).
    private(set) var parseDuration: Duration?

    private static let logger = Logger(subsystem: "com.lightlylabs.lightly", category: "DevelopLibrary")

    init() {}

    /// A library that is ready at once (tests, previews).
    init(pack: PresetPack, model: DevelopModel, lutApplier: (any DevelopLUTApplying)?) {
        self.pack = pack
        self.cache = DevelopLUTCache(model: model)
        self.renderer = lutApplier.map { DevelopFrameRenderer(lutApplier: $0, model: model) }
        self.state = lutApplier == nil ? .unavailable("no renderer") : .ready
    }

    /// Loads the bundled contract and pack in the background.
    func loadBundled(lutApplier: (any DevelopLUTApplying)?) async {
        let outcome = await Task.detached(priority: .userInitiated) { () -> (DevelopModel?, PresetPackLoadResult?, String?) in
            do {
                let model = try DevelopModel.loadBundled()
                return (model, PresetPackLoader.loadBundled(model: model), nil)
            } catch {
                return (nil, nil, "Develop model unavailable: \(error)")
            }
        }.value
        guard let model = outcome.0, let result = outcome.1 else {
            state = .unavailable(outcome.2 ?? "unknown")
            Self.logger.error("\(outcome.2 ?? "unknown", privacy: .public)")
            return
        }
        pack = result.pack
        parseDuration = result.parseDuration
        cache = DevelopLUTCache(model: model)
        renderer = lutApplier.map { DevelopFrameRenderer(lutApplier: $0, model: model) }
        if let problem = result.problem {
            state = .unavailable(problem.explanation)
        } else if renderer == nil {
            state = .unavailable("Metal is unavailable")
        } else {
            state = .ready
        }
    }

    /// Waits until loading has finished.
    func waitUntilLoaded() async {
        while state == .loading { try? await Task.sleep(for: .milliseconds(20)) }
    }
}
