import CryptoKit
import Foundation
import OSLog

/// Why no Looks could be loaded from a pack at all.
enum LookPackProblem: Error, Equatable, Sendable {
    /// No `manifest.json` (e.g. a build made without a pack).
    case missing
    case unreadableManifest(String)
    case unsupportedFormat(String)
    case unsupportedFormatVersion(Int)
    case unsupportedLUTDimension(Int)
    case unsupportedLUTEncoding(String)
}

/// One Look the loader refused, and why. Reported, never silently skipped.
struct DroppedLook: Equatable, Sendable {
    enum Reason: Error, Equatable, Sendable {
        /// `lutFile` is absolute or climbs out of the pack directory.
        case unsafeLUTPath(String)
        case missingLUTFile(String)
        case wrongLUTSize(expectedBytes: Int, actualBytes: Int)
        case checksumMismatch
        /// The same `lookId` appears again with a different LUT.
        case conflictingDuplicateID
    }

    let lookID: String
    let reason: Reason
}

/// What loading a pack produced: a (possibly empty) book plus everything
/// that was refused along the way.
struct LookPackLoadResult: Sendable {
    let book: LUTLookBook
    /// Set when the whole pack was rejected; the book is then empty.
    let problem: LookPackProblem?
    let droppedLooks: [DroppedLook]
}

/// Reads the Look pack built by `experiments/presets/look_pack/build_look_pack.py`
/// (format "lightly-look-pack", version 1; spec §4.5).
///
/// The pack is untrusted input as far as this loader is concerned: the
/// manifest's format, version, LUT dimension and encoding must match exactly,
/// and each LUT must have the contract size and the manifest's sha256. A Look
/// that fails is dropped and reported; a malformed manifest yields an empty
/// book with a reason. Categories and stops keep manifest order, because that
/// order is the curated browse order (spec D6).
enum LookPackLoader {

    /// Folder inside the app bundle (copied by `scripts/bundle_look_pack.sh`).
    static let bundleDirectoryName = "LookPack"
    static let manifestFileName = "manifest.json"

    static let supportedFormat = "lightly-look-pack"
    static let supportedFormatVersion = 1
    static let supportedLUTEncoding = "rgba-float32-red-fastest"

    private static let logger = Logger(subsystem: "com.lightlylabs.lightly", category: "LookPack")

    /// Loads the pack bundled with the app and logs anything refused.
    // DEFERRED: every LUT is read and hashed up front (≈10 MB for 18 Looks).
    // Lazy, per-Look loading is worth it once packs grow; not measured on device.
    static func loadBundled(from bundle: Bundle = .main) -> LookPackLoadResult {
        let directory = bundle.resourceURL?.appendingPathComponent(bundleDirectoryName, isDirectory: true)
            ?? bundle.bundleURL.appendingPathComponent(bundleDirectoryName, isDirectory: true)
        let result = load(from: directory)
        report(result)
        return result
    }

    static func load(from directory: URL) -> LookPackLoadResult {
        let manifest: Manifest
        switch readManifest(in: directory) {
        case .success(let decoded): manifest = decoded
        case .failure(let problem): return LookPackLoadResult(book: .empty, problem: problem, droppedLooks: [])
        }
        if let problem = unsupportedFeature(of: manifest) {
            return LookPackLoadResult(book: .empty, problem: problem, droppedLooks: [])
        }
        return assemble(manifest, in: directory)
    }

    // MARK: - Manifest

    private static func readManifest(in directory: URL) -> Result<Manifest, LookPackProblem> {
        let url = directory.appendingPathComponent(manifestFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }
        do {
            let data = try Data(contentsOf: url)
            return .success(try JSONDecoder().decode(Manifest.self, from: data))
        } catch {
            return .failure(.unreadableManifest(String(describing: error)))
        }
    }

    /// Format checks come before any LUT is read: a pack this build does
    /// not understand must not be half-loaded.
    private static func unsupportedFeature(of manifest: Manifest) -> LookPackProblem? {
        if manifest.format != supportedFormat { return .unsupportedFormat(manifest.format) }
        if manifest.formatVersion != supportedFormatVersion { return .unsupportedFormatVersion(manifest.formatVersion) }
        if manifest.lutDimension != LUT3D.contractDimension { return .unsupportedLUTDimension(manifest.lutDimension) }
        if manifest.lutEncoding != supportedLUTEncoding { return .unsupportedLUTEncoding(manifest.lutEncoding) }
        return nil
    }

    // MARK: - Looks

    private static func assemble(_ manifest: Manifest, in directory: URL) -> LookPackLoadResult {
        var looks: [LUTLook] = []
        var lutHashByID: [String: String] = [:]
        var categories: [LUTLookCategory] = []
        var dropped: [DroppedLook] = []

        for category in manifest.categories {
            var lookIDs: [String] = []
            for stop in category.stops {
                // A preset listed in two categories is one Look; the same ID
                // with a different LUT is a broken pack, not a second Look.
                if let knownHash = lutHashByID[stop.lookId] {
                    if knownHash == stop.lutSha256.lowercased() {
                        lookIDs.append(stop.lookId)
                    } else {
                        dropped.append(DroppedLook(lookID: stop.lookId, reason: .conflictingDuplicateID))
                    }
                    continue
                }
                switch readLook(stop, in: directory) {
                case .success(let look):
                    looks.append(look)
                    lutHashByID[stop.lookId] = stop.lutSha256.lowercased()
                    lookIDs.append(stop.lookId)
                case .failure(let reason):
                    dropped.append(DroppedLook(lookID: stop.lookId, reason: reason))
                }
            }
            // A category whose every Look was dropped would offer only Auto;
            // its Looks are already reported above.
            if !lookIDs.isEmpty {
                categories.append(LUTLookCategory(id: category.id, label: category.label, lookIDs: lookIDs))
            }
        }
        return LookPackLoadResult(book: LUTLookBook(looks: looks, categories: categories), problem: nil, droppedLooks: dropped)
    }

    private static func readLook(_ stop: Manifest.Stop, in directory: URL) -> Result<LUTLook, DroppedLook.Reason> {
        guard let url = containedURL(stop.lutFile, in: directory) else {
            return .failure(.unsafeLUTPath(stop.lutFile))
        }
        guard let data = try? Data(contentsOf: url) else { return .failure(.missingLUTFile(stop.lutFile)) }
        let expectedBytes = LUT3D.contractDimension * LUT3D.contractDimension * LUT3D.contractDimension
            * LUT3D.channels * MemoryLayout<Float>.size
        guard data.count == expectedBytes else {
            return .failure(.wrongLUTSize(expectedBytes: expectedBytes, actualBytes: data.count))
        }
        guard sha256Hex(data) == stop.lutSha256.lowercased() else { return .failure(.checksumMismatch) }
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard let lut = try? LUT3D(dimension: LUT3D.contractDimension, values: floats) else {
            return .failure(.wrongLUTSize(expectedBytes: expectedBytes, actualBytes: data.count))
        }
        let provenance = LookProvenance(
            lutSource: stop.lutSource, validation: stop.validation,
            omittedOperators: stop.omittedOperators, approximatedGlobally: stop.approximatedGlobally
        )
        return .success(LUTLook(id: stop.lookId, version: stop.lookVersion, name: stop.name, lut: lut, provenance: provenance))
    }

    /// The LUT's URL only if `relativePath` stays inside the pack: a
    /// manifest must not be able to make the app read arbitrary files.
    private static func containedURL(_ relativePath: String, in directory: URL) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." || $0.isEmpty }) else { return nil }
        return directory.appendingPathComponent(relativePath)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Reporting

    private static func report(_ result: LookPackLoadResult) {
        if let problem = result.problem {
            logger.error("Look pack not loaded: \(String(describing: problem), privacy: .public)")
        }
        for dropped in result.droppedLooks {
            logger.error("Look \(dropped.lookID, privacy: .public) dropped: \(String(describing: dropped.reason), privacy: .public)")
        }
        logger.info("Look pack: \(result.book.categories.count) categories, \(result.book.looks.count) Looks")
    }

    // MARK: - Manifest schema (format 1)

    private struct Manifest: Decodable {
        let format: String
        let formatVersion: Int
        let lutDimension: Int
        let lutEncoding: String
        let categories: [Category]

        struct Category: Decodable {
            let id: String
            let label: String
            let stops: [Stop]
        }

        struct Stop: Decodable {
            let lookId: String
            let lookVersion: String
            let name: String
            let lutFile: String
            let lutSha256: String
            let lutSource: String
            let validation: String
            let omittedOperators: [String]
            let approximatedGlobally: [String]
        }
    }
}
