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
                             status: String = "approximate", conversion: String = "approximate") -> LookPackFixture.Look {
        LookPackFixture.Look(id: id, name: name, lutSource: lutSource, status: status, conversion: conversion,
                             transform: LookPackFixture.warm)
    }

    /// A Lightroom-HALD Look whose global and full-recipe validations both passed.
    private static func validatedLook(_ id: String, _ name: String) -> LookPackFixture.Look {
        LookPackFixture.Look(id: id, name: name, lutSource: "lightroom-hald", status: "validated", conversion: "complete",
                             globalColourStatus: "validated", fullRecipeStatus: "validated", transform: LookPackFixture.warm)
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
                Self.validatedLook("hald", "From Lightroom"),
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
        XCTAssertEqual(model.provenance.status, "approximate")
        XCTAssertEqual(model.provenance.conversion, "approximate")
        XCTAssertEqual(model.provenance.globalColourStatus, "not-run")
        XCTAssertEqual(model.provenance.fullRecipeStatus, "not-run")
        XCTAssertEqual(hald.provenance.globalColourStatus, "validated")
        XCTAssertEqual(hald.provenance.fullRecipeStatus, "validated")
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
        let result = try write(Self.twoCategories, manifestEdits: { $0["formatVersion"] = 3 }).load()

        XCTAssertEqual(result.problem, .unsupportedFormatVersion(3))
        XCTAssertTrue(result.book.looks.isEmpty)
    }

    /// A format 1 pack (single `validation` flag) is refused as a whole, by its version and with
    /// a reason that says how to fix it, rather than failing on the first missing format 2 field.
    func testFormat1PackIsRejectedWithAClearReason() throws {
        let result = try write(Self.twoCategories, manifestEdits: { manifest in
            manifest["formatVersion"] = 1
            var categories = manifest["categories"] as! [[String: Any]]
            for index in categories.indices {
                categories[index]["stops"] = (categories[index]["stops"] as! [[String: Any]]).map { stop in
                    var old = stop
                    ["conversion", "globalColour", "fullRecipe", "status"].forEach { old[$0] = nil }
                    old["validation"] = "unvalidated"
                    return old
                }
            }
            manifest["categories"] = categories
        }).load()

        XCTAssertEqual(result.problem, .unsupportedFormatVersion(1))
        XCTAssertTrue(result.book.looks.isEmpty)
        let reason = try XCTUnwrap(result.problem).explanation
        XCTAssertTrue(reason.contains("format 1"), reason)
        XCTAssertTrue(reason.contains("build_look_pack.py"), reason)
    }

    /// Format 2 requires the separate validation fields; a stop without them is a broken manifest.
    func testFormat2StopWithoutStatusFieldsIsRejected() throws {
        let result = try write(Self.twoCategories, manifestEdits: { manifest in
            var categories = manifest["categories"] as! [[String: Any]]
            var stops = categories[0]["stops"] as! [[String: Any]]
            stops[0]["globalColour"] = nil
            categories[0]["stops"] = stops
            manifest["categories"] = categories
        }).load()

        guard case .unreadableManifest = result.problem else {
            return XCTFail("expected unreadableManifest, got \(String(describing: result.problem))")
        }
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

    /// The notice follows `status`: anything but "validated" is not a finished conversion.
    func testApproximateNoticeFollowsStatus() throws {
        func book(_ look: LookPackFixture.Look) throws -> LUTLookBook {
            try write([.init(id: "c", label: "C", looks: [look])]).load().book
        }
        let validated = try book(Self.validatedLook("v", "V"))
        let globalOnly = try book(LookPackFixture.Look(
            id: "g", name: "G", lutSource: "lightroom-hald", status: "global-colour-validated", conversion: "approximate",
            globalColourStatus: "validated", fullRecipeStatus: "not-run", transform: LookPackFixture.warm))
        let approximate = try book(Self.look("a", "A"))
        let unknownStatus = try book(Self.look("u", "U", lutSource: "lightroom-hald", status: "some-future-status",
                                               conversion: "complete"))
        let inconsistent = try book(Self.look("i", "I", status: "validated", conversion: "approximate"))

        XCTAssertFalse(validated.offersApproximateLooks, "Only validated Looks need no notice")
        XCTAssertTrue(globalOnly.offersApproximateLooks, "Global colour validated, effects may be missing")
        XCTAssertTrue(approximate.offersApproximateLooks)
        XCTAssertTrue(unknownStatus.offersApproximateLooks, "An unknown status is not a finished conversion")
        XCTAssertTrue(inconsistent.offersApproximateLooks, "Validated with an approximate conversion is not trusted")
        XCTAssertFalse(LUTLookBook.empty.offersApproximateLooks, "No Looks, nothing to qualify")
    }
}
