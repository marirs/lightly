import CoreGraphics
import ImageIO
import XCTest
@testable import Lightly

/// Enhance engine (1.3): the tile layout, mirrored reads and detection scale exactly as the Mac copy
/// (experiments/enhance-2026-11-12/phone_pipeline.py), and one whole photo against the Mac copy's output.
final class EnhanceEngineTests: XCTestCase {

    // MARK: - Geometry

    func testTileWindowsCoverEveryPixelOnceWithContext() {
        for size in [1, 100, 383, 384, 385, 800, 1200, 1676, 4032] {
            let windows = EnhanceMaths.tileWindows(size, EnhanceEngine.tile, EnhanceEngine.tilePad)
            var next = 0
            for (kept, length, start) in windows {
                XCTAssertEqual(kept, next, "size \(size): kept ranges must be contiguous")
                XCTAssertGreaterThan(length, 0)
                next = kept + length
                if size > EnhanceEngine.tile {
                    XCTAssertGreaterThanOrEqual(start, 0)
                    XCTAssertLessThanOrEqual(start + EnhanceEngine.tile, size, "size \(size): window inside the photo")
                    // Every kept pixel has >= 16 px of context on its inner sides (README step 2e).
                    if kept > 0 { XCTAssertGreaterThanOrEqual(kept - start, EnhanceEngine.tilePad) }
                    if next < size { XCTAssertGreaterThanOrEqual(start + EnhanceEngine.tile - next, EnhanceEngine.tilePad) }
                } else {
                    XCTAssertEqual(windows.count, 1)
                    XCTAssertEqual(start, 0)
                }
            }
            XCTAssertEqual(next, size)
        }
    }

    /// Python's tile_windows for 1200 and 1676 px (phone_pipeline.tile_windows, printed 2026-11-17).
    func testTileWindowsMatchTheMacCopy() {
        XCTAssertEqual(EnhanceMaths.tileWindows(1200, 384, 16).map { [$0.0, $0.1, $0.2] },
                       [[0, 328, 0], [328, 272, 272], [600, 272, 544], [872, 328, 816]])
        XCTAssertEqual(EnhanceMaths.tileWindows(1676, 384, 16).map { [$0.0, $0.1, $0.2] },
                       [[0, 353, 0], [353, 323, 323], [676, 323, 646], [999, 323, 969], [1322, 354, 1292]])
    }

    func testMirrorIndexReflectsWithoutRepeatingTheEdge() {
        XCTAssertEqual((0..<12).map { EnhanceMaths.mirrorIndex($0, 4) }, [0, 1, 2, 3, 2, 1, 0, 1, 2, 3, 2, 1])
        XCTAssertEqual((0..<3).map { EnhanceMaths.mirrorIndex($0, 1) }, [0, 0, 0])
        XCTAssertEqual((0..<500).map { EnhanceMaths.mirrorIndex($0, 500) }, Array(0..<500), "identity inside the photo")
    }

    func testDetectionScaleKeepsFittingPhotosAndFitsLongOnes() {
        XCTAssertEqual(EnhanceEngine.detectionScale(width: 1200, height: 1676, short: 640, canvas: 1024), 640.0 / 1200)
        XCTAssertEqual(EnhanceEngine.detectionScale(width: 3000, height: 1000, short: 640, canvas: 1024), 1024.0 / 3000)
        XCTAssertEqual(EnhanceEngine.detectionScale(width: 1000, height: 3000, short: 960, canvas: 1536), 1536.0 / 3000)
    }

    // MARK: - A whole photo

    /// A 480 x 400 crop of eTOiqGqdCf8 (two faces, one the child of step 2f's ring) through the bundled models against
    /// the Mac copy's output (experiments/enhance-2026-11-12/engine_check.py). Both are git-ignored experiment outputs,
    /// so the test skips without them. On a phone they are read from the host app's Documents/engine-check instead
    /// (copied there with devicectl), and the result is written beside them as output.png; the models
    /// are bundled in Debug builds only (Tools/bundle_enhance_models.sh). Tolerances: Core ML here runs other kernels
    /// than PyTorch/LiteRT on the Mac (step 2c measured iPhone vs Mac faces at a median 1-2 of 255).
    func testWholePhotoAgreesWithTheMacCopy() throws {
        let experiment = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("experiments/enhance-2026-11-12/outputs")
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let onHost = FileManager.default.fileExists(atPath: experiment.appendingPathComponent("engine-check/input.png").path)
        let folder = onHost ? experiment.appendingPathComponent("engine-check") : documents.appendingPathComponent("engine-check")
        let input = folder.appendingPathComponent("input.png"), reference = folder.appendingPathComponent("mac.png")
        guard FileManager.default.fileExists(atPath: input.path), FileManager.default.fileExists(atPath: reference.path) else {
            throw XCTSkip("no engine-check fixture (experiments/enhance-2026-11-12/engine_check.py)")
        }
        let bundle = Bundle(for: EnhanceEngine.self)
        guard EnhanceEngine.isAvailable(in: bundle) else { throw XCTSkip("Enhance models not bundled in this build") }
        let engine = try EnhanceEngine(bundle: bundle)

        let start = CFAbsoluteTimeGetCurrent()
        let result = try engine.enhance(try Self.load(input))
        print(String(format: "ENHANCE-ENGINE enhanced in %.2f s", CFAbsoluteTimeGetCurrent() - start))
        XCTAssertFalse(result.isPainting)
        XCTAssertEqual(result.faces.count, 2)
        XCTAssertTrue(result.faces.allSatisfy(\.restored))
        print("ENHANCE-ENGINE faces \(result.faces.map { "\(Int($0.eyeGap)) px \($0.pointSource.map { "\($0)" } ?? "-")" })")
        // Kept beside the reference for a look (git-ignored): this run's result.
        if let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(onHost ? "ios-test.png" : "output.png") as CFURL,
                                                             "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, result.image, nil)
            CGImageDestinationFinalize(destination)
        }
        let expected = EnhanceEngine.floatRGB(try Self.load(reference))
        let actual = EnhanceEngine.floatRGB(result.image)
        XCTAssertEqual(actual.w, expected.w)
        XCTAssertEqual(actual.h, expected.h)
        var total = 0.0
        for i in 0..<actual.d.count { total += Double(abs(actual.d[i] - expected.d[i])) }
        let mean = total / Double(actual.d.count)
        print("ENHANCE-ENGINE engine-check mean difference vs Mac \(mean)")
        XCTAssertLessThan(mean, 1.5, "whole-image mean difference from the Mac copy (0-255)")
    }

    func testCancellationStopsTheRun() throws {
        let bundle = Bundle(for: EnhanceEngine.self)
        guard EnhanceEngine.isAvailable(in: bundle) else { throw XCTSkip("Enhance models not bundled in this build") }
        let engine = try EnhanceEngine(bundle: bundle)
        let photo = EnhanceEngine.cgImage(EnhanceMaths.Image(w: 400, h: 300, c: 3, d: [Float](repeating: 128, count: 400 * 300 * 3)))
        XCTAssertThrowsError(try engine.enhance(photo, isCancelled: { true })) { error in
            XCTAssertEqual(error as? EnhanceEngine.Failure, .cancelled)
        }
    }

    func testSmallPhotoGivesTwiceItsSize() throws {
        let bundle = Bundle(for: EnhanceEngine.self)
        guard EnhanceEngine.isAvailable(in: bundle) else { throw XCTSkip("Enhance models not bundled in this build") }
        let engine = try EnhanceEngine(bundle: bundle)
        let photo = EnhanceEngine.cgImage(EnhanceMaths.Image(w: 150, h: 100, c: 3, d: [Float](repeating: 90, count: 150 * 100 * 3)))
        let result = try engine.enhance(photo)
        XCTAssertEqual(result.image.width, 300)
        XCTAssertEqual(result.image.height, 200)
        XCTAssertTrue(result.faces.isEmpty)
    }

    private static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw NSError(domain: "cannot read \(url.path)", code: 1) }
        return image
    }
}
