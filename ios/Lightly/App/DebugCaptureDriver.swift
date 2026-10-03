#if DEBUG
import CoreGraphics
import Foundation
import QuartzCore
import UIKit

/// The DEBUG launch arguments, replaceable while the app runs.
///
/// Design captures step through every screen of a cell in one launch (`DebugCaptureDriver`):
/// each screen brings its own `--scenario`, `--hold-phase`, writer and Auto flags, so every
/// DEBUG reader asks here instead of `CommandLine.arguments`. Until a driver command arrives this
/// is exactly the process's launch arguments. Nothing here exists in release builds.
enum DebugArguments {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var override: [String]?

    static var current: [String] {
        lock.withLock { override ?? CommandLine.arguments }
    }

    static func replace(with arguments: [String]) {
        lock.withLock { override = arguments }
    }
}

/// Timestamps for measuring capture batches (`--capture-timing <file>`): one line per event,
/// `<unix ms> app <event> <screen id>`, appended to the file. The UI test writes its own events
/// to a sibling file with the same clock (the Simulator shares the host's).
enum DebugCaptureTiming {
    private static let lock = NSLock()

    static func mark(_ event: String, screen: String? = nil) {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--capture-timing"), arguments.indices.contains(flag + 1) else { return }
        let screenID = screen ?? DebugScenario.current?.screenID ?? "-"
        let line = "\(Int64(Date().timeIntervalSince1970 * 1000)) app \(event) \(screenID)\n"
        lock.withLock {
            let url = URL(fileURLWithPath: arguments[flag + 1])
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// Runs a capture session in one launch (`--capture-commands <file>`): the UI test writes one
/// command line per screen, `<sequence>\t<argument>\t<argument>…`, holding that screen's launch
/// arguments; the driver applies them, returns to Welcome and opens the screen's photo through
/// the normal open path, then writes `<sequence>` to `<file>.ack`. The editor then applies the
/// scenario exactly as it does after a fresh launch.
@MainActor
enum DebugCaptureDriver {

    /// True for a capture session. Animations are then off (UIKit and SwiftUI): every screen is
    /// photographed in its final state, never mid-transition. The spinner therefore stands still.
    nonisolated static var isActive: Bool { CommandLine.arguments.contains("--capture-commands") }

    /// Lets the frame the screen just committed reach the display: two main-queue turns, each
    /// flushing Core Animation, after the render and the scenario have finished.
    static func awaitScreenCommit() async {
        await awaitDisplayFrames(3)
    }

    /// Waits for `count` display refreshes (CADisplayLink), so a render pass SwiftUI has already
    /// committed reaches the screen. Main-queue turns alone were not enough: a tool switch made
    /// just before was sometimes not on the display 60 ms later (measured in the slice-3 run).
    static func awaitDisplayFrames(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ticker = DisplayFrameTicker(remaining: count) { continuation.resume() }
            ticker.start()
        }
    }

    static func runIfRequested(appState: AppState) async {
        let launch = CommandLine.arguments
        guard let flag = launch.firstIndex(of: "--capture-commands"), launch.indices.contains(flag + 1) else { return }
        let commandFile = URL(fileURLWithPath: launch[flag + 1])
        let acknowledgement = commandFile.appendingPathExtension("ack")
        readyFile = commandFile.appendingPathExtension("ready")
        UIView.setAnimationsEnabled(false)
        var lastSequence: String?
        while !Task.isCancelled {
            if let line = try? String(contentsOf: commandFile, encoding: .utf8)
                .trimmingCharacters(in: .newlines), !line.isEmpty {
                let fields = line.components(separatedBy: "\t")
                if let sequence = fields.first, sequence != lastSequence {
                    lastSequence = sequence
                    DebugCaptureTiming.mark("command", screen: fields.count > 5 ? fields[5] : nil)
                    await apply(sequence: sequence, arguments: Array(fields.dropFirst()), launch: launch, appState: appState)
                    try? Data(sequence.utf8).write(to: acknowledgement, options: .atomic)
                }
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// The sequence of the command being shown; the editor marks it ready (`capture.ready.<n>`).
    private(set) static var sequence: String?
    /// `<command file>.ready`: the editor writes the sequence here once the screen is ready.
    /// The test polls this file instead of querying the accessibility tree, which XCTest only
    /// refreshes about once a second (measured: 1.5 s per screen of pure detection delay).
    private(set) static var readyFile: URL?

    static func reportReady(_ sequence: String) {
        guard let readyFile else { return }
        try? Data(sequence.utf8).write(to: readyFile, options: .atomic)
    }

    private static func apply(sequence: String, arguments: [String], launch: [String], appState: AppState) async {
        await appState.debugResetForNextScreen(resetPreferences: arguments.contains("--reset-preferences"))
        DebugCaptureTiming.mark("reset", screen: "-")
        // Set only once the previous screen is gone, so nothing of it can claim this sequence.
        Self.sequence = sequence
        DebugArguments.replace(with: [launch.first ?? "Lightly"] + arguments)
        if let flag = arguments.firstIndex(of: "--open-photo"), arguments.indices.contains(flag + 1) {
            let url = URL(fileURLWithPath: arguments[flag + 1])
            await appState.openPhoto(source: .photoLibrary) { try Data(contentsOf: url) }
        }
        DebugCaptureTiming.mark("opened")
    }
}

/// Picks the DEBUG library writer from the current arguments at each save, so a capture session
/// can hold "Saving a copy…" for one screen and finish quickly for the next.
struct DebugArgumentsLibraryWriter: PhotoLibraryWriting {
    let fallback: any PhotoLibraryWriting

    func save(_ data: Data, fileExtension: String) async throws {
        let arguments = DebugArguments.current
        if arguments.contains("--fake-library-writer") {
            return try await DebugInertLibraryWriter(delay: .milliseconds(600)).save(data, fileExtension: fileExtension)
        }
        if arguments.contains("--slow-library-writer") {
            return try await DebugInertLibraryWriter(delay: .seconds(600)).save(data, fileExtension: fileExtension)
        }
        try await fallback.save(data, fileExtension: fileExtension)
    }
}

/// Picks the DEBUG Auto behaviour from the current arguments at each run (`--auto-fails`,
/// `--auto-delay-seconds <s>`).
struct DebugArgumentsAutoEnhancer: AutoEnhancing {
    let fallback: any AutoEnhancing

    func autoLUT(forAnalysisProxy proxy: CGImage) async -> AutoResult {
        let arguments = DebugArguments.current
        if arguments.contains("--auto-fails") {
            return await DebugFailingAutoEnhancer().autoLUT(forAnalysisProxy: proxy)
        }
        if let flag = arguments.firstIndex(of: "--auto-delay-seconds"),
           arguments.indices.contains(flag + 1), let seconds = Double(arguments[flag + 1]) {
            return await DelayedAutoEnhancer(wrapped: fallback, delay: .seconds(seconds)).autoLUT(forAnalysisProxy: proxy)
        }
        return await fallback.autoLUT(forAnalysisProxy: proxy)
    }
}
#endif

#if DEBUG
/// Counts display refreshes for DebugCaptureDriver, then calls back once.
@MainActor
private final class DisplayFrameTicker: NSObject {
    private var remaining: Int
    private let done: () -> Void
    private var link: CADisplayLink?
    private var keepAlive: DisplayFrameTicker?

    init(remaining: Int, done: @escaping () -> Void) {
        self.remaining = remaining
        self.done = done
    }

    func start() {
        keepAlive = self
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        remaining -= 1
        guard remaining <= 0 else { return }
        link?.invalidate()
        link = nil
        done()
        keepAlive = nil
    }
}
#endif
