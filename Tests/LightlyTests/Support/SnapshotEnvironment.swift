import Foundation

/// The simulator device and runtime the snapshot references were verified
/// on, stored as `__Snapshots__/ENVIRONMENT.json` beside the references.
///
/// A sidecar rather than a constant so that re-recording on a new runtime is
/// one deliberate edit next to the images it describes.
struct SnapshotEnvironment: Codable, Equatable {
    let deviceName: String
    let runtimeVersion: String
    let runtimeBuild: String

    static let fileName = "ENVIRONMENT.json"

    /// The environment this test process is running in, from the variables
    /// the simulator sets for every process it launches.
    static var current: SnapshotEnvironment {
        let environment = ProcessInfo.processInfo.environment
        return SnapshotEnvironment(
            deviceName: environment["SIMULATOR_DEVICE_NAME"] ?? "not a simulator",
            runtimeVersion: environment["SIMULATOR_RUNTIME_VERSION"] ?? "unknown",
            runtimeBuild: environment["SIMULATOR_RUNTIME_BUILD_VERSION"] ?? "unknown"
        )
    }

    var summary: String { "\(deviceName), iOS \(runtimeVersion) (\(runtimeBuild))" }

    /// Describes why snapshots cannot be compared here, or nil when they can.
    static func mismatch(referenceDirectory: URL) -> String? {
        let url = referenceDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let pinned = try? JSONDecoder().decode(SnapshotEnvironment.self, from: data) else {
            return "missing or unreadable \(fileName) in \(referenceDirectory.lastPathComponent)."
        }
        let running = current
        guard running != pinned else { return nil }
        return """
        references were recorded on \(pinned.summary) but this run is on \(running.summary). \
        Run on the pinned simulator, or re-record deliberately and update \(fileName).
        """
    }
}
