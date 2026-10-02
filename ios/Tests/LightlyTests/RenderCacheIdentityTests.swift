import CoreGraphics
import XCTest
@testable import Lightly

/// Render caches must key on *which* photo and edit they hold, not its size.
///
/// v1 keyed the thumbnail base on source width and the preview base on
/// width×height, so a second photo with the same dimensions was rendered from
/// the first photo's pixels.
final class RenderCacheIdentityTests: XCTestCase {

    private static let thumbnailDimension = 360

    private static func makePhoto(red: Double, green: Double, blue: Double, width: Int, height: Int) -> SelectedPhoto {
        let image = TestFixtures.makeSolidImage(width: width, height: height, red: red, green: green, blue: blue)
        return SelectedPhoto(
            image: image,
            source: .photoLibrary,
            originalData: TestFixtures.makeJPEGData(for: image)
        )
    }

    private static func makeLook(id: String = "film.neutral", exposure: Double = 0) -> LightlyPreset {
        var recipe = DevelopRecipe.unmodified
        recipe.exposure = exposure
        return LightlyPreset(id: id, name: id, category: .film, isIncludedInFreeTier: true, recipe: recipe)
    }

    private func assertRedDominant(_ image: CGImage, file: StaticString = #filePath, line: UInt = #line) {
        let mean = TestFixtures.meanColour(of: image)
        XCTAssertGreaterThan(mean.red, mean.blue + 0.4, "Expected a red render, got \(mean)", file: file, line: line)
    }

    private func assertBlueDominant(_ image: CGImage, file: StaticString = #filePath, line: UInt = #line) {
        let mean = TestFixtures.meanColour(of: image)
        XCTAssertGreaterThan(mean.blue, mean.red + 0.4, "Expected a blue render, got \(mean)", file: file, line: line)
    }

    // MARK: - Fingerprint

    func testSameDimensionsDifferentContentHaveDifferentFingerprints() {
        let red = Self.makePhoto(red: 0.9, green: 0.1, blue: 0.1, width: 300, height: 400)
        let blue = Self.makePhoto(red: 0.1, green: 0.1, blue: 0.9, width: 300, height: 400)

        XCTAssertNotEqual(red.fingerprint, blue.fingerprint)
    }

    func testSameBytesProduceTheSameFingerprintAcrossLoads() {
        let image = TestFixtures.makeSolidImage(red: 0.3, green: 0.6, blue: 0.2)
        let bytes = TestFixtures.makeJPEGData(for: image)

        let first = SelectedPhoto(image: image, source: .photoLibrary, originalData: bytes)
        let second = SelectedPhoto(image: image, source: .camera, originalData: bytes)

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    func testPhotosWithoutEncodedBytesAreFingerprintedByPixels() {
        let red = TestFixtures.makeSolidImage(red: 0.9, green: 0.1, blue: 0.1)
        let blue = TestFixtures.makeSolidImage(red: 0.1, green: 0.1, blue: 0.9)

        XCTAssertNotEqual(
            PhotoFingerprint(encodedData: Data(), image: red),
            PhotoFingerprint(encodedData: Data(), image: blue)
        )
        XCTAssertEqual(
            PhotoFingerprint(encodedData: Data(), image: red),
            PhotoFingerprint(encodedData: Data(), image: red)
        )
    }

    // MARK: - Thumbnails

    /// Below the thumbnail size, v1 cached the source itself under its width.
    func testSecondPhotoWithSameSmallDimensionsGetsItsOwnThumbnail() async throws {
        try await assertDistinctThumbnails(width: 300, height: 400)
    }

    /// Above the thumbnail size, v1 cached the downsample under the width.
    func testSecondPhotoWithSameLargeDimensionsGetsItsOwnThumbnail() async throws {
        try await assertDistinctThumbnails(width: 600, height: 800)
    }

    private func assertDistinctThumbnails(width: Int, height: Int) async throws {
        let renderer = CoreImageThumbnailRenderer()
        let look = Self.makeLook()
        let red = Self.makePhoto(red: 0.9, green: 0.1, blue: 0.1, width: width, height: height)
        let blue = Self.makePhoto(red: 0.1, green: 0.1, blue: 0.9, width: width, height: height)

        let redThumbnail = try await renderer.thumbnail(
            for: look, from: LookThumbnailSource(photo: red, editBase: .unmodified),
            maximumDimension: Self.thumbnailDimension
        )
        let blueThumbnail = try await renderer.thumbnail(
            for: look, from: LookThumbnailSource(photo: blue, editBase: .unmodified),
            maximumDimension: Self.thumbnailDimension
        )

        assertRedDominant(redThumbnail)
        assertBlueDominant(blueThumbnail)
        let misses = await renderer.cacheMisses
        XCTAssertEqual(misses, 2)
    }

    func testSamePhotoAndLookIsACacheHit() async throws {
        let renderer = CoreImageThumbnailRenderer()
        let look = Self.makeLook()
        let photo = Self.makePhoto(red: 0.9, green: 0.1, blue: 0.1, width: 600, height: 800)
        let source = LookThumbnailSource(photo: photo, editBase: .unmodified)

        let first = try await renderer.thumbnail(for: look, from: source, maximumDimension: Self.thumbnailDimension)
        let second = try await renderer.thumbnail(for: look, from: source, maximumDimension: Self.thumbnailDimension)

        XCTAssertTrue(first === second, "A repeat request should return the cached render")
        let hits = await renderer.cacheHits
        let misses = await renderer.cacheMisses
        XCTAssertEqual(hits, 1)
        XCTAssertEqual(misses, 1)
    }

    /// The same bytes loaded twice (new `SelectedPhoto.id`) still hit.
    func testReloadedPhotoWithSameBytesIsACacheHit() async throws {
        let renderer = CoreImageThumbnailRenderer()
        let look = Self.makeLook()
        let image = TestFixtures.makeSolidImage(red: 0.2, green: 0.7, blue: 0.2)
        let bytes = TestFixtures.makeJPEGData(for: image)
        let firstLoad = SelectedPhoto(image: image, source: .photoLibrary, originalData: bytes)
        let secondLoad = SelectedPhoto(image: image, source: .photoLibrary, originalData: bytes)

        _ = try await renderer.thumbnail(
            for: look, from: LookThumbnailSource(photo: firstLoad, editBase: .unmodified), maximumDimension: 360
        )
        _ = try await renderer.thumbnail(
            for: look, from: LookThumbnailSource(photo: secondLoad, editBase: .unmodified), maximumDimension: 360
        )

        let hits = await renderer.cacheHits
        XCTAssertEqual(hits, 1)
    }

    func testDifferentEditBaseIsADifferentEntryWithDifferentPixels() async throws {
        let renderer = CoreImageThumbnailRenderer()
        let look = Self.makeLook()
        let photo = Self.makePhoto(red: 0.4, green: 0.4, blue: 0.4, width: 300, height: 400)
        var brighter = DevelopRecipe.unmodified
        brighter.exposure = 1

        let onOriginal = try await renderer.thumbnail(
            for: look, from: LookThumbnailSource(photo: photo, editBase: .unmodified), maximumDimension: 360
        )
        let onEdit = try await renderer.thumbnail(
            for: look, from: LookThumbnailSource(photo: photo, editBase: brighter), maximumDimension: 360
        )

        let misses = await renderer.cacheMisses
        XCTAssertEqual(misses, 2)
        XCTAssertGreaterThan(
            TestFixtures.meanColour(of: onEdit).green,
            TestFixtures.meanColour(of: onOriginal).green + 0.05,
            "The edit base must be rendered under the Look, not ignored"
        )
    }

    /// Presets carry no version; an edited recipe under the same ID must miss.
    func testSameLookIDWithChangedRecipeIsADifferentEntry() async throws {
        let renderer = CoreImageThumbnailRenderer()
        let photo = Self.makePhoto(red: 0.4, green: 0.4, blue: 0.4, width: 300, height: 400)
        let source = LookThumbnailSource(photo: photo, editBase: .unmodified)

        let before = try await renderer.thumbnail(
            for: Self.makeLook(id: "film.x", exposure: 0), from: source, maximumDimension: 360
        )
        let after = try await renderer.thumbnail(
            for: Self.makeLook(id: "film.x", exposure: 1), from: source, maximumDimension: 360
        )

        XCTAssertFalse(before === after)
        XCTAssertGreaterThan(
            TestFixtures.meanColour(of: after).green,
            TestFixtures.meanColour(of: before).green + 0.05
        )
    }

    func testDifferentOutputSizeIsADifferentEntry() async throws {
        let renderer = CoreImageThumbnailRenderer()
        let photo = Self.makePhoto(red: 0.4, green: 0.4, blue: 0.4, width: 600, height: 800)
        let source = LookThumbnailSource(photo: photo, editBase: .unmodified)

        let small = try await renderer.thumbnail(for: Self.makeLook(), from: source, maximumDimension: 120)
        let large = try await renderer.thumbnail(for: Self.makeLook(), from: source, maximumDimension: 360)

        XCTAssertEqual(max(small.width, small.height), 120)
        XCTAssertEqual(max(large.width, large.height), 360)
        let hits = await renderer.cacheHits
        XCTAssertEqual(hits, 0)
    }

    // MARK: - Preview

    func testPreviewRendererDoesNotReuseAnotherPhotosBase() async throws {
        let renderer = PreviewRenderer(maximumPreviewDimension: 200)
        let red = Self.makePhoto(red: 0.9, green: 0.1, blue: 0.1, width: 300, height: 400)
        let blue = Self.makePhoto(red: 0.1, green: 0.1, blue: 0.9, width: 300, height: 400)

        let redPreview = try await renderer.renderPreview(red.image, identity: red.fingerprint, with: .unmodified)
        let bluePreview = try await renderer.renderPreview(blue.image, identity: blue.fingerprint, with: .unmodified)

        assertRedDominant(redPreview)
        assertBlueDominant(bluePreview)
    }

    // MARK: - Bounded cache

    func testBoundedCacheEvictsTheLeastRecentlyUsedEntry() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        _ = cache.value(for: "a")
        cache.insert(3, for: "c")

        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "c"), 3)
    }
}
