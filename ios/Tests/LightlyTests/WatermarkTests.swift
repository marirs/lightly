import CoreGraphics
import CoreText
import CryptoKit
import ImageIO
import XCTest
@testable import Lightly

/// Rendering-v2 stage 12 (watermark) geometry and rendering, against the revision-2 contract and
/// the approved prototype's `watermarkHTML`.
final class WatermarkStageTests: XCTestCase {

    private func watermark(_ type: EditRecipe.Watermark.Kind = .text, position: Int = 8, offset: EditRecipe.Point? = nil,
                           size: Double = 34, opacity: Double = 100, colour: String = "#FFFFFF",
                           placement: EditRecipe.Watermark.Placement = .photo) -> EditRecipe.Watermark {
        .init(type: type, signature: nil, text: type == .text ? .init(text: "A. Rivera", font: .inter) : nil,
              logo: type == .logo ? .bundled(id: WatermarkStage.sampleLogoID) : nil,
              placement: placement, position: position, offset: offset, size: size, opacity: opacity, colour: colour)
    }

    // MARK: On-screen size (PROVISIONAL approach to defect W1, pending the owner)

    /// The prototype's layouts for wm-text / wm-signature (sunset): iPhone 17 portrait shows the
    /// photo 402 × 268.1 pt, iPad Pro 13" landscape 892 × 594.8 pt. Whatever the photo's pixels,
    /// the watermark's displayed size is 18 / 26 / 30 pt × size/34.
    func testTheDisplayedSizeIsThePrototypesPointsOnEveryLayout() {
        for displayShort in [268.1, 594.8] {
            for imageShort in [426.0, 1067.0, 4000.0] {
                let ppp = WatermarkStage.pixelsPerPoint(imageShortEdgePixels: imageShort, displayShortEdgePoints: displayShort)
                for (kind, points) in [(WatermarkStage.Kind.text, 18.0), (.signature, 26.0), (.logo, 30.0)] {
                    for size in [10.0, 34.0, 80.0] {
                        let pixels = WatermarkStage.mainSize(kind, size: size, pixelsPerPoint: ppp)
                        // Displayed: pixels × (displayed points per pixel).
                        XCTAssertEqual(pixels * displayShort / imageShort, points * size / 34, accuracy: 1e-9)
                    }
                }
            }
        }
    }

    func testBeforeLayoutTheFallbackIsTheMedianPhone() {
        XCTAssertEqual(WatermarkStage.pixelsPerPoint(imageShortEdgePixels: 1000, displayShortEdgePoints: nil), 1000 / 289.2, accuracy: 1e-9)
    }

    // MARK: Anchors and alignment

    func testTheNineAnchorsSitAt6_50_94PercentWithThePrototypesAlignment() {
        let image = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let extent = WatermarkStage.Extent(width: 100, above: 30, below: 10)
        let canvas = CGSize(width: 1000, height: 600)
        // px = 0.06225 · 600 / 18 = 2.075; the strut needs 13 px = 26.975 above, 2 px = 4.15 below.
        for position in 0..<9 {
            let layout = WatermarkStage.layout(watermark(position: position), kind: .text, extent: extent, canvasSize: canvas,
                                               imageRect: image, border: .none, pixelsPerPoint: WatermarkStage.pixelsPerPoint(imageShortEdgePixels: Double(min(image.width, image.height)), displayShortEdgePoints: nil))
            let ax = [60.0, 500, 940][position % 3], ay = [36.0, 300, 564][position / 3]
            let expectedX = [ax, ax - 50, ax - 100][position % 3]
            let expectedTop = [ay, ay - 20, ay - 40][position / 3]
            XCTAssertEqual(Double(layout.box.minX), expectedX, accuracy: 1e-9, "position \(position) x")
            XCTAssertEqual(Double(layout.box.minY), expectedTop, accuracy: 1e-9, "position \(position) y")
            XCTAssertEqual(layout.box.height, 40, accuracy: 1e-9)
            XCTAssertFalse(layout.onBorder)
        }
    }

    func testTheStrutKeepsAnSVGTwoCSSPixelsAboveTheBoxBottom() {
        let image = CGRect(x: 0, y: 0, width: 900, height: 600)
        let px = WatermarkStage.pixelsPerPoint(imageShortEdgePixels: 600, displayShortEdgePoints: nil)
        let height = WatermarkStage.mainSize(.signature, size: 34, pixelsPerPoint: px)
        let layout = WatermarkStage.layout(watermark(.signature), kind: .signature,
                                           extent: .init(width: 3.4 * height, above: height, below: 0),
                                           canvasSize: image.size, imageRect: image, border: .none, pixelsPerPoint: WatermarkStage.pixelsPerPoint(imageShortEdgePixels: Double(min(image.width, image.height)), displayShortEdgePoints: nil))
        XCTAssertEqual(Double(layout.box.maxY), 0.94 * 600, accuracy: 1e-9)
        XCTAssertEqual(Double(layout.box.maxY) - layout.baseline, 2 * px, accuracy: 1e-9, "SVG bottom 2 CSS px above the box")
        XCTAssertEqual(layout.box.height, height + 2 * px, accuracy: 1e-9, "26 px signature → 28 px box, as measured")
    }

    func testADraggedOffsetOverridesThePositionAndUsesThe30_70Rule() {
        let image = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let extent = WatermarkStage.Extent(width: 100, above: 40, below: 10)
        func box(_ x: Double, _ y: Double) -> CGRect {
            WatermarkStage.layout(watermark(position: 8, offset: .init(x: x, y: y)), kind: .text, extent: extent,
                                  canvasSize: image.size, imageRect: image, border: .none, pixelsPerPoint: WatermarkStage.pixelsPerPoint(imageShortEdgePixels: Double(min(image.width, image.height)), displayShortEdgePoints: nil)).box
        }
        XCTAssertEqual(box(0.5, 0.5).midX, 500, accuracy: 1e-9)
        XCTAssertEqual(box(0.5, 0.5).midY, 500, accuracy: 1e-9)
        XCTAssertEqual(box(0.2, 0.2).minX, 200, accuracy: 1e-9)
        XCTAssertEqual(box(0.2, 0.2).minY, 200, accuracy: 1e-9)
        XCTAssertEqual(box(0.8, 0.8).maxX, 800, accuracy: 1e-9)
        XCTAssertEqual(box(0.8, 0.8).maxY, 800, accuracy: 1e-9)
    }

    func testAnchorsAreRelativeToThePhotoInsideTheBorder() {
        let border = EditRecipe.Border(type: .solid, colour: "#FFFFFF", width: 10, spacing: 3, mat: "#F4F1EC")
        let placement = BorderStage.placement(border, frameWidth: 1000, frameHeight: 500)
        let layout = WatermarkStage.layout(watermark(position: 0), kind: .text, extent: .init(width: 50, above: 40, below: 10),
                                           canvasSize: CGSize(width: placement.canvasWidth, height: placement.canvasHeight),
                                           imageRect: placement.imageRect, border: .solid, pixelsPerPoint: WatermarkStage.pixelsPerPoint(imageShortEdgePixels: Double(min(placement.imageRect.width, placement.imageRect.height)), displayShortEdgePoints: nil))
        XCTAssertEqual(layout.box.minX, 100 + 60, accuracy: 1e-9)
        XCTAssertEqual(layout.box.minY, 100 + 30, accuracy: 1e-9)
    }

    // MARK: On a border

    func testOnABorderTheWatermarkIsCentredOnePercentAboveTheCanvasBottom() {
        let canvas = CGSize(width: 1200, height: 900)
        let layout = WatermarkStage.layout(watermark(colour: "#C9A27E", placement: .border), kind: .text,
                                           extent: .init(width: 200, above: 60, below: 20), canvasSize: canvas,
                                           imageRect: CGRect(x: 100, y: 100, width: 1000, height: 700), border: .solid, pixelsPerPoint: 1)
        XCTAssertTrue(layout.onBorder)
        XCTAssertEqual(layout.box.midX, 600, accuracy: 1e-9)
        XCTAssertEqual(layout.box.maxY, 900 * 0.99, accuracy: 1e-9)
        XCTAssertEqual(layout.ink, "#C9A27E")
    }

    func testOnAPolaroidMarginItIsSixPercentUpInDarkInk() {
        let canvas = CGSize(width: 1110, height: 1095)
        let layout = WatermarkStage.layout(watermark(.signature, placement: .border), kind: .signature,
                                           extent: .init(width: 300, above: 90, below: 0), canvasSize: canvas,
                                           imageRect: CGRect(x: 55, y: 55, width: 1000, height: 800), border: .polaroid, pixelsPerPoint: 1)
        XCTAssertEqual(layout.box.maxY, 1095 * 0.94, accuracy: 1e-9)
        XCTAssertEqual(layout.ink, "#222222")
    }

    func testBorderPlacementWithoutABorderStaysOnThePhoto() {
        let image = CGRect(x: 0, y: 0, width: 800, height: 600)
        let layout = WatermarkStage.layout(watermark(placement: .border), kind: .text, extent: .init(width: 100, above: 40, below: 10),
                                           canvasSize: image.size, imageRect: image, border: .none, pixelsPerPoint: WatermarkStage.pixelsPerPoint(imageShortEdgePixels: Double(min(image.width, image.height)), displayShortEdgePoints: nil))
        XCTAssertFalse(layout.onBorder)
        XCTAssertEqual(layout.box.maxX, 0.94 * 800, accuracy: 1e-9)
    }

    // MARK: Rendering

    private func canvas(_ width: Int, _ height: Int, value: UInt8 = 0) -> [UInt8] {
        var pixels = [UInt8](repeating: value, count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        return pixels
    }

    private func changedBounds(_ a: [UInt8], _ b: [UInt8], width: Int) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for i in stride(from: 0, to: a.count, by: 4) where a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] {
            let p = i / 4, x = p % width, y = p / width
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func testTextIsDrawnInsideItsBoxAtTheBottomRight() throws {
        let width = 1200, height = 800
        let before = canvas(width, height)
        var pixels = before
        let w = watermark()
        let content = WatermarkStage.Content.text("A. Rivera", .inter)
        let image = CGRect(x: 0, y: 0, width: width, height: height)
        WatermarkStage.apply(w, content: content, pixels: &pixels, canvasWidth: width, canvasHeight: height, imageRect: image, border: .none, displayShortEdgePoints: nil)
        let changed = try XCTUnwrap(changedBounds(before, pixels, width: width))
        let layout = WatermarkStage.layout(w, kind: .text, extent: WatermarkStage.extent(of: content, size: 34, pixelsPerPoint: 800 / 289.2),
                                           canvasSize: image.size, imageRect: image, border: .none, pixelsPerPoint: WatermarkStage.pixelsPerPoint(imageShortEdgePixels: Double(min(image.width, image.height)), displayShortEdgePoints: nil))
        // The glyphs (and their 1 px / 2 px shadow) stay within the box, give or take the shadow.
        let slack = 4 * layout.cssPixel
        XCTAssertGreaterThanOrEqual(Double(changed.minX), Double(layout.box.minX) - slack)
        XCTAssertLessThanOrEqual(Double(changed.maxX), Double(layout.box.maxX) + slack)
        XCTAssertLessThanOrEqual(Double(changed.maxY), Double(layout.box.maxY) + slack)
        XCTAssertEqual(Double(changed.maxX), 0.94 * 1200, accuracy: slack, "right edge at the 94 % anchor")
        // Inter's cap height is about 0.73 em: the ink is roughly that tall.
        XCTAssertEqual(Double(changed.height), 0.73 * WatermarkStage.mainSize(.text, size: 34, pixelsPerPoint: 800 / 289.2), accuracy: 6)
    }

    func testZeroOpacityOrNoContentDrawsNothing() {
        let before = canvas(300, 200)
        var pixels = before
        WatermarkStage.apply(watermark(opacity: 0), content: .text("A", .inter), pixels: &pixels, canvasWidth: 300, canvasHeight: 200,
                             imageRect: CGRect(x: 0, y: 0, width: 300, height: 200), border: .none, displayShortEdgePoints: nil)
        XCTAssertEqual(pixels, before)
        WatermarkStage.apply(watermark(.signature), content: nil, pixels: &pixels, canvasWidth: 300, canvasHeight: 200,
                             imageRect: CGRect(x: 0, y: 0, width: 300, height: 200), border: .none, displayShortEdgePoints: nil)
        XCTAssertEqual(pixels, before, "a missing signature renders without it")
    }

    func testOpacityScalesTheInk() {
        func peak(_ opacity: Double) -> UInt8 {
            var pixels = canvas(600, 400)
            WatermarkStage.apply(watermark(.logo, opacity: opacity), content: .sampleLogo, pixels: &pixels, canvasWidth: 600, canvasHeight: 400,
                                 imageRect: CGRect(x: 0, y: 0, width: 600, height: 400), border: .none, displayShortEdgePoints: nil)
            return stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }.max() ?? 0
        }
        XCTAssertEqual(Double(peak(100)), 255, accuracy: 2)
        XCTAssertEqual(Double(peak(50)), 128, accuracy: 6)
    }

    func testADrawnSignatureOnAPolaroidMarginIsDarkInk() throws {
        let border = EditRecipe.Border(type: .polaroid, colour: "#FFFFFF", width: 4, spacing: 3, mat: "#F4F1EC")
        let frame = [UInt8](repeating: 90, count: 400 * 500 * 4)
        var out = BorderStage.apply(border, pixels: frame, width: 400, height: 500)
        let before = out.pixels
        let placement = BorderStage.placement(border, frameWidth: 400, frameHeight: 500)
        var w = watermark(.signature, colour: "#FFFFFF", placement: .border)
        w.signature = .init(signatureId: "x", signatureVersion: "000000000000", kind: .drawn)
        WatermarkStage.apply(w, content: .drawnSignature(.prototypeSample), pixels: &out.pixels, canvasWidth: out.width,
                             canvasHeight: out.height, imageRect: placement.imageRect, border: .polaroid, displayShortEdgePoints: nil)
        let changed = try XCTUnwrap(changedBounds(before, out.pixels, width: out.width))
        XCTAssertGreaterThan(Double(changed.minY), Double(placement.imageRect.maxY), "in the bottom margin, below the photo")
        // The box is centred; the prototype's ink starts 6 of 170 units into it (and ends well
        // short of its right edge, so the ink itself sits left of centre, as in bd-polaroid).
        let boxWidth = WatermarkStage.mainSize(.signature, size: 34, pixelsPerPoint: 400 / 289.2) * 170 / 50
        XCTAssertEqual(Double(changed.minX), Double(out.width) / 2 - boxWidth / 2 + boxWidth * 6 / 170, accuracy: 3, "centred box")
        let darkest = stride(from: 0, to: out.pixels.count, by: 4).map { Int(out.pixels[$0]) }.min() ?? 255
        XCTAssertEqual(darkest, 0x22, accuracy: 3, "#222222 ink, not the white watermark colour")
    }

    func testSampleSignatureMatchesThePrototypePath() {
        let sample = DrawnSignature.prototypeSample
        XCTAssertEqual(sample.viewBox, .init(x: 0, y: 0, width: 170, height: 50))
        let points = sample.strokes.flatMap { $0 }
        XCTAssertEqual(points.first, .init(x: 6, y: 38))
        XCTAssertEqual(points.last!.x, 109, accuracy: 1e-9, "M6 38 plus the nine relative ends")
        XCTAssertEqual(points.last!.y, 21, accuracy: 1e-9)
    }

    // MARK: Fonts

    func testTheFourApprovedFontsAreBundledByFamilyAndWeight() {
        XCTAssertTrue(WatermarkFonts.allBundled)
        let expected: [(EditRecipe.Watermark.Font, String, Double?)] = [
            (.allura, "Allura", nil), (.cormorantGaramond, "Cormorant Garamond", 500), (.inter, "Inter", 400), (.caveat, "Caveat", 500)
        ]
        for (font, family, weight) in expected {
            let ctFont = WatermarkFonts.font(font, size: 20)
            XCTAssertEqual(CTFontCopyFamilyName(ctFont) as String, family)
            if let weight { XCTAssertEqual(Self.weight(of: ctFont), weight, accuracy: 0.5, "\(family) weight") }
        }
        XCTAssertEqual(Self.weight(of: WatermarkFonts.logoInitials(size: 22, cssPixels: 22)), 700, accuracy: 0.5)
    }

    /// The font's `wght` value: its variation, or the axis default when the variation leaves it out.
    private static func weight(of font: CTFont) -> Double {
        let tag = 0x7767_6874 as NSNumber
        if let value = (CTFontCopyVariation(font) as? [NSNumber: NSNumber])?[tag] { return value.doubleValue }
        let axes = CTFontCopyVariationAxes(font) as? [[String: Any]] ?? []
        let axis = axes.first { ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber) == tag }
        return (axis?[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)?.doubleValue ?? -1
    }

    // MARK: Border image box (marks on `.imgbox`)

    func testTheImageBoxIsRecoveredFromTheCanvas() {
        for (type, width, height) in [(EditRecipe.Border.Kind.solid, 1600, 1067), (.frame, 1067, 1600), (.polaroid, 1601, 900)] {
            let border = EditRecipe.Border(type: type, colour: "#FFFFFF", width: 7, spacing: 4, mat: "#F4F1EC")
            let placement = BorderStage.placement(border, frameWidth: width, frameHeight: height)
            let box = BorderStage.imageBox(border, canvasWidth: placement.canvasWidth, canvasHeight: placement.canvasHeight)
            XCTAssertEqual(box.minX * CGFloat(placement.canvasWidth), CGFloat(placement.side), accuracy: 1e-6)
            XCTAssertEqual(box.minY * CGFloat(placement.canvasHeight), CGFloat(placement.top), accuracy: 1e-6)
            XCTAssertEqual(box.width * CGFloat(placement.canvasWidth), CGFloat(width), accuracy: 1e-6)
            XCTAssertEqual(box.height * CGFloat(placement.canvasHeight), CGFloat(height), accuracy: 1e-6)
        }
        XCTAssertEqual(BorderStage.imageBox(.init(type: .none, colour: "#FFFFFF", width: 4, spacing: 3, mat: "#F4F1EC"),
                                            canvasWidth: 100, canvasHeight: 80), CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

/// The saved-signature store: ids, versions (edit recipe `signatureRef`), resolution, persistence.
@MainActor
final class SignatureStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("signatures-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func drawing(_ shift: Double = 0) -> DrawnSignature {
        DrawnSignature.fromPad(strokes: [[.init(x: 10 + shift, y: 50), .init(x: 60, y: 20), .init(x: 120, y: 60)]], penWidth: 3.36)!
    }

    func testTheVersionIsTheFirstTwelveHexDigitsOfTheSHA256OfTheStoredBytes() {
        let store = SignatureStore(directory: nil)
        let saved = store.saveDrawn(drawing())
        let digest = SHA256.hash(data: saved.data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(saved.version, String(digest.prefix(12)))
        XCTAssertEqual(saved.reference.signatureVersion.count, 12)
        XCTAssertEqual(saved.data, drawing().canonicalData, "canonical bytes: the same strokes, the same version")
        XCTAssertEqual(DrawnSignature(canonicalData: saved.data)?.canonicalData, saved.data, "reads back to the same bytes")
    }

    func testDrawingAgainKeepsTheIdAndChangesTheVersion() {
        let store = SignatureStore(directory: nil)
        let first = store.saveDrawn(drawing())
        XCTAssertEqual(store.resolve(first.reference), .available(first))
        let second = store.saveDrawn(drawing(5))
        XCTAssertEqual(second.id, first.id)
        XCTAssertNotEqual(second.version, first.version)
        XCTAssertEqual(store.resolve(first.reference), .changed(current: second), "the earlier edit is rendered without it")
        XCTAssertEqual(store.resolve(second.reference), .available(second))
    }

    func testDeletingMakesTheReferenceUnavailable() {
        let store = SignatureStore(directory: nil)
        let saved = store.saveDrawn(drawing())
        store.delete(.drawn)
        XCTAssertEqual(store.resolve(saved.reference), .unavailable)
        XCTAssertNil(store.shown)
    }

    func testOneDrawnAndOneImportedAreKeptAndPreferencesShowsTheLastSaved() throws {
        let store = SignatureStore(directory: nil)
        let drawn = store.saveDrawn(drawing())
        let png = try XCTUnwrap(SignatureInkExtractor.prototypeImportedSample(scale: 2))
        let imported = store.saveImported(png: png)
        XCTAssertNotEqual(drawn.id, imported.id)
        XCTAssertEqual(store.shown, imported)
        store.delete(.imported)
        XCTAssertEqual(store.shown, drawn, "the other one is shown next")
    }

    func testSignaturesSurviveRelaunch() throws {
        let store = SignatureStore(directory: directory)
        let drawn = store.saveDrawn(drawing())
        let imported = store.saveImported(png: try XCTUnwrap(SignatureInkExtractor.prototypeImportedSample(scale: 2)))
        let digest = store.saveLogo(png: imported.data)
        let reloaded = SignatureStore(directory: directory)
        XCTAssertEqual(reloaded.drawn, drawn)
        XCTAssertEqual(reloaded.imported, imported)
        XCTAssertEqual(reloaded.mostRecentKind, .imported)
        XCTAssertEqual(reloaded.logo(sha256: digest), imported.data)
        reloaded.delete(.drawn)
        XCTAssertNil(SignatureStore(directory: directory).drawn)
    }

    func testAPadDrawingKeepsThePrototypesStrokeProportion() throws {
        let signature = drawing()
        XCTAssertEqual(signature.strokeWidth / signature.viewBox.height, 2.4 / 50, accuracy: 1e-9)
        XCTAssertEqual(signature.viewBox.y + signature.viewBox.height / 2, 40, accuracy: 1e-9, "centred on the ink")
        XCTAssertNil(DrawnSignature.fromPad(strokes: [], penWidth: 3.36))
    }

    func testImportRemovesThePaperAndKeepsTheInkColour() throws {
        // Beige paper with a navy stroke.
        let width = 400, height = 200
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let ink = (90..<110).contains(y) && (100..<300).contains(x)
                let colour: [UInt8] = ink ? [0x1D, 0x2A, 0x6B] : [0xF2, 0xEE, 0xE4]
                pixels[i] = colour[0]; pixels[i + 1] = colour[1]; pixels[i + 2] = colour[2]; pixels[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let png = try XCTUnwrap(SignatureInkExtractor.extract(from: image))
        let out = try XCTUnwrap(WatermarkStage.image(from: png))
        // The ink is 20 px tall: the box is 20 / (32/50) = 31.25 px, plus 6/50 of that each side.
        XCTAssertEqual(out.height, 31)
        XCTAssertEqual(out.width, 200 + 8)
        let bytes = try MetalLUTRenderer.rgba8Bytes(of: out)
        let centre = ((out.height / 2) * out.width + out.width / 2) * 4
        XCTAssertEqual(bytes[centre + 3], 255, "ink opaque")
        XCTAssertEqual(Int(bytes[centre + 2]), 0x6B, accuracy: 3, "navy kept")
        XCTAssertEqual(bytes[3], 0, "paper removed")
        let paperOnly = CGImage(width: 50, height: 50, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 50 * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: CGDataProvider(data: Data([UInt8](repeating: 240, count: 50 * 50 * 4)) as CFData)!,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        XCTAssertNil(SignatureInkExtractor.extract(from: paperOnly), "no ink found")
        // A blank page has nothing to use: no sheet (a toast says so), never an empty rectangle.
        XCTAssertEqual(SignatureInkExtractor.importSignature(from: paperOnly), .blank)
        XCTAssertNil(SignatureInkExtractor.importPNG(from: paperOnly))
        // Defect W6: content with no ink told from the paper is used as it is (no paper removal).
        var faint = [UInt8](repeating: 128, count: 50 * 50 * 4)
        for i in stride(from: 0, to: faint.count / 2, by: 4) { faint[i] = 150; faint[i + 1] = 140 }
        for i in stride(from: 3, to: faint.count, by: 4) { faint[i] = 255 }
        let faintImage = try MetalLUTRenderer.makeImage(rgba8: faint, width: 50, height: 50)
        guard case .asIs(let asIs) = SignatureInkExtractor.importSignature(from: faintImage) else { return XCTFail("expected as-is") }
        let asIsImage = try XCTUnwrap(WatermarkStage.image(from: asIs))
        XCTAssertEqual(asIsImage.width, 50); XCTAssertEqual(asIsImage.height, 50)
        let store = SignatureStore(directory: nil)
        let saved = store.saveImported(png: asIs)
        XCTAssertEqual(store.resolve(saved.reference), .available(saved), "Use saves it like any import")
        XCTAssertEqual(SignatureInkExtractor.importSignature(from: image), .inkFound(png), "with ink, the paper is removed as before")
        XCTAssertEqual(SignatureInkExtractor.importSignature(from: nil), .unreadable)
    }
}

/// Stage 12 in the session: preview and Save copy share it; a missing signature renders without it.
@MainActor
final class WatermarkSessionTests: XCTestCase {

    private func decoded(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testSaveCopyCarriesTheBorderAndTheWatermarkAndTheSessionKeepsTheOriginal() async throws {
        let session = try await EditorTestSupport.readySession()
        let original = session.photo.originalData
        session.commitBorder { $0.type = .polaroid }
        session.commitWatermark { w in
            WatermarkPanelModel.setType(.text, on: &w)
            w.text = .init(text: "A. Rivera", font: .caveat)
            w.placement = .border
        }
        await session.settleRendering()
        let watermarked = try decoded(try await session.exportedData())
        session.undo()
        await session.settleRendering()
        let plain = try decoded(try await session.exportedData())
        XCTAssertEqual(watermarked.width, plain.width)
        XCTAssertEqual(watermarked.height, plain.height)
        XCTAssertEqual(watermarked.width, 640 + 2 * 35, "polaroid side 0.055 × 640 = 35")
        let a = try MetalLUTRenderer.rgba8Bytes(of: watermarked), b = try MetalLUTRenderer.rgba8Bytes(of: plain)
        var changedRows = Set<Int>()
        for i in stride(from: 0, to: a.count, by: 4) where abs(Int(a[i]) - Int(b[i])) > 40 { changedRows.insert(i / 4 / watermarked.width) }
        let photoBottom = 35 + 426
        XCTAssertFalse(changedRows.isEmpty, "the watermark is in the saved copy")
        XCTAssertGreaterThan(changedRows.min() ?? 0, photoBottom, "only the polaroid margin changed")
        XCTAssertEqual(session.photo.originalData, original, "the original is untouched")
        XCTAssertEqual(session.displayedImageBox.minX * CGFloat(session.displayedImage.width), 35, accuracy: 1)
    }

    func testAMissingOrChangedSignatureRendersWithoutIt() async throws {
        let session = try await EditorTestSupport.readySession()
        let drawn = session.signatures.saveDrawn(.prototypeSample)
        session.commitWatermark { w in WatermarkPanelModel.setType(.signature, on: &w); w.signature = drawn.reference }
        XCTAssertNotNil(session.watermarkContent(for: session.recipe.tools.watermark))
        let withSignature = try await session.exportedData()
        session.signatures.saveDrawn(DrawnSignature.fromPad(strokes: [[.init(x: 0, y: 0), .init(x: 40, y: 10)]], penWidth: 3.36)!)
        XCTAssertNil(session.watermarkContent(for: session.recipe.tools.watermark), "changed: never substituted")
        let changed = try await session.exportedData()
        session.signatures.delete(.drawn)
        XCTAssertNil(session.watermarkContent(for: session.recipe.tools.watermark), "missing")
        session.commitWatermark { WatermarkPanelModel.setType(.none, on: &$0) }
        let none = try await session.exportedData()
        XCTAssertNotEqual(withSignature, changed)
        XCTAssertEqual(try MetalLUTRenderer.rgba8Bytes(of: decoded(changed)), try MetalLUTRenderer.rgba8Bytes(of: decoded(none)))
    }

    func testThePanelCommitsOneStepPerChangeAndKeepsTheReaderRule() async throws {
        let session = try await EditorTestSupport.readySession()
        let panel = WatermarkPanelModel(session: session, signatures: session.signatures)
        panel.choose(.text)
        XCTAssertEqual(session.recipe.tools.watermark.type, .text)
        XCTAssertEqual(session.recipe.tools.watermark.text?.text, "A. Rivera")
        panel.chooseFont(.caveat)
        panel.cyclePosition()
        XCTAssertEqual(session.recipe.tools.watermark.position, 0, "Bottom right → Top left")
        panel.choose(.logo)
        XCTAssertNil(session.recipe.tools.watermark.text, "exactly the part matching type is set")
        XCTAssertEqual(session.recipe.tools.watermark.logo, .bundled(id: WatermarkStage.sampleLogoID))
        panel.choose(.text)
        XCTAssertEqual(session.recipe.tools.watermark.text?.font, .caveat, "the session remembers the text")
        panel.choose(.signature)
        XCTAssertEqual(session.recipe.tools.watermark.type, .text, "no saved signature: nothing to choose yet")
        XCTAssertEqual(panel.selectedType, .signature)
        panel.saveDrawn(.prototypeSample)
        XCTAssertEqual(session.recipe.tools.watermark.type, .signature)
        XCTAssertEqual(session.recipe.tools.watermark.signature, session.signatures.drawn?.reference)
        XCTAssertEqual(session.toast, "Signature saved for reuse")
        // Round trip through the codec: the recipe stays valid.
        let encoded = EditRecipeCodec.encode(session.recipe)
        XCTAssertEqual(try EditRecipeCodec.decode(encoded), session.recipe)
    }

    func testPolaroidSignatureOnTheMarginChoosesTheSavedSignature() async throws {
        let session = try await EditorTestSupport.readySession()
        let watermarkPanel = WatermarkPanelModel(session: session, signatures: session.signatures)
        let border = BorderPanelModel(session: session, watermarkPanel: watermarkPanel)
        border.choose(.polaroid)
        border.toggleSignatureOnMargin()
        XCTAssertEqual(watermarkPanel.sheet, .draw, "nothing saved yet: Draw signature opens")
        watermarkPanel.saveDrawn(.prototypeSample)
        XCTAssertTrue(border.signatureOnMargin)
        border.toggleSignatureOnMargin()
        XCTAssertFalse(border.signatureOnMargin)
        XCTAssertEqual(session.recipe.tools.watermark.placement, .photo)
        session.commitWatermark { WatermarkPanelModel.setType(.none, on: &$0) }
        border.toggleSignatureOnMargin()
        XCTAssertTrue(border.signatureOnMargin, "no watermark: the saved signature goes on the margin")
        XCTAssertEqual(session.recipe.tools.watermark.type, .signature)
    }

    func testBorderOpensOnThePreferredTypeWithoutApplyingIt() async throws {
        let session = try await EditorTestSupport.readySession()
        let border = BorderPanelModel(session: session, watermarkPanel: WatermarkPanelModel(session: session, signatures: session.signatures),
                                      preferredBorder: { .polaroid })
        border.openOnPreferredType()
        XCTAssertEqual(border.selectedType, .polaroid)
        XCTAssertEqual(session.recipe.tools.border.type, .none, "never added automatically")
        XCTAssertFalse(session.canUndo)
        border.commit { $0.colour = "#F4F1EC" }
        XCTAssertEqual(session.recipe.tools.border.type, .polaroid, "a change on the shown tab applies it")
        XCTAssertEqual(session.recipe.tools.border.colour, "#F4F1EC")
    }
}

/// Focus & Blur's strength on screen (PROVISIONAL approach, pending the owner): the prototype blurs the
/// displayed photo with σ = blur/9 pt on every device.
final class BlurDisplayScaleTests: XCTestCase {

    /// iPhone 17 portrait bg-focus shows the woman photo 1129 px / 3 = 376.3 pt long; iPad Pro 13"
    /// landscape 1878 px / 2 = 939 pt (contract-fixes-1 §1 measurement table).
    func testTheDisplayedSigmaIsBlurOverNinePointsOnEveryLayout() {
        for displayLong in [376.3, 939.0] {
            for sourceLong in [1_257, 4_032] {
                let fraction = RefocusRenderer.maxRadiusFraction(displayLongEdgePoints: displayLong, frameLongPixels: sourceLong,
                                                                 sourceLongPixels: sourceLong)
                for blur: Float in [30, 55, 100] {
                    let radiusPixels = RefocusRenderer.radiusMax(blur: blur, longSide: sourceLong, fraction: fraction)
                    let sigmaPoints = Double(RefocusRenderer.sigmaPerMaxRadius * radiusPixels) * displayLong / Double(sourceLong)
                    XCTAssertEqual(sigmaPoints, Double(blur) / 9, accuracy: 1e-3, "display \(displayLong) pt, source \(sourceLong) px")
                }
            }
        }
    }

    func testTheFractionIsResolutionIndependentSoExportMatchesPreview() {
        // Preview 1600 px and export 4032 px of the same photo, both displayed 376.3 pt long.
        let preview = RefocusRenderer.maxRadiusFraction(displayLongEdgePoints: 376.3, frameLongPixels: 1_600, sourceLongPixels: 1_600)
        let export = RefocusRenderer.maxRadiusFraction(displayLongEdgePoints: 376.3, frameLongPixels: 4_032, sourceLongPixels: 4_032)
        XCTAssertEqual(preview, export, accuracy: 1e-7)
        // A crop shows a smaller part of the source larger: the source fraction shrinks with it.
        let cropped = RefocusRenderer.maxRadiusFraction(displayLongEdgePoints: 376.3, frameLongPixels: 2_016, sourceLongPixels: 4_032)
        XCTAssertEqual(cropped, export / 2, accuracy: 1e-7)
    }

    func testTheCalibrationKeepsTheMeasuredRatio() {
        // σ = 0.0133 of the long edge at Blur 55 with R_max 0.06 (contract-fixes-1 §1).
        XCTAssertEqual(Double(RefocusRenderer.sigmaPerMaxRadius), 0.0133 / 0.033, accuracy: 1e-6)
        XCTAssertEqual(Double(RefocusRenderer.maxRadiusPointsAtBlur100), 27.57, accuracy: 0.01)
    }
}

/// The session renders the watermark at the displayed size, and Save copy at the layout of the moment.
@MainActor
final class WatermarkDisplaySizeTests: XCTestCase {

    private func changedRowSpan(_ a: CGImage, _ b: CGImage) throws -> (rows: Int, top: Int)? {
        let pa = try MetalLUTRenderer.rgba8Bytes(of: a), pb = try MetalLUTRenderer.rgba8Bytes(of: b)
        var top = Int.max, bottom = -1
        for i in stride(from: 0, to: pa.count, by: 4) where abs(Int(pa[i]) - Int(pb[i])) > 60 {
            let y = i / 4 / a.width
            top = min(top, y); bottom = max(bottom, y)
        }
        return bottom < 0 ? nil : (bottom - top + 1, top)
    }

    private func decoded(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    func testPreviewShowsThePrototypesPointsAndExportMatchesPreview() async throws {
        let photo = try await EditorTestSupport.photo(width: 1_280, height: 852)
        let session = try await EditorTestSupport.readySession(photo: photo, previewLongEdge: 640)
        // The iPhone 17 layout of a 3:2 photo: 402 × 267.6 pt.
        session.setDisplayedPhotoSize(CGSize(width: 402, height: 267.6))
        await session.settleRendering()
        let previewPlain = session.displayedImage
        let exportPlain = try decoded(try await session.exportedData())
        session.commitWatermark { w in
            WatermarkPanelModel.setType(.text, on: &w)
            w.text = .init(text: "AAAA", font: .inter)
            w.opacity = 100
        }
        await session.settleRendering()
        let preview = try XCTUnwrap(try changedRowSpan(session.displayedImage, previewPlain))
        let exportData = try await session.exportedData()
        let export = try XCTUnwrap(try changedRowSpan(try decoded(exportData), exportPlain))
        // Inter caps are 0.727 em: 18 pt × 0.727 = 13.1 pt on screen.
        let previewPoints = Double(preview.rows) * 267.6 / 426
        XCTAssertEqual(previewPoints, 18 * 0.727, accuracy: 1.5, "displayed at the prototype's size")
        XCTAssertEqual(Double(export.rows), 2 * Double(preview.rows), accuracy: 3, "the saved copy is the screen, at twice the pixels")
        XCTAssertEqual(Double(export.top) / 852, Double(preview.top) / 426, accuracy: 0.01)
    }
}
