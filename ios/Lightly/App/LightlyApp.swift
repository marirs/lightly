import SwiftUI

@main
struct LightlyApp: App {
    /// Root state, built from the composition root.
    @State private var appState: AppState

    init() {
        // `DependencyContainer` is main-actor isolated, as is `AppState`;
        // `App.init` runs on the main actor, so this is safe without hopping.
        _appState = State(initialValue: DependencyContainer.live().makeAppState())
        // A marker per launch: proves the trace file is written and names the build that wrote it.
        let version = AppVersion()
        DiagnosticTrace.note("launch: Lightly \(version.version) (\(version.build))")
        KeepAwake.start()
        #if DEBUG
        DebugLifecycleTrace.start()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
    }
}
