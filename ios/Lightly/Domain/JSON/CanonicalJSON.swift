import Foundation

/// A JSON value that keeps what Foundation's parsers throw away: the order of an object's keys and
/// the exact text of every number.
///
/// Two contracts need that:
/// - `lookVersion` (rendering-v2 §4.3) hashes a preset recipe as Python's
///   `json.dumps(sort_keys=True, separators=(",", ":"))` writes it. The pack was written by the same
///   `json` module, so re-emitting each number's original literal reproduces those bytes exactly,
///   where a round trip through `Double` could not (e.g. `100` vs `100.0`).
/// - EditState schema 3 (edit-recipe-v1) is strict and canonical: keys in schema order, integers
///   without a decimal point. A reader must reject unknown keys and must not reorder anything.
indirect enum CanonicalJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The number exactly as written in the source text.
    case number(String)
    case string(String)
    case array([CanonicalJSON])
    /// Members in source order. Duplicate keys are rejected by the parser.
    case object([(key: String, value: CanonicalJSON)])

    static func == (lhs: CanonicalJSON, rhs: CanonicalJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    // MARK: - Accessors

    subscript(key: String) -> CanonicalJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    var objectMembers: [(key: String, value: CanonicalJSON)]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var arrayValue: [CanonicalJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let literal) = self { return Double(literal) }
        return nil
    }

    /// The number as an integer, only when its literal has no fraction or exponent.
    var integerLiteralValue: Int64? {
        guard case .number(let literal) = self, !literal.contains(where: { ".eE".contains($0) }) else { return nil }
        return Int64(literal)
    }

    var isNull: Bool { if case .null = self { return true } else { return false } }

    // MARK: - Writing

    enum KeyOrder {
        /// Keys as stored (schema order for EditState).
        case asStored
        /// Python `sort_keys=True`: by Unicode code points.
        case sorted
    }

    /// Compact UTF-8 bytes: no whitespace, `","` and `":"` separators, strings escaped as Python's
    /// `json.dumps(ensure_ascii=False)` escapes them.
    func serialized(keys order: KeyOrder = .asStored) -> Data {
        var text = ""
        write(into: &text, order: order)
        return Data(text.utf8)
    }

    private func write(into text: inout String, order: KeyOrder) {
        switch self {
        case .null: text += "null"
        case .bool(let value): text += value ? "true" : "false"
        case .number(let literal): text += literal
        case .string(let value): Self.writeString(value, into: &text)
        case .array(let items):
            text += "["
            for (index, item) in items.enumerated() {
                if index > 0 { text += "," }
                item.write(into: &text, order: order)
            }
            text += "]"
        case .object(let members):
            let ordered = order == .sorted
                ? members.sorted { Array($0.key.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.key.unicodeScalars.map(\.value)) }
                : members
            text += "{"
            for (index, member) in ordered.enumerated() {
                if index > 0 { text += "," }
                Self.writeString(member.key, into: &text)
                text += ":"
                member.value.write(into: &text, order: order)
            }
            text += "}"
        }
    }

    private static func writeString(_ value: String, into text: inout String) {
        text += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            case "\u{08}": text += "\\b"
            case "\u{0C}": text += "\\f"
            default:
                if scalar.value < 0x20 {
                    text += String(format: "\\u%04x", scalar.value)
                } else {
                    text.unicodeScalars.append(scalar)
                }
            }
        }
        text += "\""
    }

    // MARK: - Parsing

    enum ParseError: Error, Equatable {
        case unexpectedEnd
        case unexpected(character: UInt8, offset: Int)
        case invalidNumber(offset: Int)
        case invalidString(offset: Int)
        case duplicateKey(String)
        case trailingContent(offset: Int)
    }

    /// Strict RFC 8259 parsing (no comments, no trailing commas, no NaN). Duplicate keys are an
    /// error rather than "last wins", so a document can never mean two things.
    static func parse(_ data: Data) throws -> CanonicalJSON {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.offset == parser.bytes.count else { throw ParseError.trailingContent(offset: parser.offset) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        mutating func skipWhitespace() {
            while offset < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[offset]) { offset += 1 }
        }

        mutating func parseValue() throws -> CanonicalJSON {
            guard offset < bytes.count else { throw ParseError.unexpectedEnd }
            switch bytes[offset] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
            default: throw ParseError.unexpected(character: bytes[offset], offset: offset)
            }
        }

        mutating func expect(_ word: String) throws {
            for byte in word.utf8 {
                guard offset < bytes.count else { throw ParseError.unexpectedEnd }
                guard bytes[offset] == byte else { throw ParseError.unexpected(character: bytes[offset], offset: offset) }
                offset += 1
            }
        }

        mutating func parseObject() throws -> CanonicalJSON {
            offset += 1
            var members: [(key: String, value: CanonicalJSON)] = []
            var seen = Set<String>()
            skipWhitespace()
            if offset < bytes.count, bytes[offset] == UInt8(ascii: "}") { offset += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard offset < bytes.count else { throw ParseError.unexpectedEnd }
                guard bytes[offset] == UInt8(ascii: "\"") else { throw ParseError.unexpected(character: bytes[offset], offset: offset) }
                let key = try parseString()
                guard seen.insert(key).inserted else { throw ParseError.duplicateKey(key) }
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                members.append((key, try parseValue()))
                skipWhitespace()
                guard offset < bytes.count else { throw ParseError.unexpectedEnd }
                if bytes[offset] == UInt8(ascii: ",") { offset += 1; continue }
                if bytes[offset] == UInt8(ascii: "}") { offset += 1; return .object(members) }
                throw ParseError.unexpected(character: bytes[offset], offset: offset)
            }
        }

        mutating func parseArray() throws -> CanonicalJSON {
            offset += 1
            var items: [CanonicalJSON] = []
            skipWhitespace()
            if offset < bytes.count, bytes[offset] == UInt8(ascii: "]") { offset += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue())
                skipWhitespace()
                guard offset < bytes.count else { throw ParseError.unexpectedEnd }
                if bytes[offset] == UInt8(ascii: ",") { offset += 1; continue }
                if bytes[offset] == UInt8(ascii: "]") { offset += 1; return .array(items) }
                throw ParseError.unexpected(character: bytes[offset], offset: offset)
            }
        }

        mutating func parseString() throws -> String {
            let start = offset
            offset += 1
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []
            func flushRaw() throws {
                guard !raw.isEmpty else { return }
                guard let decoded = String(bytes: raw, encoding: .utf8) else { throw ParseError.invalidString(offset: start) }
                scalars.append(contentsOf: decoded.unicodeScalars)
                raw.removeAll(keepingCapacity: true)
            }
            while true {
                guard offset < bytes.count else { throw ParseError.unexpectedEnd }
                let byte = bytes[offset]
                if byte == UInt8(ascii: "\"") { offset += 1; break }
                if byte < 0x20 { throw ParseError.invalidString(offset: offset) }
                if byte != UInt8(ascii: "\\") { raw.append(byte); offset += 1; continue }
                try flushRaw()
                offset += 1
                guard offset < bytes.count else { throw ParseError.unexpectedEnd }
                let escape = bytes[offset]
                offset += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code) {
                        try expect("\\u")
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw ParseError.invalidString(offset: offset) }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw ParseError.invalidString(offset: offset) }
                    scalars.append(scalar)
                default:
                    throw ParseError.invalidString(offset: offset)
                }
            }
            try flushRaw()
            return String(scalars)
        }

        mutating func hex4() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw ParseError.unexpectedEnd }
            guard let text = String(bytes: bytes[offset..<offset + 4], encoding: .ascii),
                  let value = UInt32(text, radix: 16) else { throw ParseError.invalidString(offset: offset) }
            offset += 4
            return value
        }

        /// `-? (0 | [1-9][0-9]*) (\.[0-9]+)? ([eE][+-]?[0-9]+)?`, kept as text.
        mutating func parseNumber() throws -> String {
            let start = offset
            func digits() -> Int {
                let begin = offset
                while offset < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[offset]) { offset += 1 }
                return offset - begin
            }
            if bytes[offset] == UInt8(ascii: "-") { offset += 1 }
            guard offset < bytes.count else { throw ParseError.invalidNumber(offset: start) }
            if bytes[offset] == UInt8(ascii: "0") {
                offset += 1
            } else if digits() == 0 {
                throw ParseError.invalidNumber(offset: start)
            }
            if offset < bytes.count, bytes[offset] == UInt8(ascii: ".") {
                offset += 1
                guard digits() > 0 else { throw ParseError.invalidNumber(offset: start) }
            }
            if offset < bytes.count, bytes[offset] == UInt8(ascii: "e") || bytes[offset] == UInt8(ascii: "E") {
                offset += 1
                if offset < bytes.count, bytes[offset] == UInt8(ascii: "+") || bytes[offset] == UInt8(ascii: "-") { offset += 1 }
                guard digits() > 0 else { throw ParseError.invalidNumber(offset: start) }
            }
            return String(decoding: bytes[start..<offset], as: UTF8.self)
        }
    }
}
