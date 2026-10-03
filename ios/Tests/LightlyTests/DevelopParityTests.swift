import Foundation
import XCTest
@testable import Lightly

/// Recipe → LUT parity against the shared golden vectors (`shared/fixtures/look-pack/`), with the
/// tolerances `golden.json` publishes (docs/v1/preset-pack.md §Parity):
/// - every 17³ bake node within `lutNode` (1e-3) of the golden float16 LUT;
/// - develop.global on each probe within `probeDirect` (5e-4);
/// - each probe through a 33³ bake and trilinear lookup within `probeViaLut33` (1e-3);
/// - `lookVersion` recomputed from the recipe equal to the published one;
/// - the portable random vectors exact, the Gaussian field within 1e-6.
///
/// The fixtures are read from the repository (they are shared with Android), never copied.
final class DevelopParityTests: XCTestCase {

    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // ios/
        .deletingLastPathComponent()

    static func fixture(_ path: String) -> URL { repositoryRoot.appendingPathComponent(path) }

    private struct Golden: Decodable {
        struct Tolerances: Decodable { let lutNode: Double; let probeDirect: Double; let probeViaLut33: Double }
        struct Case: Decodable {
            let presetId: String
            let category: String
            let displayName: String
            let lookVersion: String
            let lutFile: String
            let probesDirect: [[Double]]
            let probesViaLut33: [[Double]]
        }
        struct PortableRandom: Decodable {
            struct Field: Decodable { let seed: UInt32; let layer: UInt32; let rows: Int; let cols: Int; let values: [[Double]]; let tolerance: Double }
            let lowbias32: [[UInt64]]
            let gaussianField: Field
        }
        let probes: [[Double]]
        let tolerances: Tolerances
        let cases: [Case]
        let portableRandom: PortableRandom
    }

    private static func loadModel() throws -> DevelopModel {
        try DevelopModel.load(contractData: Data(contentsOf: fixture("shared/contracts/rendering-v2.json")))
    }

    private static func loadGolden() throws -> Golden {
        try JSONDecoder().decode(Golden.self, from: Data(contentsOf: fixture("shared/fixtures/look-pack/golden.json")))
    }

    private static func loadParityPack(model: DevelopModel) throws -> PresetPack {
        let data = try Data(contentsOf: fixture("shared/fixtures/look-pack/manifest-parity.json"))
        let result = PresetPackLoader.read(data, model: model, expectedCatalogueSha256: nil)
        XCTAssertNil(result.problem)
        XCTAssertEqual(result.dropped, [])
        return result.pack
    }

    /// float16 little-endian RGB triples.
    private static func float16Triples(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            (0..<(data.count / 2)).map { index in
                Float(Float16(bitPattern: raw.load(fromByteOffset: index * 2, as: UInt16.self).littleEndian))
            }
        }
    }

    func testContractConstantsDigestMatches() throws {
        let model = try Self.loadModel()
        XCTAssertEqual(model.constantsSha256, "c85518517aa68396480e3d01bf53ae2131d3bc9779f61d6c5813e98e1a6402df")
        XCTAssertEqual(model.id, "lightly-develop-model")
        XCTAssertEqual(model.version, 1)
    }

    func testEveryParityCaseBakesWithinTolerance() throws {
        let model = try Self.loadModel()
        let golden = try Self.loadGolden()
        let pack = try Self.loadParityPack(model: model)
        XCTAssertEqual(golden.cases.count, 40)

        var worstNode = 0.0, worstDirect = 0.0, worstVia33 = 0.0
        for testCase in golden.cases {
            let preset = try XCTUnwrap(pack.preset(id: testCase.presetId), testCase.presetId)
            let program = DevelopGlobalProgram(recipe: preset.recipe.global, model: model)

            let expected = Self.float16Triples(try Data(contentsOf: Self.fixture("shared/fixtures/look-pack/\(testCase.lutFile)")))
            let baked17 = program.bakeRGB(dimension: 17)
            XCTAssertEqual(baked17.count, expected.count)
            let node = zip(baked17, expected).map { abs(Double($0) - Double($1)) }.max() ?? .infinity
            XCTAssertLessThanOrEqual(node, golden.tolerances.lutNode, "17³ \(testCase.presetId) \(testCase.displayName)")
            worstNode = max(worstNode, node)

            let baked33 = program.bakeRGB(dimension: 33)
            for (index, probe) in golden.probes.enumerated() {
                let colour = SIMD3(probe[0], probe[1], probe[2])
                let direct = program.evaluate(colour)
                let expectedDirect = testCase.probesDirect[index]
                let directError = (0..<3).map { abs(direct[$0] - expectedDirect[$0]) }.max()!
                XCTAssertLessThanOrEqual(directError, golden.tolerances.probeDirect, "direct \(testCase.presetId) probe \(index)")
                worstDirect = max(worstDirect, directError)

                let via = TrilinearLookup.apply(rgb: baked33, dimension: 33, to: colour)
                let expectedVia = testCase.probesViaLut33[index]
                let viaError = (0..<3).map { abs(via[$0] - expectedVia[$0]) }.max()!
                XCTAssertLessThanOrEqual(viaError, golden.tolerances.probeViaLut33, "33³ \(testCase.presetId) probe \(index)")
                worstVia33 = max(worstVia33, viaError)
            }
        }
        // Evidence for docs/v1/slice2-ios.md.
        print(String(format: "PARITY worst 17³ node %.3g, direct probe %.3g, via 33³ %.3g over %d cases",
                     worstNode, worstDirect, worstVia33, golden.cases.count))
    }

    func testLookVersionIsRecomputedExactly() throws {
        let model = try Self.loadModel()
        let golden = try Self.loadGolden()
        let manifest = try CanonicalJSON.parse(Data(contentsOf: Self.fixture("shared/fixtures/look-pack/manifest-parity.json")))
        var recipes: [String: CanonicalJSON] = [:]
        for category in manifest["categories"]?.arrayValue ?? [] {
            for preset in category["presets"]?.arrayValue ?? [] {
                if let id = preset["id"]?.stringValue, let recipe = preset["recipe"] { recipes[id] = recipe }
            }
        }
        for testCase in golden.cases {
            let recipe = try XCTUnwrap(recipes[testCase.presetId])
            XCTAssertEqual(LookVersion.compute(recipe: recipe, recipeVersion: 1, model: model, globalOverrideSha256: nil),
                           testCase.lookVersion, testCase.presetId)
        }
    }

    func testPortableRandomVectors() throws {
        let golden = try Self.loadGolden()
        for pair in golden.portableRandom.lowbias32 {
            XCTAssertEqual(UInt64(PortableRandom.lowbias32(UInt32(pair[0]))), pair[1], "lowbias32(\(pair[0]))")
        }
        let field = golden.portableRandom.gaussianField
        let values = PortableRandom.gaussianField(seed: field.seed, layer: field.layer, rows: field.rows, cols: field.cols)
        for i in 0..<field.rows {
            for j in 0..<field.cols {
                XCTAssertEqual(values[i * field.cols + j], field.values[i][j], accuracy: field.tolerance)
            }
        }
    }

    /// The device bake into the Metal LUT path's format, and the GPU applying it, agree with the
    /// golden 33³ probes (the GPU path reads 8-bit input, so probes are quantised first and the
    /// output tolerance includes one 8-bit step).
    func testMetalAppliesTheBakedLUTWithinTolerance() throws {
        let model = try Self.loadModel()
        let golden = try Self.loadGolden()
        let pack = try Self.loadParityPack(model: model)
        let renderer = try MetalLUTRenderer()
        for testCase in golden.cases.prefix(8) {
            let preset = try XCTUnwrap(pack.preset(id: testCase.presetId))
            let program = DevelopGlobalProgram(recipe: preset.recipe.global, model: model)
            let lut = program.bakeLUT()
            let rgb33 = program.bakeRGB(dimension: 33)
            let pixels = golden.probes.flatMap { probe -> [UInt8] in
                probe.map { UInt8((min(max($0, 0), 1) * 255).rounded()) } + [255]
            }
            let output = try renderer.applyUnencoded([lut], toRGBA8: pixels, width: golden.probes.count, height: 1)
            for (index, probe) in golden.probes.enumerated() {
                let quantised = SIMD3(probe.map { (min(max($0, 0), 1) * 255).rounded() / 255 })
                let expected = TrilinearLookup.apply(rgb: rgb33, dimension: 33, to: quantised)
                let got = output[index]
                for c in 0..<3 {
                    XCTAssertEqual(Double(got[c]), expected[c], accuracy: 1e-4, "\(testCase.presetId) probe \(index)")
                }
            }
        }
    }

    func testRecipeReaderRejectsUnknownOperatorsAndMissingParameters() {
        XCTAssertThrowsError(try PresetRecipe(json: ["global": ["sparkle": ["amount": 1]]]))
        XCTAssertThrowsError(try PresetRecipe(json: ["global": ["exposure": [:]]]))
        XCTAssertThrowsError(try PresetRecipe(json: ["global": ["exposure": ["ev": 1, "extra": 2]]]))
        XCTAssertThrowsError(try PresetRecipe(json: ["local": [:]]))
        XCTAssertNoThrow(try PresetRecipe(json: ["global": ["exposure": ["ev": 0.5]]]))
    }

    func testLoaderRefusesOtherFormatsAndModels() throws {
        let model = try Self.loadModel()
        func manifest(_ edit: (inout [String: Any]) -> Void) throws -> Data {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixture(
                "shared/fixtures/look-pack/manifest-parity.json"))) as? [String: Any])
            edit(&root)
            return try JSONSerialization.data(withJSONObject: root)
        }
        XCTAssertEqual(PresetPackLoader.read(try manifest { $0["formatVersion"] = 2 }, model: model, expectedCatalogueSha256: nil).problem,
                       .unsupportedFormatVersion(2))
        XCTAssertEqual(PresetPackLoader.read(try manifest { $0["format"] = "other" }, model: model, expectedCatalogueSha256: nil).problem,
                       .unsupportedFormat("other"))
        let mismatch = PresetPackLoader.read(try manifest {
            var developModel = $0["developModel"] as? [String: Any] ?? [:]
            developModel["constantsSha256"] = "0000"
            $0["developModel"] = developModel
        }, model: model, expectedCatalogueSha256: nil)
        XCTAssertEqual(mismatch.problem, .developModelMismatch(pack: "0000", app: model.constantsSha256))
        XCTAssertTrue(mismatch.pack.isEmpty)
        let catalogue = PresetPackLoader.read(try manifest { _ in }, model: model, expectedCatalogueSha256: "ffff")
        XCTAssertNotNil(catalogue.problem)
    }
}
