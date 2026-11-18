import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Edit › Enhance results (rendering-v2 §7.6), stored by the SHA-256 of their PNG bytes: the recipe's
/// `edit.enhance.result` is a `derivedRef` to one of them. PNG because the result is the source of every later stage and
/// of the saved copy, so it must come back bit for bit.
final class EnhanceResultStore: @unchecked Sendable {
    // @unchecked: every access to `memory` holds `lock`; file writes are atomic renames.
    private let lock = NSLock()
    /// Results of this launch by digest, as PNG bytes (tests, or a directory that could not be written).
    private var memory: [String: Data] = [:]
    private let directory: URL?

    init(directory: URL? = nil) { self.directory = directory }

    /// The app's store: Application Support/EnhanceResults (beside RemovePatches).
    static func applicationSupport() -> EnhanceResultStore {
        #if DEBUG
        // `--keep-stored-session` (device checks): the stored session's results are left untouched, as Remove's patches.
        if ProcessInfo.processInfo.arguments.contains("--keep-stored-session") { return EnhanceResultStore(directory: nil) }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return EnhanceResultStore(directory: base?.appendingPathComponent("EnhanceResults\(DebugSessionStoreName.suffix)", isDirectory: true))
    }

    enum Failure: Error { case encodeFailed }

    /// Stores `image` and returns its digest. Throws only when the image cannot be encoded; a failed write keeps the
    /// result for this launch (after a kill the edit renders without it, never re-enhanced silently).
    func add(_ image: CGImage) throws -> String {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw Failure.encodeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodeFailed }
        let bytes = data as Data
        let digest = Self.digest(of: bytes)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Derived results, re-made from the edit: kept out of iCloud and device backup, like Remove's patches.
            var folder = directory, file = fileURL(digest, in: directory)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            do {
                try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try? file.setResourceValues(values)
                return digest
            } catch {
                DiagnosticTrace.note("enhance: result not written (\(error.localizedDescription)); kept for this launch")
            }
        }
        lock.withLock { memory[digest] = bytes }
        return digest
    }

    /// The stored result, or nil when it is unknown, missing or corrupt (its bytes no longer match the digest).
    func image(_ digest: String) -> CGImage? {
        let bytes = lock.withLock { memory[digest] } ?? directory.flatMap { try? Data(contentsOf: fileURL(digest, in: $0)) }
        guard let bytes, Self.digest(of: bytes) == digest,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Choosing a new photo: the previous edit's results are deleted, in memory and on disk.
    func removeAll() {
        lock.withLock { memory.removeAll() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func fileURL(_ digest: String, in directory: URL) -> URL {
        // Digests are hex; anything else never names a file.
        let safe = digest.allSatisfy { "0123456789abcdef".contains($0) } ? digest : "invalid"
        return directory.appendingPathComponent("\(safe).png")
    }

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `image` drawn at exactly `width` x `height` (the original's preview size, so preview-resolution mattes and
    /// masks line up; rendering-v2 §7.6), with the same high-quality downscale as the original's preview.
    static func resampled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        if image.width == width && image.height == height { return image }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: ColorPipeline.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// An Enhance result at the preview's size, as the RGBA8 pixels a preview render starts from (EditorSession).
struct EnhancedBase: Sendable {
    let pixels: [UInt8]
    let width: Int
    let height: Int

    static func make(_ image: CGImage, width: Int, height: Int) -> EnhancedBase? {
        guard let small = EnhanceResultStore.resampled(image, width: width, height: height),
              let pixels = try? MetalLUTRenderer.rgba8Bytes(of: small) else { return nil }
        return EnhancedBase(pixels: pixels, width: width, height: height)
    }
}

/// A finished Enhance run, before it becomes one undo step.
struct EnhanceOutcome: Sendable {
    let digest: String
    let width: Int
    let height: Int
    let painting: Bool
    let base: EnhancedBase
}

/// Hands the engine's progress to the main actor at most once per whole percent, so a photo's ~150 tiles do not
/// each schedule a panel update.
final class EnhanceProgressRelay: @unchecked Sendable {
    // @unchecked: `lastPercent` is only touched by the one engine run that owns this relay.
    private let deliver: @Sendable (Double) -> Void
    private var lastPercent = -1

    init(_ deliver: @escaping @Sendable (Double) -> Void) { self.deliver = deliver }

    func report(_ fraction: Double) {
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        guard percent > lastPercent else { return }
        lastPercent = percent
        deliver(Double(percent) / 100)
    }
}
