import CoreGraphics
import Foundation
import ImageIO
import OSLog

/// Stage log for Save copy and subject separation (sizes, timings and outcomes only, never photo content). DEBUG
/// builds also append each line to Documents/save-trace.log, so a physical-device run can be diagnosed when the system
/// log is not reachable (a phone connected over the network only); the file name is kept so earlier runs stay readable.
enum DiagnosticTrace {
    static let logger = Logger(subsystem: "com.lightlylabs.lightly", category: "Diagnostics")

    static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        #if DEBUG
        appendToDocuments(message)
        #endif
    }

    #if DEBUG
    /// DEBUG builds: a file the device check needs (Documents/evidence/<name>), retrieved with devicectl
    /// (scripts/iphone_evidence.sh). Mattes and saved copies only; nothing leaves the phone by itself.
    static func evidence(_ data: Data, named name: String) {
        let directory = URL.documentsDirectory.appending(path: "evidence", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = URL(fileURLWithPath: name).lastPathComponent
        try? data.write(to: directory.appending(path: safe), options: .atomic)
        note("evidence: \(safe) \(data.count) bytes")
    }

    /// An 8-bit grey PNG of a matte in [0, 1].
    static func evidence(matte: FloatImage, named name: String) {
        var bytes = matte.data.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        guard let context = CGContext(data: &bytes, width: matte.width, height: matte.height, bitsPerComponent: 8, bytesPerRow: matte.width,
                                      space: CGColorSpace(name: CGColorSpace.linearGray)!, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let image = context.makeImage() else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        evidence(data as Data, named: name)
    }

    static var stamp: String {
        let f = DateFormatter(); f.dateFormat = "HHmmss"; return f.string(from: Date())
    }

    private static let lock = NSLock()

    private static func appendToDocuments(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = URL.documentsDirectory.appending(path: "save-trace.log")
        lock.withLock {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
    #endif
}
