import Foundation
import OSLog

/// Save copy's stage log (sizes and outcomes only, never photo content). DEBUG builds also append each line to
/// Documents/save-trace.log, so a physical-device run can be diagnosed when the system log is not reachable
/// (a phone connected over the network only).
enum SaveTrace {
    static let logger = Logger(subsystem: "com.lightlylabs.lightly", category: "SaveCopy")

    static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        #if DEBUG
        appendToDocuments(message)
        #endif
    }

    #if DEBUG
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
