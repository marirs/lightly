import CryptoKit
import Foundation
import Observation
import OSLog

/// The saved signatures (approved Watermark › Signature and Preferences › Saved signature).
///
/// One drawn and one imported signature can be saved at a time, as the approved panel shows
/// (`wm-signature`: a drawn chip and an imported chip). Drawing again replaces the drawn one and
/// importing again the imported one; each keeps its id, so an edit that used the earlier
/// drawing sees a changed version (edit recipe `signatureRef`: "version differs → changed").
/// Deleting removes it (an edit that used it sees it missing). Nothing is ever substituted.
///
/// Files live in Application Support/Signatures: `index.json` (ids and the most recent kind) and
/// one content file per signature. A nil directory keeps everything in memory (tests, captures).
@MainActor
@Observable
final class SignatureStore {

    /// What a recipe's reference finds in the store.
    enum Resolution: Equatable {
        case available(SavedSignature)
        /// No signature with that id (deleted, or never on this device): rendered without it.
        case unavailable
        /// The id exists but its content changed since the edit chose it: rendered without it
        /// until the person chooses the current version.
        case changed(current: SavedSignature)
    }

    private(set) var drawn: SavedSignature?
    private(set) var imported: SavedSignature?
    /// The kind saved last: Preferences shows that one (the approved page shows one signature).
    private(set) var mostRecentKind: SignatureKind?

    private let directory: URL?
    private static let log = Logger(subsystem: "com.lightlylabs.lightly", category: "signatures")

    init(directory: URL?) {
        self.directory = directory
        load()
    }

    /// The app's store in Application Support.
    static func applicationSupport() -> SignatureStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return SignatureStore(directory: base?.appendingPathComponent("Signatures", isDirectory: true))
    }

    func signature(of kind: SignatureKind) -> SavedSignature? { kind == .drawn ? drawn : imported }

    /// The signature Preferences › Saved signature shows: the one saved last, else whichever exists.
    var shown: SavedSignature? {
        if let mostRecentKind, let signature = signature(of: mostRecentKind) { return signature }
        return drawn ?? imported
    }

    var isEmpty: Bool { drawn == nil && imported == nil }

    // MARK: - Changes

    /// Saves a drawing as the drawn signature, keeping the drawn signature's id when one exists.
    @discardableResult
    func saveDrawn(_ signature: DrawnSignature) -> SavedSignature {
        save(kind: .drawn, data: signature.canonicalData)
    }

    /// Saves an imported signature (PNG with the paper removed), keeping the imported id.
    @discardableResult
    func saveImported(png: Data) -> SavedSignature {
        save(kind: .imported, data: png)
    }

    func delete(_ kind: SignatureKind) {
        if let existing = signature(of: kind), let directory {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.fileName(id: existing.id, kind: kind)))
        }
        if kind == .drawn { drawn = nil } else { imported = nil }
        if mostRecentKind == kind {
            let other: SignatureKind = kind == .drawn ? .imported : .drawn
            mostRecentKind = signature(of: other) != nil ? other : nil
        }
        writeIndex()
    }

    // MARK: - Resolving a recipe's reference

    func resolve(_ reference: EditRecipe.Watermark.SignatureRef) -> Resolution {
        guard let saved = [drawn, imported].compactMap({ $0 }).first(where: { $0.id == reference.signatureId }) else { return .unavailable }
        return saved.version == reference.signatureVersion ? .available(saved) : .changed(current: saved)
    }

    // MARK: - Chosen logo images (Watermark › Logo › Replace logo)

    /// Logo images by SHA-256 (edit recipe `assetRef` kind `file`: "imported bytes stored beside
    /// the edit by digest"). Kept beside the signatures; never shown in Preferences.
    @ObservationIgnored private var logos: [String: Data] = [:]

    /// Stores a logo image and returns its digest for the recipe.
    func saveLogo(png: Data) -> String {
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        logos[digest] = png
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? png.write(to: directory.appendingPathComponent("logo-\(digest).png"), options: .atomic)
        }
        return digest
    }

    /// The logo image with this digest, or nil when it is not on this device.
    func logo(sha256: String) -> Data? {
        if let cached = logos[sha256] { return cached }
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("logo-\(sha256).png")) else { return nil }
        logos[sha256] = data
        return data
    }

    // MARK: - Storage

    private func save(kind: SignatureKind, data: Data) -> SavedSignature {
        let id = signature(of: kind)?.id ?? UUID().uuidString.lowercased()
        let saved = SavedSignature(id: id, kind: kind, data: data)
        if let directory {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(Self.fileName(id: id, kind: kind)), options: .atomic)
            } catch {
                // Kept in memory for this launch; the next launch will not find it (shown as missing).
                Self.log.error("could not write signature: \(error.localizedDescription, privacy: .public)")
            }
        }
        if kind == .drawn { drawn = saved } else { imported = saved }
        mostRecentKind = kind
        writeIndex()
        return saved
    }

    private static func fileName(id: String, kind: SignatureKind) -> String {
        kind == .drawn ? "\(id).strokes.json" : "\(id).png"
    }

    private struct Index: Codable {
        var drawn: String?
        var imported: String?
        var mostRecent: String?
    }

    private func writeIndex() {
        guard let directory else { return }
        let index = Index(drawn: drawn?.id, imported: imported?.id, mostRecent: mostRecentKind?.rawValue)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(index).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        } catch {
            Self.log.error("could not write signature index: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load() {
        guard let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        func read(_ id: String?, _ kind: SignatureKind) -> SavedSignature? {
            guard let id, let bytes = try? Data(contentsOf: directory.appendingPathComponent(Self.fileName(id: id, kind: kind))) else { return nil }
            // The version is always recomputed from the bytes on disk, never trusted from the index.
            return SavedSignature(id: id, kind: kind, data: bytes)
        }
        drawn = read(index.drawn, .drawn)
        imported = read(index.imported, .imported)
        mostRecentKind = index.mostRecent.flatMap(SignatureKind.init(rawValue:))
    }

    #if DEBUG
    /// Captures and UI tests: replace the store's content without touching the disk.
    func debugReplace(drawn: DrawnSignature?, importedPNG: Data?) {
        self.drawn = drawn.map { SavedSignature(id: "debug-drawn", kind: .drawn, data: $0.canonicalData) }
        self.imported = importedPNG.map { SavedSignature(id: "debug-imported", kind: .imported, data: $0) }
        mostRecentKind = drawn != nil ? .drawn : (importedPNG != nil ? .imported : nil)
    }
    #endif
}
