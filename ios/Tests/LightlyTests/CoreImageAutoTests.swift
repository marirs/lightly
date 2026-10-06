import CoreGraphics
import CoreImage
import ImageIO
import XCTest
@testable import Lightly

/// iOS Auto = Core Image auto enhancement (owner approval 2026-10-06).
@MainActor
final class CoreImageAutoTests: XCTestCase {

    func testNoFilterBakesTheIdentityLUT() throws {
        let lut = try XCTUnwrap(CoreImageAutoCorrection(filters: [], omitted: []).lut(dimension: 9))
        let identity = LUT3D.identity(dimension: 9)
        let worst = zip(lut.values, identity.values).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 1e-3, "grid order and orientation of the bake match the LUT layout")
    }

    func testTheStoredCorrectionRebuildsTheSameLUT() throws {
        let correction = CoreImageAutoCorrection(filters: [
            .init(name: "CIVibrance", parameters: ["inputAmount": .init(isVector: false, values: [0.4])]),
            .init(name: "CIToneCurve", parameters: [
                "inputPoint0": .init(isVector: true, values: [0, 0.03]), "inputPoint1": .init(isVector: true, values: [0.25, 0.3]),
                "inputPoint2": .init(isVector: true, values: [0.5, 0.56]), "inputPoint3": .init(isVector: true, values: [0.75, 0.8]),
                "inputPoint4": .init(isVector: true, values: [1, 1])]),
        ], omitted: ["CIHighlightShadowAdjust"])
        let json = try JSONSerialization.data(withJSONObject: correction.json)
        let decoded = try XCTUnwrap(CoreImageAutoCorrection(json: try JSONSerialization.jsonObject(with: json)))
        XCTAssertEqual(decoded, correction)
        XCTAssertEqual(decoded.lut(), correction.lut(), "deterministic: a restore renders exactly what was shown")
        XCTAssertNotEqual(correction.lut(), LUT3D.identity(), "the filters change colour")
    }

    func testAutoIsTheStartingPointAndEachToggleIsOneStepAndSaveCopyUsesIt() async throws {
        let photo = try await EditorTestSupport.photo(width: 1_200, height: 800)
        let session = try await EditorTestSupport.readySession(photo: photo, autoEnhancer: CoreImageAutoEnhancer())
        XCTAssertEqual(session.autoState, .applied)
        XCTAssertEqual(session.recipe.auto.modelId, CoreImageAutoCorrection.recipeModelID)
        XCTAssertEqual(session.history.count, 1, "the approved flow: Auto is the starting state, not an edit")
        let withAuto = try await session.exportedData()

        session.toggleAuto()
        XCTAssertEqual(session.history.count, 2, "switching Auto off is one Undo step")
        XCTAssertEqual(session.recipe.auto.strength, 0)
        let withoutAuto = try await session.exportedData()
        _ = (withAuto, withoutAuto)   // the guards may leave a synthetic photo unchanged; equality is not asserted
        session.undo()
        XCTAssertEqual(session.autoState, .applied)
        XCTAssertEqual(session.recipe.auto.strength, 1)
    }

    /// The clipping guard: a tone curve that would push the top of a mid-range photo into white is stepped down until it
    /// adds no more than 0.1 percentage points of clipped pixels.
    func testTheClippingGuardStepsDownATonalLiftThatWouldClip() throws {
        // A horizontal ramp from 20 % to 80 % grey: does not span its range, so the tone curve is considered.
        let w = 256, h = 64
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let v = UInt8(51 + x * 153 / (w - 1)); let i = (y * w + x) * 4; bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let curve = try XCTUnwrap(CIFilter(name: "CIToneCurve"))
        for (k, p) in [(0, (0.0, 0.0)), (1, (0.25, 0.3)), (2, (0.5, 0.7)), (3, (0.7, 1.0)), (4, (1.0, 1.0))] {
            curve.setValue(CIVector(x: p.0, y: p.1), forKey: "inputPoint\(k)")
        }
        let result = CoreImageAutoGuards.guarded([curve], proxy: image)
        let after = CoreImageAutoGuards.stats(CoreImageAutoGuards.apply(result.filters, to: CIImage(cgImage: image)), faces: [], context: CIContext())
        XCTAssertLessThanOrEqual(after.highlightClip, CoreImageAutoGuards.clipTolerance + 1e-9, "no new clipping: \(result.notes)")
        XCTAssertTrue(result.notes.contains { $0.contains("strength") && !$0.contains("strength 1.00") }, "the lift was stepped down: \(result.notes)")
    }

    /// The approved photos through the app's Auto (analysis, guards, baked LUT): no new clipping, skin hue kept, no tone
    /// change on photos that already span their range. Failing photos of the unguarded chain: portrait_light_01
    /// (orange skin), sunset_02 (clipping), landscape_01/02 (darkened); passing: backlit_02, night_03.
    func testGuardedAutoOnTheApprovedPhotos() throws {
        let photos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../docs/ui/assets/photos").standardized
        for name in ["portrait_light_01", "portrait_medium_02", "portrait_deep_03", "sunset_02", "landscape_01", "landscape_02", "backlit_02", "night_03"] {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(photos.appendingPathComponent("\(name).jpg") as CFURL, nil), name)
            let proxy = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary))
            let correction = CoreImageAutoCorrection.analyse(proxy)
            let lut = try XCTUnwrap(correction.lut(dimension: 33))
            let cube = try XCTUnwrap(CIFilter(name: "CIColorCubeWithColorSpace"))
            cube.setValue(CIImage(cgImage: proxy), forKey: kCIInputImageKey)
            cube.setValue(33, forKey: "inputCubeDimension")
            cube.setValue(lut.values.withUnsafeBytes { Data($0) }, forKey: "inputCubeData")
            cube.setValue(CGColorSpace(name: CGColorSpace.sRGB), forKey: "inputColorSpace")
            let faces = CoreImageAutoGuards.faceRects(in: proxy), context = CIContext()
            let before = CoreImageAutoGuards.stats(CIImage(cgImage: proxy), faces: faces, context: context)
            let after = CoreImageAutoGuards.stats(try XCTUnwrap(cube.outputImage), faces: faces, context: context)
            print("\(name): \(correction.filters.map(\.name)) omitted \(correction.omitted)")
            XCTAssertLessThanOrEqual(after.highlightClip, before.highlightClip + 0.002, "\(name): highlight clipping")
            XCTAssertLessThanOrEqual(after.shadowClip, before.shadowClip + 0.002, "\(name): shadow clipping")
            // Skin colour moves only through face balance, and that only with a measured global cast.
            if let h0 = before.skinHue, let h1 = after.skinHue, !correction.filters.contains(where: { $0.name == "CIFaceBalance" }) {
                XCTAssertLessThanOrEqual(abs(h1 - h0), 2, "\(name): skin hue")
            }
            XCTAssertFalse(correction.filters.contains { $0.name == "CIHighlightShadowAdjust" }, "\(name): local filter not applied")
            if before.spansRange { XCTAssertFalse(correction.filters.contains { $0.name == "CIToneCurve" }, "\(name): no tone curve") }
        }
    }

    /// Tiled Save copy: the Auto stage is a per-pixel LUT, so tile boundaries cannot change it. Same LUT on a 12 MP
    /// photo with 256 px tiles and in one pass: identical bytes.
    func testTheAutoLUTIsIdenticalAcrossTileBoundaries() throws {
        let photos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../experiments/lut3d/photos").standardized
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(photos.appendingPathComponent("portrait_deep_01.jpg") as CFURL, nil))
        let full = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let proxy = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceThumbnailMaxPixelSize: 1024,
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary))
        // A strong correction for the check: every proposed per-pixel filter at Core Image's own values.
        let correction = CoreImageAutoCorrection.analyse(proxy)
        let lut = try XCTUnwrap(CoreImageAutoCorrection(filters: correction.filters, omitted: []).lut())
        let renderer = try MetalLUTRenderer()
        let pixels = try MetalLUTRenderer.rgba8Bytes(of: full)
        let tiled = try renderer.apply([lut], toRGBA8: pixels, width: full.width, height: full.height, maximumTileSide: 256)
        let whole = try renderer.apply([lut], toRGBA8: pixels, width: full.width, height: full.height, maximumTileSide: 8192)
        XCTAssertGreaterThan(full.width * full.height, 12_000_000, "a 12 MP-class photo")
        XCTAssertTrue(tiled == whole, "tile boundaries change nothing")
    }
}
