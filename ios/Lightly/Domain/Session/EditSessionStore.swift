import CoreGraphics
import Foundation
import OSLog

/// The model results a session was edited with, kept so a restored session never runs a model
/// again (Auto, Vision, depth): people and faces, the subject matte, the depth map and the
/// person matte, at the preview resolution they were computed at.
struct PersistedAnalysis: Sendable {
    var hasPerson: Bool?
    var people: PeopleAnalysis?
    var subjectAnalysed = false
    var subject: SubjectMatte?
    var disparity: DisparityMap?
    var personMatte: FloatImage?
}

/// One editing session as it stood when last changed: the original photo's bytes, the whole undo
/// history (canonical edit-recipe-v1 JSON per entry) with its position, the Auto state and the
/// model results.
struct PersistedEditSession: Sendable {
    var original: Data
    var history: [EditRecipe]
    var index: Int
    /// `EditorSession.AutoState` by name (applied, off, unavailable, failed).
    var autoState: String
    /// The UIKit scene session the edit was made in (`UISceneSession.persistentIdentifier`).
    /// iOS keeps a scene session when it ends the app itself and discards it when the person
    /// removes the app in the app switcher, so this tells a system kill from a force-quit.
    var sceneSessionID: String?
    var analysis: PersistedAnalysis
    /// Core Image Auto: the filters and parameters that were applied (iOS 1.0 Auto).
    var autoCorrection: CoreImageAutoCorrection? = nil
}

/// Keeps the working session on disk while it has unsaved edits, so that when the system ends
/// the app in the background the person comes back to the same edit (spec §27: "Persist history
/// with the working session so a returning user can still step back"). Remove patches and
/// saved signatures have their own stores.
///
/// Application Support/EditSession, excluded from iCloud and device backup, files protected
/// until first unlock. Writes go through one serial queue in order (the original is written once,
/// the history on every change, the analysis when it changes); `clear()` is queued the same way.
final class EditSessionStore: @unchecked Sendable {
    // @unchecked: every file operation runs on `queue`; `directory` is immutable.
    private let directory: URL?
    private let queue = DispatchQueue(label: "com.lightlylabs.lightly.edit-session", qos: .utility)
    private static let log = Logger(subsystem: "com.lightlylabs.lightly", category: "edit-session")
    private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    init(directory: URL?) { self.directory = directory }

    static func applicationSupport() -> EditSessionStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return EditSessionStore(directory: base?.appendingPathComponent("EditSession", isDirectory: true))
    }

    // MARK: - Writing

    func saveOriginal(_ data: Data) {
        write { directory in try self.writeFile(data, named: "original.bin", in: directory) }
    }

    func saveHistory(_ history: [EditRecipe], index: Int, autoState: String, sceneSessionID: String?, autoCorrection: [String: Any]? = nil) {
        // JSON Lines: a header line, then one canonical recipe per line (canonical JSON is compact).
        var header: [String: Any] = ["format": 1, "index": index, "autoState": autoState]
        if let sceneSessionID { header["scene"] = sceneSessionID }
        if let autoCorrection { header["autoCorrection"] = autoCorrection }
        var data = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        for recipe in history {
            data.append(EditRecipeCodec.encode(recipe))
            data.append(0x0A)
        }
        write { directory in try self.writeFile(data, named: "history.jsonl", in: directory) }
    }

    func saveAnalysis(_ analysis: PersistedAnalysis) {
        write { directory in
            try self.writeFile(Self.encodeAnalysis(analysis), named: "analysis.json", in: directory)
            for (name, image) in [("subject-matte.f32", analysis.subject?.matte), ("disparity.f32", analysis.disparity?.disparity),
                                  ("person-matte.f32", analysis.personMatte)] {
                if let image {
                    try self.writeFile(Self.encodeImage(image), named: name, in: directory)
                } else {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                }
            }
        }
    }

    /// Saving a copy, Discard, closing the photo or choosing another one: nothing to restore.
    func clear() {
        guard let directory else { return }
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }

    /// Waits for queued writes (tests, and before reading back).
    func flush() { queue.sync {} }

    private func write(_ body: @escaping (URL) throws -> Void) {
        guard let directory else { return }
        queue.async {
            do {
                try Self.prepare(directory)
                try body(directory)
            } catch {
                // The session stays in memory; a restore after a kill would find it incomplete
                // and start from Welcome instead.
                Self.log.error("could not persist the session: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func writeFile(_ data: Data, named name: String, in directory: URL) throws {
        var url = directory.appendingPathComponent(name)
        try data.write(to: url, options: Self.writeOptions)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private static func prepare(_ directory: URL) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    // MARK: - Reading

    /// The stored session, or nil when there is none or it is incomplete or unreadable.
    func load() -> PersistedEditSession? {
        guard let directory else { return nil }
        return queue.sync { () -> PersistedEditSession? in
            guard let original = try? Data(contentsOf: directory.appendingPathComponent("original.bin")),
                  let text = try? Data(contentsOf: directory.appendingPathComponent("history.jsonl")) else { return nil }
            let lines = text.split(separator: 0x0A, omittingEmptySubsequences: true)
            guard let headerData = lines.first,
                  let header = try? JSONSerialization.jsonObject(with: Data(headerData)) as? [String: Any],
                  header["format"] as? Int == 1, let index = header["index"] as? Int, let auto = header["autoState"] as? String
            else { return nil }
            var history: [EditRecipe] = []
            for line in lines.dropFirst() {
                guard let recipe = try? EditRecipeCodec.decode(Data(line)) else { return nil }
                history.append(recipe)
            }
            guard history.indices.contains(index) else { return nil }
            var analysis = PersistedAnalysis()
            if let data = try? Data(contentsOf: directory.appendingPathComponent("analysis.json")) {
                analysis = Self.decodeAnalysis(data, images: { name in
                    (try? Data(contentsOf: directory.appendingPathComponent(name))).flatMap(Self.decodeImage)
                }) ?? PersistedAnalysis()
            }
            return PersistedEditSession(original: original, history: history, index: index, autoState: auto,
                                        sceneSessionID: header["scene"] as? String, analysis: analysis,
                                        autoCorrection: CoreImageAutoCorrection(json: header["autoCorrection"]))
        }
    }

    // MARK: - Encoding

    /// FloatImage: three little-endian Int32 (width, height, channels), then little-endian Float32.
    static func encodeImage(_ image: FloatImage) -> Data {
        var data = Data()
        for value in [image.width, image.height, image.channels] { withUnsafeBytes(of: Int32(value).littleEndian) { data.append(contentsOf: $0) } }
        for value in image.data { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    static func decodeImage(_ data: Data) -> FloatImage? {
        guard data.count >= 12 else { return nil }
        let header = (0..<3).map { i in Int(Int32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 4, as: Int32.self) })) }
        let count = header[0] * header[1] * header[2]
        guard header.allSatisfy({ $0 > 0 }), data.count == 12 + count * 4 else { return nil }
        let values = data.withUnsafeBytes { raw in
            (0..<count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 12 + $0 * 4, as: UInt32.self))) }
        }
        return FloatImage(width: header[0], height: header[1], channels: header[2], data: values)
    }

    private static func encodeModel(_ ref: EditRecipe.ModelRef) -> [String: String] { ["id": ref.id, "version": ref.version] }
    private static func decodeModel(_ object: Any?) -> EditRecipe.ModelRef? {
        guard let o = object as? [String: String], let id = o["id"], let version = o["version"] else { return nil }
        return .init(id: id, version: version)
    }
    private static func encodeRect(_ r: EditRecipe.Rect) -> [Double] { [r.x, r.y, r.width, r.height] }
    private static func decodeRect(_ object: Any?) -> EditRecipe.Rect? {
        guard let a = object as? [Double], a.count == 4 else { return nil }
        return .init(x: a[0], y: a[1], width: a[2], height: a[3])
    }
    private static func encodePoints(_ p: [CGPoint]) -> [[Double]] { p.map { [Double($0.x), Double($0.y)] } }
    private static func decodePoints(_ object: Any?) -> [CGPoint] {
        ((object as? [[Double]]) ?? []).compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
    }

    static func encodeAnalysis(_ a: PersistedAnalysis) -> Data {
        var object: [String: Any] = ["format": 1, "subjectAnalysed": a.subjectAnalysed]
        if let hasPerson = a.hasPerson { object["hasPerson"] = hasPerson }
        if let people = a.people {
            object["people"] = [
                "people": people.people.map(encodeRect),
                "faces": people.faces.map { f -> [String: Any] in
                    var face: [String: Any] = ["box": encodeRect(f.box), "faceContour": encodePoints(f.faceContour), "leftEye": encodePoints(f.leftEye),
                                               "rightEye": encodePoints(f.rightEye), "leftEyebrow": encodePoints(f.leftEyebrow),
                                               "rightEyebrow": encodePoints(f.rightEyebrow), "outerLips": encodePoints(f.outerLips),
                                               "innerLips": encodePoints(f.innerLips)]
                    if let q = f.quality { face["quality"] = Double(q) }
                    return face
                }
            ]
        }
        if let subject = a.subject { object["subjectModel"] = encodeModel(subject.model) }
        if let disparity = a.disparity { object["disparityModel"] = encodeModel(disparity.model); object["disparitySource"] = disparity.source.rawValue }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static func decodeAnalysis(_ data: Data, images: (String) -> FloatImage?) -> PersistedAnalysis? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], o["format"] as? Int == 1 else { return nil }
        var a = PersistedAnalysis()
        a.hasPerson = o["hasPerson"] as? Bool
        a.subjectAnalysed = o["subjectAnalysed"] as? Bool ?? false
        if let p = o["people"] as? [String: Any] {
            let faces = ((p["faces"] as? [[String: Any]]) ?? []).compactMap { f -> DetectedFace? in
                guard let box = decodeRect(f["box"]) else { return nil }
                return DetectedFace(box: box, faceContour: decodePoints(f["faceContour"]), leftEye: decodePoints(f["leftEye"]),
                                    rightEye: decodePoints(f["rightEye"]), leftEyebrow: decodePoints(f["leftEyebrow"]),
                                    rightEyebrow: decodePoints(f["rightEyebrow"]), outerLips: decodePoints(f["outerLips"]),
                                    innerLips: decodePoints(f["innerLips"]), quality: (f["quality"] as? Double).map(Float.init))
            }
            a.people = PeopleAnalysis(faces: faces, people: ((p["people"] as? [[Double]]) ?? []).compactMap { decodeRect($0) })
        }
        if let m = decodeModel(o["subjectModel"]), let matte = images("subject-matte.f32") { a.subject = SubjectMatte(matte: matte, model: m) }
        if let m = decodeModel(o["disparityModel"]), let source = (o["disparitySource"] as? String).flatMap(EditRecipe.Depth.Source.init(rawValue:)),
           let map = images("disparity.f32") {
            a.disparity = DisparityMap(disparity: map, source: source, model: m)
        }
        a.personMatte = images("person-matte.f32")
        return a
    }
}
