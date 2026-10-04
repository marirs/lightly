import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Lightly

/// Evidence for the PROVISIONAL display-relative sizing (W1) and the signature import cases
/// (W6), from actual rendered images. Images and a measurements file go to `LIGHTLY_EVIDENCE_DIR`
/// when it is set (otherwise a temporary folder); the assertions record what the renderers do.
///
/// Layouts: the displayed photo for a 3:2 photo is 402 × 268 pt on iPhone 17 portrait and
/// 892 × 594.8 pt on iPad Pro 13" landscape (the prototype's own layouts).
@MainActor
final class SizingEvidenceTests: XCTestCase {

    static let iPhone17 = CGSize(width: 402, height: 268)
    static let iPad13Landscape = CGSize(width: 892, height: 594.8)

    private var directory: URL!
    private var lines: [String] = []

    override func setUp() async throws {
        let path = ProcessInfo.processInfo.environment["LIGHTLY_EVIDENCE_DIR"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("sizing-evidence").path
        directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        let url = directory.appendingPathComponent("\(name.replacingOccurrences(of: " ", with: "_").filter { $0.isLetter || $0.isNumber || $0 == "_" }).txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func record(_ line: String) { lines.append(line); print("EVIDENCE \(line)") }

    private func save(_ image: CGImage, _ name: String) {
        let url = directory.appendingPathComponent(name) as CFURL
        guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private func image(_ pixels: [UInt8], _ width: Int, _ height: Int) throws -> CGImage {
        try MetalLUTRenderer.makeImage(rgba8: pixels, width: width, height: height)
    }

    /// Bilinear-free downscale through Core Graphics (what a viewer does to compare sizes).
    private func scaled(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    // MARK: - Watermark

    /// The watermark's ink rows (pixels brighter than 200 on a 40-grey canvas).
    private func inkHeight(_ image: CGImage) throws -> Int {
        let p = try MetalLUTRenderer.rgba8Bytes(of: image)
        var top = Int.max, bottom = -1
        for i in stride(from: 0, to: p.count, by: 4) where p[i] > 200 {
            let y = i / 4 / image.width
            top = min(top, y); bottom = max(bottom, y)
        }
        return bottom < 0 ? 0 : bottom - top + 1
    }

    private func watermarked(width: Int, height: Int, display: CGSize) throws -> CGImage {
        var pixels = [UInt8](repeating: 40, count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        let w = EditRecipe.Watermark(type: .text, signature: nil, text: .init(text: "A. Rivera", font: .inter), logo: nil,
                                     placement: .photo, position: 8, offset: nil, size: 34, opacity: 100, colour: "#FFFFFF")
        WatermarkStage.apply(w, content: .text("A. Rivera", .inter), pixels: &pixels, canvasWidth: width, canvasHeight: height,
                             imageRect: CGRect(x: 0, y: 0, width: width, height: height), border: .none,
                             displayShortEdgePoints: Double(min(display.width, display.height)))
        return try image(pixels, width, height)
    }

    func testWatermarkSavedAtTwoEditorLayoutsAndPreviewVersusExport() throws {
        // The same 3:2 photo: preview 1600 × 1067, export 4800 × 3200.
        for (label, display) in [("iphone17", Self.iPhone17), ("ipad13-landscape", Self.iPad13Landscape)] {
            let export = try watermarked(width: 4_800, height: 3_200, display: display)
            let preview = try watermarked(width: 1_600, height: 1_067, display: display)
            save(export, "wm-export-\(label).png")
            save(preview, "wm-preview-\(label).png")
            let exportHeight = try inkHeight(export), previewHeight = try inkHeight(preview)
            let exportScaledDown = try inkHeight(try scaled(export, width: 1_600, height: 1_067))
            record("watermark \(label): export ink height \(exportHeight) px of 3200 (\(String(format: "%.4f", Double(exportHeight) / 3200)) of the short edge); preview \(previewHeight) px of 1067; export scaled to the preview size \(exportScaledDown) px")
            record("watermark \(label): on screen \(String(format: "%.2f", Double(previewHeight) * Double(display.height) / 1067)) pt (Inter cap height of 18 pt = 13.1 pt)")
            XCTAssertEqual(Double(exportScaledDown), Double(previewHeight), accuracy: 2, "preview and export agree")
        }
        let phone = try inkHeight(try watermarked(width: 4_800, height: 3_200, display: Self.iPhone17))
        let pad = try inkHeight(try watermarked(width: 4_800, height: 3_200, display: Self.iPad13Landscape))
        record("watermark VIEWPORT DEPENDENCE: the same edit saved from iPhone 17 gives \(phone) px, from iPad 13 landscape \(pad) px (ratio \(String(format: "%.2f", Double(phone) / Double(pad))); display short edges 268 / 594.8 pt = \(String(format: "%.2f", 594.8 / 268)))")
        XCTAssertGreaterThan(phone, pad, "the saved copy depends on the editor's layout (provisional approach)")
    }

    // MARK: - Focus & Blur

    /// A step edge as the background, all of it far (disparity 0), focus on the near plane: every
    /// pixel gets R_max. The equivalent σ is the line-spread function's standard deviation.
    private func blurredEdge(width: Int, height: Int, display: CGSize?) -> FloatImage {
        var linear = FloatImage(width: width, height: height, channels: 3)
        for y in 0..<height { for x in 0..<width { let v: Float = x < width / 2 ? 0.05 : 0.8; for c in 0..<3 { linear.data[(y * width + x) * 3 + c] = v } } }
        let disparity = FloatImage(width: width, height: height, channels: 1, repeating: 0)
        let scene = RefocusRenderer.buildScene(linear: linear, disparity: disparity, matte: nil)
        let fraction = display.map {
            RefocusRenderer.maxRadiusFraction(displayLongEdgePoints: Double(max($0.width, $0.height)), frameLongPixels: width,
                                              sourceLongPixels: width)
        }
        var params = RefocusRenderer.Parameters(blur: 55, focusDepth: 40, style: .soft)
        params.focalOverride = 1
        params.subjectFocus = false
        params.maxRadiusFraction = fraction
        return RefocusRenderer.render(scene, params)
    }

    private func sigma(_ image: FloatImage) -> Double {
        let y = image.height / 2
        let row = (0..<image.width).map { Double(image.data[(y * image.width + $0) * 3]) }
        let lsf = zip(row.dropFirst(), row).map { $0 - $1 }
        let total = lsf.reduce(0, +)
        let mean = lsf.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element } / total
        let variance = lsf.enumerated().reduce(0) { $0 + pow(Double($1.offset) - mean, 2) * $1.element } / total
        return variance.squareRoot()
    }

    func testBlurSavedAtTwoEditorLayoutsAndPreviewVersusExport() throws {
        var exportSigmas: [String: Double] = [:]
        for (label, display) in [("iphone17", Self.iPhone17), ("ipad13-landscape", Self.iPad13Landscape)] {
            let export = blurredEdge(width: 1_200, height: 120, display: display)
            let preview = blurredEdge(width: 600, height: 60, display: display)
            save(try image(export.rgba8FromLinear(), export.width, export.height), "blur-export-\(label).png")
            save(try image(preview.rgba8FromLinear(), preview.width, preview.height), "blur-preview-\(label).png")
            let se = sigma(export), sp = sigma(preview)
            exportSigmas[label] = se
            let onScreen = sp * Double(display.width) / 600
            record("blur \(label): export σ \(String(format: "%.2f", se)) px of 1200 (\(String(format: "%.4f", se / 1200)) of the long edge); preview σ \(String(format: "%.2f", sp)) px of 600 → export/2 = \(String(format: "%.2f", se / 2)); on screen \(String(format: "%.2f", onScreen)) pt (prototype 55/9 = 6.11 pt)")
            XCTAssertEqual(se / 2, sp, accuracy: 0.6, "preview and export agree")
            // This plane gets the full R_max; the calibration (contract-fixes-1 §1) matched the
            // prototype on the bg-focus wall, which gets 0.72 R_max, so σ here is 1/0.72 of 55/9.
            record("blur \(label): σ on screen / (55/9 pt) = \(String(format: "%.2f", onScreen / (55.0 / 9))) at full R_max (calibration point: 0.72 R_max → \(String(format: "%.2f", onScreen * 0.72)) pt)")
            XCTAssertEqual(onScreen * 0.72, 55.0 / 9, accuracy: 0.8, "the calibrated scene's σ is the prototype's")
        }
        let ratio = exportSigmas["iphone17"]! / exportSigmas["ipad13-landscape"]!
        record("blur VIEWPORT DEPENDENCE: the same edit saved from iPhone 17 gives σ \(String(format: "%.2f", exportSigmas["iphone17"]!)) px, from iPad 13 landscape \(String(format: "%.2f", exportSigmas["ipad13-landscape"]!)) px (ratio \(String(format: "%.2f", ratio)); display long edges 402 / 892 pt = \(String(format: "%.2f", 892.0 / 402)))")
    }

    // MARK: - Signature import

    /// A photographed signature: warm paper with a light gradient and grain, blue ink strokes of
    /// varying width (stand-in for a camera photo; no real signature photo is in the repository).
    private func inkPhoto() throws -> CGImage {
        let width = 900, height = 500
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  colors: [CGColor(srgbRed: 0.96, green: 0.94, blue: 0.89, alpha: 1), CGColor(srgbRed: 0.86, green: 0.84, blue: 0.79, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        var seed: UInt64 = 7
        for _ in 0..<4_000 {
            seed = seed &* 6364136223846793005 &+ 1
            let x = Double(seed >> 33 % UInt64(width)), y = Double((seed >> 13) % UInt64(height))
            context.setFillColor(CGColor(gray: 0.6, alpha: 0.08))
            context.fill(CGRect(x: x.truncatingRemainder(dividingBy: Double(width)), y: y, width: 2, height: 2))
        }
        context.setStrokeColor(CGColor(srgbRed: 0.10, green: 0.16, blue: 0.45, alpha: 0.95))
        context.setLineCap(.round)
        let path = DrawnSignature.prototypeSample.path(origin: CGPoint(x: 120, y: 80), height: 340)
        context.setLineWidth(9)
        context.addPath(path)
        context.strokePath()
        return try XCTUnwrap(context.makeImage())
    }

    private func blankPage() throws -> CGImage {
        let pixels = [UInt8](repeating: 255, count: 400 * 300 * 4)
        return try image(pixels, 400, 300)
    }

    /// The sheet's preview (the PNG on the sheet's paper colour) and the watermark composited on a
    /// photo-like canvas, saved for each case.
    private func composite(_ png: Data, name: String, cleanOutsideInk: Bool = true) throws {
        let signature = try XCTUnwrap(WatermarkStage.image(from: png))
        let paper = try XCTUnwrap(CGContext(data: nil, width: signature.width, height: signature.height, bitsPerComponent: 8,
                                            bytesPerRow: signature.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        paper.setFillColor(CGColor(srgbRed: 0xF7 / 255.0, green: 0xF4 / 255.0, blue: 0xEE / 255.0, alpha: 1))
        paper.fill(CGRect(x: 0, y: 0, width: signature.width, height: signature.height))
        paper.draw(signature, in: CGRect(x: 0, y: 0, width: signature.width, height: signature.height))
        save(try XCTUnwrap(paper.makeImage()), "import-\(name)-sheet-preview.png")
        let width = 1_600, height = 1_067
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width { let o = (y * width + x) * 4; pixels[o] = UInt8(60 + x * 80 / width); pixels[o + 1] = 90; pixels[o + 2] = UInt8(40 + y * 60 / height); pixels[o + 3] = 255 } }
        var w = EditRecipe.Watermark(type: .signature, signature: .init(signatureId: "e", signatureVersion: "000000000000", kind: .imported),
                                     text: nil, logo: nil, placement: .photo, position: 8, offset: nil, size: 34, opacity: 100, colour: "#FFFFFF")
        w.size = 60
        let base = pixels
        WatermarkStage.apply(w, content: .importedSignature(png), pixels: &pixels, canvasWidth: width, canvasHeight: height,
                             imageRect: CGRect(x: 0, y: 0, width: width, height: height), border: .none,
                             displayShortEdgePoints: 268)
        save(try image(pixels, width, height), "import-\(name)-on-photo.png")
        // Outside the ink the photo is untouched, byte for byte: every changed pixel is within 4 px
        // of a strongly changed (ink) pixel. A residual paper rectangle would fail here.
        var strong = [Bool](repeating: false, count: width * height), changed: [Int] = []
        for i in 0..<(width * height) {
            let o = i * 4
            let delta = (0..<3).map { abs(Int(pixels[o + $0]) - Int(base[o + $0])) }.max() ?? 0
            if delta > 0 { changed.append(i) }
            if delta > 40 { strong[i] = true }
        }
        let near = SignatureInkExtractor.dilate(strong, width: width, height: height, radius: 4)
        let stray = changed.filter { !near[$0] }.count
        record("import \(name): \(changed.count) pixels changed on the photo, \(stray) of them away from ink")
        // An as-is import is the photo itself, a rectangle by nature: only recorded.
        if cleanOutsideInk { XCTAssertEqual(stray, 0, "no tint or rectangle outside the ink (\(name))") }
    }

    func testSignatureImportWithInkBlankAndUndecodableInputs() throws {
        let ink = try inkPhoto()
        save(ink, "import-ink-input.png")
        guard case .inkFound(let inkPNG) = SignatureInkExtractor.importSignature(from: ink) else { return XCTFail("ink not found") }
        try composite(inkPNG, name: "ink")
        let inkImage = try XCTUnwrap(WatermarkStage.image(from: inkPNG))
        let bytes = try MetalLUTRenderer.rgba8Bytes(of: inkImage)
        let transparent = stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] == 0 }.count
        record("import ink: \(inkImage.width) × \(inkImage.height) px, \(String(format: "%.0f", 100 * Double(transparent) / Double(bytes.count / 4))) % transparent (paper removed)")
        XCTAssertGreaterThan(Double(transparent) / Double(bytes.count / 4), 0.6)
        // Paper ends at exactly zero alpha: every pixel more than 6 px from ink is transparent.
        let core = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] >= 128 }
        let nearInk = SignatureInkExtractor.dilate(core, width: inkImage.width, height: inkImage.height, radius: 6)
        let paperAlpha = (0..<(inkImage.width * inkImage.height)).filter { !nearInk[$0] && bytes[$0 * 4 + 3] != 0 }.count
        record("import ink: \(paperAlpha) pixels with alpha > 0 farther than 6 px from ink")
        XCTAssertEqual(paperAlpha, 0)

        let blank = try blankPage()
        save(blank, "import-blank-input.png")
        let blankResult = SignatureInkExtractor.importSignature(from: blank)
        record("import blank white page: \(blankResult == .blank ? "blank → no sheet; toast \"\(WatermarkPanelModel.blankImportMessage)\"" : "\(blankResult)")")
        XCTAssertEqual(blankResult, .blank, "never an empty rectangle as a signature")

        let undecodable = Data("not an image".utf8)
        let decoded = WatermarkPanelModel.uprightImage(undecodable)
        let undecodableResult = SignatureInkExtractor.importSignature(from: decoded)
        record("import undecodable file: \(undecodableResult == .unreadable ? "unreadable → no sheet; toast \"\(WatermarkPanelModel.unreadableImportMessage)\"" : "\(undecodableResult)")")
        XCTAssertEqual(undecodableResult, .unreadable)

        // A photo with content but no ink told from the paper (a mid-grey logo on grey): used as is.
        var logo = [UInt8](repeating: 128, count: 300 * 200 * 4)
        for y in 60..<140 { for x in 60..<240 { let o = (y * 300 + x) * 4; logo[o] = 150; logo[o + 1] = 140; logo[o + 2] = 120 } }
        for i in stride(from: 3, to: logo.count, by: 4) { logo[i] = 255 }
        let lowContrast = try image(logo, 300, 200)
        guard case .asIs(let asIsPNG) = SignatureInkExtractor.importSignature(from: lowContrast) else { return XCTFail("expected as-is") }
        try composite(asIsPNG, name: "low-contrast-as-is", cleanOutsideInk: false)
        record("import low-contrast photo: used as it is (\(lowContrast.width) × \(lowContrast.height))")
    }
}
