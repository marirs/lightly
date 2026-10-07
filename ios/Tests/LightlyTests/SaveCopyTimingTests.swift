import XCTest
@testable import Lightly

/// Save copy stage times on real photos (2026-10-07): the real save path, the bundled Look pack and a Look with spatial
/// operators (Landscape · Hiking 5). Runs only when the runner sets LIGHTLY_SAVE_TIMING (xcodebuild:
/// TEST_RUNNER_LIGHTLY_SAVE_TIMING=13,48), so the normal suite never pays for it; build it in Debug and in Release
/// optimisation to compare equal configurations. Results are printed as "SAVE TIMING …" lines.
@MainActor
final class SaveCopyTimingTests: XCTestCase {
    private static let fixtures: [String: String] = [
        "1.7": "docs/ui/assets/photos/landscape_02.jpg",
        "13": "experiments/depth/out/portrait-edges-2026-10-05/iosbg/pd03_full.jpg",
        "48": "experiments/auto/data/pd12m/eval_originals/c8954609f02a4f76ddfa575d71823e59.jpg",
    ]

    func testSaveCopyStageTimes() async throws {
        guard let wanted = ProcessInfo.processInfo.environment["LIGHTLY_SAVE_TIMING"] else { throw XCTSkip("set LIGHTLY_SAVE_TIMING") }
        let library = DevelopLibrary()
        await library.loadBundled(lutApplier: try MetalLUTRenderer())
        let presetID = try XCTUnwrap(DevelopPresetCatalogue.loadBundled().preset(inCategory: "landscape", atStop: 37)?.id)
        let preset = try XCTUnwrap(library.pack.preset(id: presetID))
        for size in wanted.split(separator: ",").map(String.init) {
            let path = "\(EditorCaptureUITestsPaths.repositoryRoot)/\(try XCTUnwrap(Self.fixtures[size]))"
            let photo = try await ImageIOPhotoLoader().loadPhoto(from: try Data(contentsOf: URL(fileURLWithPath: path)), source: .photoLibrary)
            let writer = SpyLibraryWriter()
            let session = try await EditorTestSupport.readySession(photo: photo, library: library, writer: writer)
            session.applyLook(preset)
            await session.settleRendering()
            let before = SaveTiming.currentFootprintMB() ?? -1
            let sampler = DebugFootprintSampler()
            let start = Date()
            session.saveCopy()
            await EditorTestSupport.waitForSave(session, timeout: 3_000)
            let peak = sampler.stop()
            guard case .saved = session.saveState else { return XCTFail("\(size) MP: \(session.saveState)") }
            print("SAVE TIMING \(size) MP total=\(Int(Date().timeIntervalSince(start) * 1000))ms \(SaveTiming.lastReport ?? "-")")
            // The save's own memory: footprint before it, and its peak sampled every 10 ms (the process peak includes the
            // test's loading of the photo).
            print("SAVE MEMORY \(size) MP before=\(before)MB savePeak=\(peak)MB added=\(peak - before)MB")
        }
    }
}

/// The repository root, as the UI tests find it (this file's location).
enum EditorCaptureUITestsPaths {
    static var repositoryRoot: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    }
}
