import XCTest
@testable import Lightly

/// The Look pack loader (spec §4.5): manifest order is browse order, labels
/// are data, and anything that fails validation is refused visibly.
final class LookPackLoaderTests: XCTestCase {

    private var fixtures: [LookPackFixture] = []

    override func tearDown() {
        fixtures.forEach { $0.remove() }
        fixtures = []
    }

    private func write(
        _ categories: [LookPackFixture.Category],
        manifestEdits: (inout [String: Any]) -> Void = { _ in },
        lutEdits: [String: (Data) -> Data] = [:]
    ) throws -> LookPackFixture {
        let fixture = try LookPackFixture.write(categories, manifestEdits: manifestEdits, lutEdits: lutEdits)
        fixtures.append(fixture)
        return fixture
    }

    private static func look(_ id: String, _ name: String, lutSource: String = "lr-model-approximation",
                             validation: String = "unvalidated") -> LookPackFixture.Look {
        LookPackFixture.Look(id: id, name: name, lutSource: lutSource, validation: validation, transform: LookPackFixture.warm)
    }

    private static let twoCategories: [LookPackFixture.Category] = [
        .init(id: "cat-z", label: "Zulu", looks: [look("z-2", "Second Z"), look("z-1", "First Z"), look("z-3", "Third Z")]),
        .init(id: "cat-a", label: "Alpha", looks: [look("a-1", "Only A")])
    ]

    // MARK: - Order and labels

    func testCategoriesAndStopsKeepManifestOrder() throws {
        let result = try write(Self.twoCategories).load()

        XCTAssertNil(result.problem)
        XCTAssertEqual(result.droppedLooks, [])
        XCTAssertEqual(result.book.categories.map(\.id), ["cat-z", "cat-a"], "Not sorted: manifest order is browse order")
        XCTAssertEqual(result.book.stops(inCategory: "cat-z").map(\.id), ["z-2", "z-1", "z-3"])
        XCTAssertEqual(result.book.stops(inCategory: "cat-z").map(\.name), ["Second Z", "First Z", "Third Z"])
    }

    func testArbitraryLabelsFlowThroughVerbatim() throws {
        let result = try write([
            .init(id: "c1", label: "Alpha", looks: [Self.look("l1", "Nordic Tone  (10)")]),
            .init(id: "c2", label: "Beta", looks: [Self.look("l2", "Ünïcødé – Look")])
        ]).load()

        XCTAssertEqual(result.book.categories.map(\.label), ["Alpha", "Beta"])
        XCTAssertEqual(result.book.look(id: "l1")?.name, "Nordic Tone  (10)", "Names are not cleaned up by the app")
        XCTAssertEqual(result.book.look(id: "l2")?.name, "Ünïcødé – Look")
    }

    func testLooksCarryVersionLUTAndProvenance() throws {
        let result = try write([
            .init(id: "c", label: "C", looks: [
                Self.look("hald", "From Lightroom", lutSource: "lightroom-hald", validation: "validated"),
                Self.look("model", "From the model")
            ])
        ]).load()
        let hald = try XCTUnwrap(result.book.look(id: "hald"))
        let model = try XCTUnwrap(result.book.look(id: "model"))

        XCTAssertEqual(hald.version.count, 12)
        XCTAssertEqual(hald.lut, LUT3D.lut(dimension: 33, LookPackFixture.warm), "The LUT is the file's bytes, unchanged")
        XCTAssertFalse(hald.provenance.isApproximate)
        XCTAssertTrue(model.provenance.isApproximate)
        XCTAssertEqual(model.provenance.lutSource, "lr-model-approximation")
    }

    // MARK: - Refused Looks

    func testALookWithTheWrongChecksumIsDroppedAndReported() throws {
        let result = try write(Self.twoCategories, lutEdits: ["z-1": { data in
            var tampered = data
            tampered[100] ^= 0xFF
            return tampered
        }]).load()

        XCTAssertNil(result.problem, "One bad Look does not reject the pack")
        XCTAssertEqual(result.droppedLooks, [DroppedLook(lookID: "z-1", reason: .checksumMismatch)])
        XCTAssertNil(result.book.look(id: "z-1"))
        XCTAssertEqual(result.book.stops(inCategory: "cat-z").map(\.id), ["z-2", "z-3"])
    }

    func testALookWithTheWrongSizeIsDroppedAndReported() throws {
        let result = try write(Self.twoCategories, lutEdits: ["a-1": { $0.prefix(1_000) }]).load()

        XCTAssertEqual(result.droppedLooks, [
            DroppedLook(lookID: "a-1", reason: .wrongLUTSize(expectedBytes: 33 * 33 * 33 * 16, actualBytes: 1_000))
        ])
        XCTAssertEqual(result.book.categories.map(\.id), ["cat-z"], "A category left with no Looks is not offered")
    }

    func testAMissingLUTFileIsDroppedAndReported() throws {
        let fixture = try write(Self.twoCategories)
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("luts/z-3.f32"))

        let result = fixture.load()

        XCTAssertEqual(result.droppedLooks, [DroppedLook(lookID: "z-3", reason: .missingLUTFile("luts/z-3.f32"))])
    }

    func testALUTPathOutsideThePackIsRefused() throws {
        let result = try write(Self.twoCategories, manifestEdits: { manifest in
            var categories = manifest["categories"] as! [[String: Any]]
            var stops = categories[1]["stops"] as! [[String: Any]]
            stops[0]["lutFile"] = "../../etc/passwd"
            categories[1]["stops"] = stops
            manifest["categories"] = categories
        }).load()

        XCTAssertEqual(result.droppedLooks, [DroppedLook(lookID: "a-1", reason: .unsafeLUTPath("../../etc/passwd"))])
    }

    // MARK: - Rejected packs

    func testWrongFormatYieldsAnEmptyBookWithAReason() throws {
        let result = try write(Self.twoCategories, manifestEdits: { $0["format"] = "something-else" }).load()

        XCTAssertEqual(result.problem, .unsupportedFormat("something-else"))
        XCTAssertTrue(result.book.looks.isEmpty)
        XCTAssertTrue(result.book.categories.isEmpty)
    }

    func testNewerFormatVersionIsRejected() throws {
        let result = try write(Self.twoCategories, manifestEdits: { $0["formatVersion"] = 2 }).load()

        XCTAssertEqual(result.problem, .unsupportedFormatVersion(2))
        XCTAssertTrue(result.book.looks.isEmpty)
    }

    func testWrongLUTDimensionYieldsAnEmptyBookWithAReason() throws {
        let result = try write(Self.twoCategories, manifestEdits: { $0["lutDimension"] = 17 }).load()

        XCTAssertEqual(result.problem, .unsupportedLUTDimension(17))
        XCTAssertTrue(result.book.categories.isEmpty)
    }

    func testWrongLUTEncodingIsRejected() throws {
        let result = try write(Self.twoCategories, manifestEdits: { $0["lutEncoding"] = "rgb-uint16" }).load()

        XCTAssertEqual(result.problem, .unsupportedLUTEncoding("rgb-uint16"))
    }

    func testMalformedManifestYieldsAnEmptyBookWithAReason() throws {
        let fixture = try write(Self.twoCategories)
        try Data("{ \"format\": ".utf8).write(to: fixture.directory.appendingPathComponent("manifest.json"))

        let result = fixture.load()

        guard case .unreadableManifest = result.problem else {
            return XCTFail("expected unreadableManifest, got \(String(describing: result.problem))")
        }
        XCTAssertTrue(result.book.looks.isEmpty)
    }

    func testMissingPackYieldsAnEmptyBook() {
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("no-pack-\(UUID().uuidString)")

        let result = LookPackLoader.load(from: nowhere)

        XCTAssertEqual(result.problem, .missing)
        XCTAssertTrue(result.book.categories.isEmpty)
    }

    // MARK: - Honest status

    func testApproximateNoticeLogic() throws {
        let validated = try write([
            .init(id: "c", label: "C", looks: [Self.look("v", "V", lutSource: "lightroom-hald", validation: "validated")])
        ]).load().book
        let unvalidatedHald = try write([
            .init(id: "c", label: "C", looks: [Self.look("h", "H", lutSource: "lightroom-hald", validation: "unvalidated")])
        ]).load().book
        let validatedModel = try write([
            .init(id: "c", label: "C", looks: [Self.look("m", "M", lutSource: "lr-model-approximation", validation: "validated")])
        ]).load().book

        XCTAssertFalse(validated.offersApproximateLooks, "Only validated Lightroom LUTs need no notice")
        XCTAssertTrue(unvalidatedHald.offersApproximateLooks)
        XCTAssertTrue(validatedModel.offersApproximateLooks)
        XCTAssertFalse(LUTLookBook.empty.offersApproximateLooks, "No Looks, nothing to qualify")
    }
}
