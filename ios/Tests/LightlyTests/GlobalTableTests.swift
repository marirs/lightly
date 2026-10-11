import Foundation
import XCTest
@testable import Lightly

/// Table looks: presets whose develop.global stage is a precomputed 33³ LUT file in the pack
/// (`globalOverride` source "cube") instead of a recipe bake.
///
/// Most tests use a synthetic table written to a temporary pack directory next to a copy of the
/// shared parity manifest, so they do not depend on the git-ignored built pack. The last test checks
/// the pack actually bundled in the app, and skips when the build carries no table looks.
final class GlobalTableTests: XCTestCase {

    private static let tablePresetID = "look-table-fixture"
    private static let tableRelativePath = "luts/look-table-fixture.f16"

    private var packDirectory: URL!

    override func setUpWithError() throws {
        packDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlobalTableTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: packDirectory.appendingPathComponent("luts"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: packDirectory)
    }

    // MARK: Fixture

    /// Not `EditorTestSupport.model()`, which is main-actor isolated; these tests need no editor session.
    private static func model() throws -> DevelopModel {
        try DevelopModel.load(contractData: Data(contentsOf: DevelopParityTests.fixture("shared/contracts/rendering-v2.json")))
    }

    /// A colour transform that moves every channel differently, so a table applied in the wrong layout
    /// (e.g. blue fastest) or not at all cannot pass.
    private static func fixtureTransform(_ colour: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(0.05 + 0.9 * pow(colour.x, 0.8), 0.5 * colour.y + 0.25 * colour.x, 1 - 0.7 * colour.z)
    }

    /// The fixture table in the pack encoding: 33³ RGB half floats, red fastest, little-endian.
    private static func fixtureTableBytes() -> Data {
        let dimension = GlobalTableRef.supportedDimension
        var data = Data(capacity: dimension * dimension * dimension * 6)
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let grid = SIMD3(Double(red), Double(green), Double(blue)) / Double(dimension - 1)
                    let output = fixtureTransform(grid)
                    for channel in [output.x, output.y, output.z] {
                        withUnsafeBytes(of: Float16(channel).bitPattern.littleEndian) { data.append(contentsOf: $0) }
                    }
                }
            }
        }
        return data
    }

    /// The fixture table decoded back to floats exactly as stored (RGB, red fastest), for expected values.
    private static func storedFixtureRGB() -> [Float] {
        let data = fixtureTableBytes()
        return data.withUnsafeBytes { raw in
            (0..<(data.count / 2)).map { Float(Float16(bitPattern: UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)))) }
        }
    }

    @discardableResult
    private func writeFixtureTable() throws -> String {
        let bytes = Self.fixtureTableBytes()
        try bytes.write(to: packDirectory.appendingPathComponent(Self.tableRelativePath))
        return PresetPackLoader.sha256Hex(bytes)
    }

    private static func emptyRecipeLookVersion(model: DevelopModel, tableSha256: String) throws -> String {
        let recipe = try CanonicalJSON.parse(Data(#"{"global":{},"spatial":{},"finishing":{}}"#.utf8))
        return LookVersion.compute(recipe: recipe, recipeVersion: 1, model: model, globalOverrideSha256: tableSha256)
    }

    private static func tablePresetJSON(lookVersion: String, override: [String: Any]) -> [String: Any] {
        [
            "id": tablePresetID, "displayName": "Table Fixture", "stop": 1, "recipeVersion": 1, "lookVersion": lookVersion,
            "operators": [String](), "recipe": ["global": [String: Any](), "spatial": [String: Any](), "finishing": [String: Any]()],
            "completeness": "complete", "approximated": [Any](), "unsupported": [Any](), "notApplied": [Any](),
            "effects": ["grain": false, "vignette": false], "validation": ["status": "exact-table"],
            "globalOverride": override
        ]
    }

    private static func override(sha256: String) -> [String: Any] {
        ["source": "cube", "lutFile": tableRelativePath, "lutSha256": sha256, "lutDimension": 33,
         "lutEncoding": "rgb-float16-red-fastest", "note": "develop.global = this table alone"]
    }

    /// The shared parity manifest with `preset` appended to its first category.
    private static func manifest(adding preset: [String: Any]) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: DevelopParityTests.fixture(
            "shared/fixtures/look-pack/manifest-parity.json"))) as? [String: Any])
        var categories = try XCTUnwrap(root["categories"] as? [[String: Any]])
        var presets = try XCTUnwrap(categories[0]["presets"] as? [[String: Any]])
        presets.append(preset)
        categories[0]["presets"] = presets
        root["categories"] = categories
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func loadTablePreset(model: DevelopModel) throws -> PresetPack.Preset {
        let sha256 = try writeFixtureTable()
        let lookVersion = try Self.emptyRecipeLookVersion(model: model, tableSha256: sha256)
        let data = try Self.manifest(adding: Self.tablePresetJSON(lookVersion: lookVersion, override: Self.override(sha256: sha256)))
        let result = PresetPackLoader.read(data, model: model, expectedCatalogueSha256: nil, packDirectory: packDirectory)
        XCTAssertNil(result.problem)
        XCTAssertEqual(result.dropped, [])
        return try XCTUnwrap(result.pack.preset(id: Self.tablePresetID))
    }

    private func tableRef(sha256: String) -> GlobalTableRef {
        GlobalTableRef(relativePath: Self.tableRelativePath, fileURL: packDirectory.appendingPathComponent(Self.tableRelativePath),
                       sha256: sha256, dimension: 33)
    }

    // MARK: Parsing

    func testTablePresetParsesWithItsTableAndAnEmptyRecipe() throws {
        let model = try Self.model()
        let preset = try loadTablePreset(model: model)
        let table = try XCTUnwrap(preset.globalTable)
        XCTAssertEqual(table.relativePath, Self.tableRelativePath)
        XCTAssertEqual(table.fileURL, packDirectory.appendingPathComponent(Self.tableRelativePath))
        XCTAssertEqual(table.sha256, PresetPackLoader.sha256Hex(Self.fixtureTableBytes()))
        XCTAssertEqual(table.dimension, 33)
        XCTAssertEqual(preset.recipe, PresetRecipe())
        XCTAssertEqual(preset.validationStatus, "exact-table")
        XCTAssertEqual(preset.lookVersion, try Self.emptyRecipeLookVersion(model: model, tableSha256: table.sha256))
        // The parity pack's own (recipe) presets are untouched.
        let parityData = try Data(contentsOf: DevelopParityTests.fixture("shared/fixtures/look-pack/manifest-parity.json"))
        let parity = PresetPackLoader.read(parityData, model: model, expectedCatalogueSha256: nil).pack
        XCTAssertTrue(parity.categories.flatMap(\.presets).allSatisfy { $0.globalTable == nil })
    }

    func testMalformedOverridesAreDroppedLikeOtherMalformedPresets() throws {
        let model = try Self.model()
        let sha256 = try writeFixtureTable()
        let lookVersion = try Self.emptyRecipeLookVersion(model: model, tableSha256: sha256)
        var cases: [(String, [String: Any])] = []
        func variant(_ label: String, _ edit: (inout [String: Any]) -> Void) {
            var preset = Self.tablePresetJSON(lookVersion: lookVersion, override: Self.override(sha256: sha256))
            edit(&preset)
            cases.append((label, preset))
        }
        func overrideVariant(_ label: String, _ key: String, _ value: Any) {
            variant(label) { preset in
                var override = Self.override(sha256: sha256)
                override[key] = value
                preset["globalOverride"] = override
            }
        }
        overrideVariant("float32 encoding", "lutEncoding", "rgb-float32-red-fastest")
        overrideVariant("17³ table", "lutDimension", 17)
        overrideVariant("HALD source", "source", "hald")
        overrideVariant("path outside luts/", "lutFile", "../manifest.f16")
        overrideVariant("nested path", "lutFile", "luts/sub/look.f16")
        overrideVariant("not a SHA-256", "lutSha256", "abc")
        variant("override not an object") { $0["globalOverride"] = "cube" }
        variant("non-empty global beside a table") { $0["recipe"] = ["global": ["exposure": ["ev": 0.5]]] }

        for (label, preset) in cases {
            let result = PresetPackLoader.read(try Self.manifest(adding: preset), model: model, expectedCatalogueSha256: nil,
                                               packDirectory: packDirectory)
            XCTAssertNil(result.problem, label)
            XCTAssertEqual(result.dropped.map(\.presetID), [Self.tablePresetID], label)
            XCTAssertNil(result.pack.preset(id: Self.tablePresetID), label)
        }

        let withoutDirectory = PresetPackLoader.read(
            try Self.manifest(adding: Self.tablePresetJSON(lookVersion: lookVersion, override: Self.override(sha256: sha256))),
            model: model, expectedCatalogueSha256: nil)
        XCTAssertEqual(withoutDirectory.dropped.map(\.presetID), [Self.tablePresetID], "a table cannot be resolved without its pack")
    }

    // MARK: Loading

    func testTableLoadsAsTheStoredValuesWithOpaqueAlpha() throws {
        let lut = try GlobalTableLoader.load(tableRef(sha256: try writeFixtureTable()))
        let stored = Self.storedFixtureRGB()
        var expectedRGBA: [Float] = []
        for node in 0..<(33 * 33 * 33) {
            expectedRGBA += [stored[node * 3], stored[node * 3 + 1], stored[node * 3 + 2], 1]
        }
        XCTAssertEqual(lut.dimension, 33)
        XCTAssertTrue(lut.values == expectedRGBA, "the table's values in RGBA layout, alpha 1")
    }

    func testTableWithAnotherDigestOrSizeIsRefused() throws {
        let realSha256 = try writeFixtureTable()
        let wrongSha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try GlobalTableLoader.load(tableRef(sha256: wrongSha256))) { error in
            XCTAssertEqual(error as? GlobalTableError,
                           .digestMismatch(path: Self.tableRelativePath, expected: wrongSha256, actual: realSha256))
        }
        try Self.fixtureTableBytes().prefix(1_000).write(to: packDirectory.appendingPathComponent(Self.tableRelativePath))
        XCTAssertThrowsError(try GlobalTableLoader.load(tableRef(sha256: realSha256))) { error in
            XCTAssertEqual(error as? GlobalTableError,
                           .unexpectedSize(path: Self.tableRelativePath, expectedBytes: 33 * 33 * 33 * 6, actualBytes: 1_000))
        }
        try FileManager.default.removeItem(at: packDirectory.appendingPathComponent(Self.tableRelativePath))
        XCTAssertThrowsError(try GlobalTableLoader.load(tableRef(sha256: realSha256)))
    }

    func testCacheRefusesATableWhoseFileWasReplaced() throws {
        let model = try Self.model()
        let preset = try loadTablePreset(model: model)
        var tampered = Self.fixtureTableBytes()
        tampered[0] ^= 0x01
        try tampered.write(to: packDirectory.appendingPathComponent(Self.tableRelativePath))
        let cache = DevelopLUTCache(model: model)
        XCTAssertThrowsError(try cache.lut(for: preset))
        XCTAssertThrowsError(try cache.lut(for: preset, dimension: DevelopLUTCache.dragDimension))
        XCTAssertThrowsError(try DevelopRenderPlan.look(preset, strength: 1, cache: cache))
    }

    // MARK: Resampling

    func testResampleTo17MatchesTrilinearLookupOfThe33TableAtGridPoints() throws {
        let model = try Self.model()
        let preset = try loadTablePreset(model: model)
        let cache = DevelopLUTCache(model: model)
        let full = try cache.lut(for: preset)
        let stored = Self.storedFixtureRGB()
        XCTAssertEqual(full, try GlobalTableLoader.load(try XCTUnwrap(preset.globalTable)))

        for dimension in [DevelopLUTCache.dragDimension, 9] {
            let coarse = try cache.lut(for: preset, dimension: dimension)
            XCTAssertEqual(coarse.dimension, dimension)
            var worst: Double = 0
            for blue in 0..<dimension {
                for green in 0..<dimension {
                    for red in 0..<dimension {
                        let step = 1 / Double(dimension - 1)
                        let grid = SIMD3<Double>(Double(red) * step, Double(green) * step, Double(blue) * step)
                        let expected: SIMD3<Double> = TrilinearLookup.apply(rgb: stored, dimension: 33, to: grid)
                        let node: Int = ((blue * dimension + green) * dimension + red) * 4
                        for channel in 0..<3 {
                            let difference: Double = abs(Double(coarse.values[node + channel]) - expected[channel])
                            worst = max(worst, difference)
                        }
                        XCTAssertEqual(coarse.values[node + 3], 1)
                    }
                }
            }
            XCTAssertLessThanOrEqual(worst, 1e-6, "\(dimension)³ resample")
        }
    }

    // MARK: Rendering

    /// Probe colours as RGBA8 pixels, one per pixel.
    private static let probes: [SIMD3<UInt8>] = [
        SIMD3(0, 0, 0), SIMD3(255, 255, 255), SIMD3(128, 128, 128), SIMD3(200, 40, 90), SIMD3(17, 230, 151), SIMD3(250, 128, 3)
    ]

    private static func probePixels() -> [UInt8] {
        probes.flatMap { [$0.x, $0.y, $0.z, 255] }
    }

    private func render(_ preset: PresetPack.Preset, strength: Double, model: DevelopModel) throws -> (DevelopRenderPlan, [UInt8]) {
        let cache = DevelopLUTCache(model: model)
        let renderer = DevelopFrameRenderer(lutApplier: try MetalLUTRenderer(), model: model)
        let plan = try DevelopRenderPlan.look(preset, strength: strength, cache: cache)
        let output = try renderer.render(plan, pixels: Self.probePixels(), width: Self.probes.count, height: 1)
        return (plan, output)
    }

    func testTablePresetAtFullStrengthRendersTheTablesOutput() throws {
        let model = try Self.model()
        let preset = try loadTablePreset(model: model)
        let (plan, output) = try render(preset, strength: 1, model: model)
        XCTAssertEqual(plan.lookLUT, try GlobalTableLoader.load(try XCTUnwrap(preset.globalTable)))
        XCTAssertFalse(plan.hasPixelStages, "a table look has no spatial or finishing stage")
        let stored = Self.storedFixtureRGB()
        for (index, probe) in Self.probes.enumerated() {
            let colour = SIMD3(Double(probe.x), Double(probe.y), Double(probe.z)) / 255
            let expected = TrilinearLookup.apply(rgb: stored, dimension: 33, to: colour)
            for channel in 0..<3 {
                let expectedByte = Int((min(max(expected[channel], 0), 1) * 255).rounded())
                XCTAssertLessThanOrEqual(abs(Int(output[index * 4 + channel]) - expectedByte), 1,
                                         "probe \(index) channel \(channel)")
            }
        }
    }

    func testTablePresetAtZeroStrengthIsIdentityAndPartialStrengthBlendsLikeRecipeLooks() throws {
        let model = try Self.model()
        let preset = try loadTablePreset(model: model)
        let (zeroPlan, zeroOutput) = try render(preset, strength: 0, model: model)
        XCTAssertTrue(zeroPlan.isIdentity)
        XCTAssertEqual(zeroOutput, Self.probePixels())

        let table = try GlobalTableLoader.load(try XCTUnwrap(preset.globalTable))
        let (halfPlan, _) = try render(preset, strength: 0.5, model: model)
        XCTAssertEqual(halfPlan.lookLUT, table.blendedTowardIdentity(strength: 0.5))
    }

    // MARK: Bundled pack

    /// Every table look in the bundled pack loads with a matching digest, and its published lookVersion is the
    /// one recomputed with `globalOverrideSha256 = lutSha256` (as `DevelopParityTests` does for recipe looks).
    func testBundledTableLooksLoadAndTheirLookVersionsRecompute() throws {
        let model = try DevelopModel.loadBundled()
        let result = PresetPackLoader.loadBundled(model: model)
        let tablePresets = result.pack.categories.flatMap(\.presets).filter { $0.globalTable != nil }
        guard !tablePresets.isEmpty else { throw XCTSkip("the bundled pack carries no table looks") }
        XCTAssertNil(result.problem)
        XCTAssertEqual(result.droppedPresets, [])

        let manifestURL = try XCTUnwrap(Bundle.main.resourceURL)
            .appendingPathComponent(PresetPackLoader.bundleDirectoryName).appendingPathComponent(PresetPackLoader.manifestFileName)
        let manifest = try CanonicalJSON.parse(Data(contentsOf: manifestURL))
        var recipes: [String: CanonicalJSON] = [:]
        for category in manifest["categories"]?.arrayValue ?? [] {
            for preset in category["presets"]?.arrayValue ?? [] {
                if let id = preset["id"]?.stringValue, let recipe = preset["recipe"] { recipes[id] = recipe }
            }
        }
        for preset in tablePresets {
            let table = try XCTUnwrap(preset.globalTable)
            XCTAssertNoThrow(try GlobalTableLoader.load(table), preset.id)
            let recipe = try XCTUnwrap(recipes[preset.id], preset.id)
            XCTAssertEqual(LookVersion.compute(recipe: recipe, recipeVersion: 1, model: model, globalOverrideSha256: table.sha256),
                           preset.lookVersion, preset.id)
        }
        print("TABLES bundled table looks verified: \(tablePresets.count)")
    }
}
