import XCTest
@testable import Lightly

/// EditState schema 2 against the shared golden files (shared/fixtures/edit-state/README.md).
///
/// The files are read from the repository, never copied: Android's tests read the same bytes, so
/// a change to the contract shows up on both platforms at once.
final class SavedEditFormatTests: XCTestCase {

    /// `<repo>/shared/fixtures/edit-state`, located from this file the way `LUTGoldenTests` finds
    /// `experiments/` (ios/Tests/LightlyTests/<file> → repository root).
    static let fixtureDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // ios/
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("shared/fixtures/edit-state", isDirectory: true)

    static func fixture(_ name: String) throws -> Data {
        let url = fixtureDirectory.appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw XCTSkip("Shared fixture missing: \(url.path)")
        }
        return data
    }

    // MARK: - Schema 2

    func testV2WithLookDecodesToTheContractValues() throws {
        let state = try SavedEditCodec.decodeState(try Self.fixture("v2-with-look.json"))

        XCTAssertEqual(state.source.assetId, "content://media/picker/0/42")
        XCTAssertEqual(state.source.fingerprint, SavedSourceFingerprint(
            headSha256: String(repeating: "ab", count: 32), byteSize: 1_048_576, pixelWidth: 4032, pixelHeight: 3024))
        XCTAssertEqual(state.source.orientation, 6)
        XCTAssertEqual(state.auto, SavedAutoResult(
            modelId: "ia3dlut", modelVersion: "research-fivek-1", weights: [1.5, -0.25, -0.75],
            guardrail: .endpointV1, strength: 0.75))
        XCTAssertEqual(state.look, SavedLookRef(lookId: "film.portra", lookVersion: "3f2a9c1b7d0e", strength: 0.8))
        XCTAssertEqual(state.revision, 7)
    }

    func testV2WithLookReencodesToIdenticalBytes() throws {
        let bytes = try Self.fixture("v2-with-look.json")
        XCTAssertEqual(String(decoding: SavedEditCodec.encode(try SavedEditCodec.decodeState(bytes)), as: UTF8.self),
                       String(decoding: bytes, as: UTF8.self))
    }

    func testV2NoLookDecodesExplicitNullsAndReencodesToIdenticalBytes() throws {
        let bytes = try Self.fixture("v2-no-look.json")
        let state = try SavedEditCodec.decodeState(bytes)

        XCTAssertNil(state.look)
        XCTAssertNil(state.auto.guardrail)
        XCTAssertEqual(state.revision, 0)
        XCTAssertEqual(String(decoding: SavedEditCodec.encode(state), as: UTF8.self), String(decoding: bytes, as: UTF8.self))
    }

    // MARK: - Schema 1 migration

    /// Migrated, not dropped and not reinterpreted: the result is exactly the migration fixture.
    func testV1IsMigratedToExactlyTheMigratedFixture() throws {
        let migrated = try SavedEditCodec.decodeState(try Self.fixture("v1-numeric-look-version.json"))
        let expected = try Self.fixture("v1-migrated-to-v2.json")

        XCTAssertEqual(migrated.look?.lookVersion, "legacy-v1-2")
        XCTAssertEqual(migrated, try SavedEditCodec.decodeState(expected))
        XCTAssertEqual(String(decoding: SavedEditCodec.encode(migrated), as: UTF8.self), String(decoding: expected, as: UTF8.self))
    }

    func testV1WithAStringLookVersionIsRejected() throws {
        let text = String(decoding: try Self.fixture("v2-with-look.json"), as: UTF8.self)
            .replacingOccurrences(of: "\"schema\":2", with: "\"schema\":1")
        XCTAssertThrowsError(try SavedEditCodec.decodeState(Data(text.utf8))) { error in
            XCTAssertEqual(error as? SavedEditDecodingError, .wrongType("look.lookVersion"))
        }
    }

    // MARK: - Invalid files

    func testUnknownKeyIsRejected() throws {
        XCTAssertThrowsError(try SavedEditCodec.decodeState(try Self.fixture("invalid-unknown-key.json"))) { error in
            XCTAssertEqual(error as? SavedEditDecodingError, .unknownKey("extra"))
        }
    }

    func testFutureSchemaIsRejected() throws {
        XCTAssertThrowsError(try SavedEditCodec.decodeState(try Self.fixture("invalid-future-schema.json"))) { error in
            XCTAssertEqual(error as? SavedEditDecodingError, .unsupportedSchema(3))
        }
    }

    func testOutOfRangeStrengthIsRejected() throws {
        XCTAssertThrowsError(try SavedEditCodec.decodeState(try Self.fixture("invalid-strength-out-of-range.json"))) { error in
            XCTAssertEqual(error as? SavedEditDecodingError, .invalidValue("look.strength"))
        }
    }

    /// Every invalid fixture in the folder is refused, including any added later.
    func testEveryInvalidFixtureIsRejected() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.fixtureDirectory.path)
            .filter { $0.hasPrefix("invalid-") && $0.hasSuffix(".json") }
        XCTAssertGreaterThanOrEqual(names.count, 3)
        for name in names {
            XCTAssertThrowsError(try SavedEditCodec.decodeState(try Self.fixture(name)), name)
        }
    }

    // MARK: - Writing

    func testWriterEscapesOnlyWhatKotlinEscapes() throws {
        var state = try SavedEditCodec.decodeState(try Self.fixture("v2-no-look.json"))
        state.source.assetId = "a/b \"c\" \\ é\n"
        let text = String(decoding: SavedEditCodec.encode(state), as: UTF8.self)

        XCTAssertTrue(text.contains(#""assetId":"a/b \"c\" \\ é\n""#), text)
        XCTAssertEqual(try SavedEditCodec.decodeState(Data(text.utf8)), state)
    }
}
