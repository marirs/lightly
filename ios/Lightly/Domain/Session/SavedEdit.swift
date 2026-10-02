import Foundation

// Saved-edit format: EditState schema 2 (docs/m1/spec.md §3, §4.5).
//
// The JSON is a contract shared with Android (`android/core-session/.../EditState.kt`) and pinned by
// the golden files in `shared/fixtures/edit-state/`. Field names, key order and number formatting
// must reproduce those files byte for byte, which is why encoding is written out by hand below
// instead of going through `JSONEncoder` (which escapes "/" in the asset ID and does not promise a
// key order).

/// One committed edit as it is saved: the Original's identity, the Auto correction and at most one
/// Look. `revision` is the session's commit counter.
struct SavedEditState: Equatable, Sendable {
    /// 2: `look.lookVersion` is the Look pack's version string. Schema 1 used a hand-numbered
    /// integer; it is migrated on read (`SavedEditCodec.migrateSchema1`).
    static let currentSchema = 2

    var source: SavedSourceRef
    var auto: SavedAutoResult
    /// nil means "no Look" (Auto only, or the Original).
    var look: SavedLookRef?
    var revision: Int64
}

/// The Original's identity. `assetId` is opaque to the session (a PHAsset local identifier or
/// picker item identifier on iOS, a content URI on Android).
struct SavedSourceRef: Equatable, Sendable {
    var assetId: String
    var fingerprint: SavedSourceFingerprint
    /// EXIF orientation (1–8) of the Original as decoded.
    var orientation: Int
}

/// `sha256(first 64 KiB) + byte size + pixel size` (spec §3).
struct SavedSourceFingerprint: Equatable, Sendable {
    var headSha256: String
    var byteSize: Int64
    var pixelWidth: Int
    var pixelHeight: Int
}

/// Guardrail applied to the fused Auto LUT; versioned so an old edit re-renders identically.
enum SavedAutoGuardrail: String, Equatable, Sendable {
    case endpointV1 = "endpoint-v1"
}

/// The Auto correction as saved. The weights are stored so a restored edit never silently re-runs a
/// different model.
struct SavedAutoResult: Equatable, Sendable {
    static let weightCount = 3
    static let ia3dlutModelID = "ia3dlut"
    /// Same marker as Android `EditorViewModel.NO_MODEL_IN_BUILD_MODEL_VERSION`: Auto was never
    /// applied because this build ships no model. It is a reason, not a model version to resolve.
    static let noModelInBuildVersion = "no-model-in-build"

    var modelId: String
    var modelVersion: String
    var weights: [Float]
    var guardrail: SavedAutoGuardrail?
    var strength: Float

    /// The Auto block an iOS edit carries while no Auto model ships: zero weights, strength 0.
    // DEFERRED: real model ID, version and weights once a production Auto model is bundled
    // (spec §4.6); until then nothing on iOS can produce them.
    static let noModelInBuild = SavedAutoResult(
        modelId: ia3dlutModelID, modelVersion: noModelInBuildVersion,
        weights: [0, 0, 0], guardrail: nil, strength: 0
    )
}

/// A reference to one Look of the pack, by ID and the pack's version string for it. The LUT itself
/// lives in the pack; a mismatching version is reported, never silently replayed (§4.5).
struct SavedLookRef: Equatable, Sendable {
    /// Schema 1 → 2 migration prefix: such a version can never equal a pack version, so a migrated
    /// Look always resolves as "changed" and asks before it is applied.
    static let legacyVersionPrefix = "legacy-v1-"

    var lookId: String
    var lookVersion: String
    var strength: Float
}

/// A whole editing session as saved: the undo stack, its cursor and the revision counter.
///
/// Same shape and invariants as Android `EditSession` / `UndoStack`, so one JSON reader can
/// validate both: `{"history":{"entries":[…],"cursor":n,"capacity":50},"lastIssuedRevision":n}`.
struct SavedEditSession: Equatable, Sendable {
    var entries: [SavedEditState]
    var cursor: Int
    var capacity: Int
    var lastIssuedRevision: Int64

    var current: SavedEditState { entries[cursor] }
}

/// Why saved-edit JSON was refused. A refused edit is never half-read: no field of it is used.
enum SavedEditDecodingError: Error, Equatable, Sendable {
    case malformedJSON
    case unsupportedSchema(Int)
    /// A key this schema does not define, e.g. "extra" or "look.tint".
    case unknownKey(String)
    case missingKey(String)
    case wrongType(String)
    /// Present and well-typed but outside the contract (strength outside 0…1, orientation 9, …).
    case invalidValue(String)
}

// MARK: - Codec

/// Reads and writes saved edits.
///
/// Reading is strict (unknown keys, unknown schemas and out-of-range values are rejected) and
/// migrates schema 1. Writing is canonical: the same value always produces the same bytes, and
/// those bytes equal Android's for every value the shared fixtures cover.
enum SavedEditCodec {

    // MARK: Decode

    static func decodeState(_ data: Data) throws -> SavedEditState {
        try SavedEditReader.state(from: try jsonObject(data), path: "")
    }

    static func decodeSession(_ data: Data) throws -> SavedEditSession {
        try SavedEditReader.session(from: try jsonObject(data))
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw SavedEditDecodingError.malformedJSON
        }
        return object
    }

    // MARK: Encode

    static func encode(_ state: SavedEditState) -> Data {
        var writer = CanonicalJSONWriter()
        writer.write(state)
        return writer.data
    }

    static func encode(_ session: SavedEditSession) -> Data {
        var writer = CanonicalJSONWriter()
        writer.write(session)
        return writer.data
    }
}

// MARK: - Reading

/// Walks the `JSONSerialization` tree by hand so that every key is accounted for and integers and
/// floats are told apart (schema 1's numeric `lookVersion` must be migrated, not read as a string).
private enum SavedEditReader {

    static func state(from object: [String: Any], path: String) throws -> SavedEditState {
        let schema = try integer(object, "schema", path: path)
        switch schema {
        case 2:
            return try schema2State(from: object, path: path)
        case 1:
            return try migrateSchema1(object, path: path)
        default:
            throw SavedEditDecodingError.unsupportedSchema(Int(clamping: schema))
        }
    }

    private static func schema2State(from object: [String: Any], path: String) throws -> SavedEditState {
        try requireExactKeys(object, ["schema", "source", "auto", "look", "revision"], path: path)
        let look: SavedLookRef?
        if let lookObject = try optionalObject(object, "look", path: path) {
            look = try lookRef(lookObject, path: join(path, "look"), version: { object, key, path in
                try string(object, key, path: path)
            })
        } else {
            look = nil
        }
        return try assemble(object, look: look, path: path)
    }

    /// Schema 1 differs only in `look.lookVersion`, an integer. It becomes `"legacy-v1-<n>"`;
    /// everything else is kept exactly (shared/fixtures/edit-state/v1-migrated-to-v2.json).
    private static func migrateSchema1(_ object: [String: Any], path: String) throws -> SavedEditState {
        try requireExactKeys(object, ["schema", "source", "auto", "look", "revision"], path: path)
        let look: SavedLookRef?
        if let lookObject = try optionalObject(object, "look", path: path) {
            look = try lookRef(lookObject, path: join(path, "look"), version: { object, key, path in
                SavedLookRef.legacyVersionPrefix + String(try integer(object, key, path: path))
            })
        } else {
            look = nil
        }
        return try assemble(object, look: look, path: path)
    }

    private static func assemble(_ object: [String: Any], look: SavedLookRef?, path: String) throws -> SavedEditState {
        let revision = try integer(object, "revision", path: path)
        guard revision >= 0 else { throw SavedEditDecodingError.invalidValue(join(path, "revision")) }
        return SavedEditState(
            source: try sourceRef(try requiredObject(object, "source", path: path), path: join(path, "source")),
            auto: try autoResult(try requiredObject(object, "auto", path: path), path: join(path, "auto")),
            look: look,
            revision: revision
        )
    }

    private static func sourceRef(_ object: [String: Any], path: String) throws -> SavedSourceRef {
        try requireExactKeys(object, ["assetId", "fingerprint", "orientation"], path: path)
        let orientation = try integer(object, "orientation", path: path)
        guard (1...8).contains(orientation) else { throw SavedEditDecodingError.invalidValue(join(path, "orientation")) }
        return SavedSourceRef(
            assetId: try string(object, "assetId", path: path),
            fingerprint: try fingerprint(try requiredObject(object, "fingerprint", path: path), path: join(path, "fingerprint")),
            orientation: Int(orientation)
        )
    }

    private static func fingerprint(_ object: [String: Any], path: String) throws -> SavedSourceFingerprint {
        try requireExactKeys(object, ["headSha256", "byteSize", "pixelWidth", "pixelHeight"], path: path)
        let head = try string(object, "headSha256", path: path)
        let isLowercaseHex = head.count == 64 && head.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        guard isLowercaseHex else { throw SavedEditDecodingError.invalidValue(join(path, "headSha256")) }
        let byteSize = try integer(object, "byteSize", path: path)
        let width = try integer(object, "pixelWidth", path: path)
        let height = try integer(object, "pixelHeight", path: path)
        guard byteSize > 0 else { throw SavedEditDecodingError.invalidValue(join(path, "byteSize")) }
        guard width > 0, height > 0, width <= Int32.max, height <= Int32.max else {
            throw SavedEditDecodingError.invalidValue(join(path, "pixelWidth"))
        }
        return SavedSourceFingerprint(headSha256: head, byteSize: byteSize, pixelWidth: Int(width), pixelHeight: Int(height))
    }

    private static func autoResult(_ object: [String: Any], path: String) throws -> SavedAutoResult {
        try requireExactKeys(object, ["modelId", "modelVersion", "weights", "guardrail", "strength"], path: path)
        guard let rawWeights = object["weights"] as? [Any] else { throw SavedEditDecodingError.wrongType(join(path, "weights")) }
        let weights = try rawWeights.map { try float($0, path: join(path, "weights")) }
        guard weights.count == SavedAutoResult.weightCount else { throw SavedEditDecodingError.invalidValue(join(path, "weights")) }
        let guardrail: SavedAutoGuardrail?
        switch object["guardrail"] {
        case is NSNull: guardrail = nil
        case let name as String:
            guard let known = SavedAutoGuardrail(rawValue: name) else { throw SavedEditDecodingError.invalidValue(join(path, "guardrail")) }
            guardrail = known
        default: throw SavedEditDecodingError.wrongType(join(path, "guardrail"))
        }
        return SavedAutoResult(
            modelId: try string(object, "modelId", path: path),
            modelVersion: try string(object, "modelVersion", path: path),
            weights: weights,
            guardrail: guardrail,
            strength: try unitStrength(object, path: path)
        )
    }

    private static func lookRef(
        _ object: [String: Any], path: String,
        version: ([String: Any], String, String) throws -> String
    ) throws -> SavedLookRef {
        try requireExactKeys(object, ["lookId", "lookVersion", "strength"], path: path)
        let lookId = try string(object, "lookId", path: path)
        let lookVersion = try version(object, "lookVersion", path)
        guard !lookId.trimmingCharacters(in: .whitespaces).isEmpty else { throw SavedEditDecodingError.invalidValue(join(path, "lookId")) }
        guard !lookVersion.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SavedEditDecodingError.invalidValue(join(path, "lookVersion"))
        }
        return SavedLookRef(lookId: lookId, lookVersion: lookVersion, strength: try unitStrength(object, path: path))
    }

    static func session(from object: [String: Any]) throws -> SavedEditSession {
        try requireExactKeys(object, ["history", "lastIssuedRevision"], path: "")
        let history = try requiredObject(object, "history", path: "")
        try requireExactKeys(history, ["entries", "cursor", "capacity"], path: "history")
        guard let rawEntries = history["entries"] as? [Any] else { throw SavedEditDecodingError.wrongType("history.entries") }
        let entries = try rawEntries.enumerated().map { index, raw in
            guard let entry = raw as? [String: Any] else { throw SavedEditDecodingError.wrongType("history.entries[\(index)]") }
            return try state(from: entry, path: "history.entries[\(index)]")
        }
        let cursor = try integer(history, "cursor", path: "history")
        let capacity = try integer(history, "capacity", path: "history")
        let lastIssuedRevision = try integer(object, "lastIssuedRevision", path: "")
        // Android UndoStack / EditSession invariants: a snapshot that breaks them is corrupt.
        guard capacity >= 1, !entries.isEmpty, entries.count <= capacity else {
            throw SavedEditDecodingError.invalidValue("history.entries")
        }
        guard entries.indices.contains(Int(cursor)) else { throw SavedEditDecodingError.invalidValue("history.cursor") }
        guard entries.allSatisfy({ $0.revision <= lastIssuedRevision }) else {
            throw SavedEditDecodingError.invalidValue("lastIssuedRevision")
        }
        guard Set(entries.map(\.source.assetId)).count == 1, entries.allSatisfy({ $0.source == entries[0].source }) else {
            throw SavedEditDecodingError.invalidValue("history.entries.source")
        }
        return SavedEditSession(entries: entries, cursor: Int(cursor), capacity: Int(capacity), lastIssuedRevision: lastIssuedRevision)
    }

    // MARK: Primitives

    private static func join(_ path: String, _ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

    private static func requireExactKeys(_ object: [String: Any], _ keys: [String], path: String) throws {
        if let unknown = object.keys.sorted().first(where: { !keys.contains($0) }) {
            throw SavedEditDecodingError.unknownKey(join(path, unknown))
        }
        // Explicit nulls are part of the contract (Android `explicitNulls`), so a missing key is
        // an error even where the value may be null.
        if let missing = keys.first(where: { object[$0] == nil }) {
            throw SavedEditDecodingError.missingKey(join(path, missing))
        }
    }

    private static func requiredObject(_ object: [String: Any], _ key: String, path: String) throws -> [String: Any] {
        guard let value = object[key] as? [String: Any] else { throw SavedEditDecodingError.wrongType(join(path, key)) }
        return value
    }

    private static func optionalObject(_ object: [String: Any], _ key: String, path: String) throws -> [String: Any]? {
        if object[key] is NSNull { return nil }
        return try requiredObject(object, key, path: path)
    }

    private static func string(_ object: [String: Any], _ key: String, path: String) throws -> String {
        guard let value = object[key] as? String else { throw SavedEditDecodingError.wrongType(join(path, key)) }
        return value
    }

    /// An integral JSON number. Booleans and numbers written with a fraction or exponent are
    /// refused, so `"lookVersion": 2.0` or `true` cannot pass for a schema 1 version.
    private static func integer(_ object: [String: Any], _ key: String, path: String) throws -> Int64 {
        guard let number = object[key] as? NSNumber, !isBoolean(number), !CFNumberIsFloatType(number) else {
            throw SavedEditDecodingError.wrongType(join(path, key))
        }
        return number.int64Value
    }

    private static func float(_ value: Any, path: String) throws -> Float {
        guard let number = value as? NSNumber, !isBoolean(number) else { throw SavedEditDecodingError.wrongType(path) }
        let float = Float(number.doubleValue)
        guard float.isFinite else { throw SavedEditDecodingError.invalidValue(path) }
        return float
    }

    private static func unitStrength(_ object: [String: Any], path: String) throws -> Float {
        guard let raw = object["strength"] else { throw SavedEditDecodingError.missingKey(join(path, "strength")) }
        let strength = try float(raw, path: join(path, "strength"))
        guard (0...1).contains(strength) else { throw SavedEditDecodingError.invalidValue(join(path, "strength")) }
        return strength
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

// MARK: - Writing

/// Compact JSON with the contract's key order and Kotlin-compatible number text.
private struct CanonicalJSONWriter {
    private(set) var text = ""

    var data: Data { Data(text.utf8) }

    mutating func write(_ state: SavedEditState) {
        text += "{\"schema\":\(SavedEditState.currentSchema),\"source\":"
        write(state.source)
        text += ",\"auto\":"
        write(state.auto)
        text += ",\"look\":"
        if let look = state.look { write(look) } else { text += "null" }
        text += ",\"revision\":\(state.revision)}"
    }

    mutating func write(_ session: SavedEditSession) {
        text += "{\"history\":{\"entries\":["
        for (index, entry) in session.entries.enumerated() {
            if index > 0 { text += "," }
            write(entry)
        }
        text += "],\"cursor\":\(session.cursor),\"capacity\":\(session.capacity)},\"lastIssuedRevision\":\(session.lastIssuedRevision)}"
    }

    private mutating func write(_ source: SavedSourceRef) {
        let fingerprint = source.fingerprint
        text += "{\"assetId\":\(Self.quoted(source.assetId)),\"fingerprint\":{"
        text += "\"headSha256\":\(Self.quoted(fingerprint.headSha256)),\"byteSize\":\(fingerprint.byteSize),"
        text += "\"pixelWidth\":\(fingerprint.pixelWidth),\"pixelHeight\":\(fingerprint.pixelHeight)},"
        text += "\"orientation\":\(source.orientation)}"
    }

    private mutating func write(_ auto: SavedAutoResult) {
        text += "{\"modelId\":\(Self.quoted(auto.modelId)),\"modelVersion\":\(Self.quoted(auto.modelVersion)),"
        text += "\"weights\":[\(auto.weights.map(Self.number).joined(separator: ","))],"
        text += "\"guardrail\":\(auto.guardrail.map { Self.quoted($0.rawValue) } ?? "null"),"
        text += "\"strength\":\(Self.number(auto.strength))}"
    }

    private mutating func write(_ look: SavedLookRef) {
        text += "{\"lookId\":\(Self.quoted(look.lookId)),\"lookVersion\":\(Self.quoted(look.lookVersion)),"
        text += "\"strength\":\(Self.number(look.strength))}"
    }

    /// Shortest text that reads back as the same Float, like Kotlin's `Float.toString` for every
    /// value in 1e-3…1e7 ("0.8", "1.0", "-0.25").
    // DEFERRED: below 1e-3 Kotlin writes "1.0E-4" where Swift writes "0.0001". Both read back to
    // the same Float, so they interoperate; only byte equality across platforms differs, and no
    // fixture covers it. Strengths and weights in practice never get that small.
    private static func number(_ value: Float) -> String {
        "\(value)"
    }

    /// JSON string with the escapes kotlinx.serialization writes: quote, backslash and control
    /// characters. "/" is not escaped (Foundation's encoder would write "\/").
    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case let control where control.value < 0x20:
                result += String(format: "\\u%04x", control.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
