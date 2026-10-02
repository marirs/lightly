import CryptoKit
import Foundation
@testable import Lightly

/// Writes small, deterministic Look packs to a temporary directory.
///
/// Formula LUTs live here and only here: they are test fixtures, never app
/// content (spec §4.5). The real pack is derived from a private preset
/// collection and is not available to (or wanted by) unit and snapshot tests.
struct LookPackFixture {

    struct Look {
        let id: String
        let name: String
        var lutSource = "lr-model-approximation"
        var validation = "unvalidated"
        let transform: @Sendable (SIMD3<Float>) -> SIMD3<Float>
    }

    struct Category {
        let id: String
        let label: String
        let looks: [Look]
    }

    let directory: URL

    /// Writes `manifest.json` and `luts/<id>.f32`. `manifestEdits` may
    /// rewrite the manifest dictionary before it is saved (for malformed
    /// cases); `lutEdits` may replace a Look's LUT bytes after hashing.
    @discardableResult
    static func write(
        _ categories: [Category],
        to directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lookpack-\(UUID().uuidString)", isDirectory: true),
        manifestEdits: (inout [String: Any]) -> Void = { _ in },
        lutEdits: [String: (Data) -> Data] = [:]
    ) throws -> LookPackFixture {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("luts"), withIntermediateDirectories: true)
        var categoryEntries: [[String: Any]] = []
        for category in categories {
            var stops: [[String: Any]] = []
            for look in category.looks {
                let data = lutBytes(look.transform)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let lutFile = "luts/\(look.id).f32"
                try (lutEdits[look.id]?(data) ?? data).write(to: directory.appendingPathComponent(lutFile))
                stops.append([
                    "lookId": look.id,
                    "lookVersion": String(digest.prefix(12)),
                    "name": look.name,
                    "lutFile": lutFile,
                    "lutSha256": digest,
                    "lutSource": look.lutSource,
                    "lightroomHald": NSNull(),
                    "validation": look.validation,
                    "omittedOperators": [String](),
                    "approximatedGlobally": [String]()
                ])
            }
            categoryEntries.append(["id": category.id, "label": category.label, "labelStatus": "provisional", "stops": stops])
        }
        var manifest: [String: Any] = [
            "format": "lightly-look-pack",
            "formatVersion": 1,
            "catalogVersion": 1,
            "lutDimension": 33,
            "lutEncoding": "rgba-float32-red-fastest",
            "categories": categoryEntries
        ]
        manifestEdits(&manifest)
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: directory.appendingPathComponent("manifest.json"))
        return LookPackFixture(directory: directory)
    }

    /// Contract encoding: 33³ RGBA float32, red fastest.
    static func lutBytes(_ transform: (SIMD3<Float>) -> SIMD3<Float>) -> Data {
        let values = LUT3D.lut(dimension: LUT3D.contractDimension, transform).values
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func load() -> LookPackLoadResult { LookPackLoader.load(from: directory) }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

extension LookPackFixture {

    // Fixture transforms: simple, clearly synthetic colour changes.
    static let lift: @Sendable (SIMD3<Float>) -> SIMD3<Float> = { 0.05 + 0.95 * $0 }
    static let warm: @Sendable (SIMD3<Float>) -> SIMD3<Float> = { SIMD3(min($0.x * 1.1 + 0.03, 1.2), $0.y * 1.02, $0.z * 0.85) }
    static let cool: @Sendable (SIMD3<Float>) -> SIMD3<Float> = { SIMD3($0.x * 0.9, $0.y, min($0.z * 1.1 + 0.02, 1.2)) }
    static let fade: @Sendable (SIMD3<Float>) -> SIMD3<Float> = { SIMD3(0.06 + 0.9 * $0.x, 0.06 + 0.9 * $0.y, 0.08 + 0.88 * $0.z) }
    static let mono: @Sendable (SIMD3<Float>) -> SIMD3<Float> = { SIMD3(repeating: 0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z) }

    /// The editor fixture: arbitrary labels (nothing in the app may depend on
    /// them), browse order that is not alphabetical, one long preset name for
    /// large-text layout checks, and every Look an unvalidated approximation
    /// like today's real pack.
    static let editorCategories: [Category] = [
        Category(id: "cat-alpha", label: "Alpha", looks: [
            Look(id: "fixture-lift-000001", name: "Fixture Lift", transform: lift),
            Look(id: "fixture-warm-000002", name: "Fixture Warm (2)", transform: warm)
        ]),
        Category(id: "cat-beta", label: "Beta", looks: [
            Look(id: "fixture-cool-000003", name: "Fixture Cool", transform: cool),
            Look(id: "fixture-long-000004", name: "Fixture Long Preset Name Tone (11)", transform: fade),
            Look(id: "fixture-mono-000005", name: "Fixture Mono", transform: mono)
        ]),
        Category(id: "cat-gamma", label: "Gamma", looks: [
            Look(id: "fixture-fade-000006", name: "Fixture Fade", transform: fade)
        ])
    ]

    /// The editor fixture pack, written once per test process.
    static let editorPack: LookPackFixture = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lookpack-editor-fixture-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        // A failure here is a broken test environment; the loader tests cover
        // the loader itself.
        return try! write(editorCategories, to: directory)
    }()

    static var editorBook: LUTLookBook {
        let result = editorPack.load()
        precondition(result.problem == nil && result.droppedLooks.isEmpty, "editor fixture pack failed to load: \(result)")
        return result.book
    }
}
