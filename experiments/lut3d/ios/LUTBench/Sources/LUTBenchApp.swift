import SwiftUI
import UIKit

/// Minimal UI: a status line plus a "done" label. With `--run-bench` the benchmark starts on launch.
@main
struct LUTBenchApp: App {
    @StateObject private var benchStatus = BenchStatus()

    var body: some Scene {
        WindowGroup {
            BenchStatusView(status: benchStatus)
                .onAppear { startIfRequestedByLaunchArguments() }
        }
    }

    private func startIfRequestedByLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--run-bench") else { return }
        benchStatus.startBenchmark(runIdentifier: Self.runIdentifier(from: arguments))
    }

    /// run_ios.sh passes `--run-id <token>` so it can tell this run's `done` marker from a stale one.
    static func runIdentifier(from arguments: [String]) -> String {
        if let flagIndex = arguments.firstIndex(of: "--run-id"), flagIndex + 1 < arguments.count {
            return arguments[flagIndex + 1]
        }
        return "manual-\(Int(Date().timeIntervalSince1970))"
    }
}

final class BenchStatus: ObservableObject {
    @Published var statusLine = "idle (launch with --run-bench, or tap Run)"
    @Published var isDone = false
    @Published var isRunning = false

    func startBenchmark(runIdentifier: String) {
        guard !isRunning else { return }
        isRunning = true
        // Keep the screen awake: if the device auto-locks mid-run the app is suspended and timings are garbage.
        UIApplication.shared.isIdleTimerDisabled = true
        let runner = BenchRunner(runIdentifier: runIdentifier) { [weak self] message in
            DispatchQueue.main.async { self?.statusLine = message }
        }
        Task.detached(priority: .userInitiated) {
            await runner.run()
            await MainActor.run {
                self.isDone = true
                self.isRunning = false
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}

struct BenchStatusView: View {
    @ObservedObject var status: BenchStatus

    var body: some View {
        VStack(spacing: 16) {
            Text("LUTBench").font(.title)
            Text(status.statusLine)
                .font(.system(.footnote, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if status.isDone {
                Text("done").font(.largeTitle).bold().accessibilityIdentifier("done")
            } else if !status.isRunning {
                Button("Run") { status.startBenchmark(runIdentifier: LUTBenchApp.runIdentifier(from: [])) }
            } else {
                ProgressView()
            }
        }
        .padding()
    }
}
