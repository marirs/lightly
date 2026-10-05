import CoreGraphics
import ImageIO
import XCTest
@testable import Lightly

/// Free crop (owner amendment 2026-10-05): handles, independent corners and edges, moving, locked ratios, and that the
/// crop editor previews the uncropped frame while Save copy, Undo and Redo use the committed crop.
@MainActor
final class CropGeometryTests: XCTestCase {
    private let rect = EditRecipe.Rect(x: 0.2, y: 0.2, width: 0.5, height: 0.4)
    private let size = CGSize(width: 300, height: 200)

    func testHandlesAreCornersEdgesInsideAndNothingFarAway() {
        // The rectangle spans x 60…210, y 40…120 points.
        XCTAssertEqual(CropGeometry.handle(at: CGPoint(x: 62, y: 42), rect: rect, size: size), .corner(left: true, top: true))
        XCTAssertEqual(CropGeometry.handle(at: CGPoint(x: 208, y: 119), rect: rect, size: size), .corner(left: false, top: false))
        XCTAssertEqual(CropGeometry.handle(at: CGPoint(x: 135, y: 41), rect: rect, size: size), .edge(.top))
        XCTAssertEqual(CropGeometry.handle(at: CGPoint(x: 211, y: 80), rect: rect, size: size), .edge(.right))
        XCTAssertEqual(CropGeometry.handle(at: CGPoint(x: 135, y: 80), rect: rect, size: size), .move)
        XCTAssertNil(CropGeometry.handle(at: CGPoint(x: 290, y: 190), rect: rect, size: size))
    }

    func testFreeCornerAndEdgeMoveOnlyTheirOwnSides() {
        let corner = CropGeometry.dragged(rect, handle: .corner(left: false, top: true), dx: 0.1, dy: -0.05, ratio: nil, frameAspect: 1.5)
        XCTAssertEqual(corner.x, 0.2, accuracy: 1e-9); XCTAssertEqual(corner.width, 0.6, accuracy: 1e-9)
        XCTAssertEqual(corner.y, 0.15, accuracy: 1e-9); XCTAssertEqual(corner.y + corner.height, 0.6, accuracy: 1e-9)
        let edge = CropGeometry.dragged(rect, handle: .edge(.left), dx: -0.1, dy: 0.3, ratio: nil, frameAspect: 1.5)
        XCTAssertEqual(edge.x, 0.1, accuracy: 1e-9); XCTAssertEqual(edge.x + edge.width, 0.7, accuracy: 1e-9)
        XCTAssertEqual(edge.y, rect.y, accuracy: 1e-9); XCTAssertEqual(edge.height, rect.height, accuracy: 1e-9)
    }

    func testMovingStaysInsideTheFrameAndKeepsTheSize() {
        let moved = CropGeometry.dragged(rect, handle: .move, dx: 0.5, dy: -0.5, ratio: nil, frameAspect: 1.5)
        XCTAssertEqual(moved.x, 0.5, accuracy: 1e-9); XCTAssertEqual(moved.y, 0, accuracy: 1e-9)
        XCTAssertEqual(moved.width, rect.width, accuracy: 1e-9); XCTAssertEqual(moved.height, rect.height, accuracy: 1e-9)
    }

    func testAPresetLocksTheRatioOnCornersAndEdges() {
        // A square crop (1:1 in pixels) on a 3:2 frame: width fraction × 1.5 = height fraction.
        for handle: CropGeometry.Handle in [.corner(left: true, top: false), .edge(.right), .edge(.bottom)] {
            let r = CropGeometry.dragged(rect, handle: handle, dx: 0.07, dy: 0.05, ratio: 1, frameAspect: 1.5)
            XCTAssertEqual(r.width * 1.5 / r.height, 1, accuracy: 1e-9, "\(handle)")
            XCTAssertTrue(r.x >= 0 && r.y >= 0 && r.x + r.width <= 1 + 1e-9 && r.y + r.height <= 1 + 1e-9, "\(handle) inside")
        }
    }

    func testNeverSmallerThanTheMinimum() {
        let r = CropGeometry.dragged(rect, handle: .corner(left: true, top: true), dx: 0.9, dy: 0.9, ratio: nil, frameAspect: 1.5)
        XCTAssertEqual(r.width, CropGeometry.minimumFraction, accuracy: 1e-9); XCTAssertEqual(r.height, CropGeometry.minimumFraction, accuracy: 1e-9)
    }

    /// While cropping, the preview is the uncropped (straightened, rotated) frame; Save copy writes the crop; Undo and
    /// Redo move between crops.
    func testCropEditorPreviewsTheWholeFrameWhileSaveCopyAndUndoUseTheCrop() async throws {
        let writer = SpyLibraryWriter()
        let session = try await EditorTestSupport.readySession(library: EditorTestSupport.library(), writer: writer)
        let full = (session.displayedImage.width, session.displayedImage.height)
        session.commitEdit { $0.geometry.straighten = 4; $0.geometry.cropAspect = .free; $0.geometry.cropRect = .init(x: 0.1, y: 0.2, width: 0.5, height: 0.6) }
        await session.settleRendering()
        let cropped = (session.displayedImage.width, session.displayedImage.height)
        XCTAssertEqual(Double(cropped.0) / Double(full.0), 0.5, accuracy: 0.02)

        session.isCropEditing = true
        await session.settleRendering()
        XCTAssertEqual(session.displayedImage.width, full.0, "The crop editor shows the whole frame")
        XCTAssertEqual(session.displayedImage.height, full.1)

        session.saveCopy()
        await EditorTestSupport.waitForSave(session)
        guard case .saved(let data) = session.saveState,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return XCTFail("no saved copy")
        }
        let photo = session.photo.image
        XCTAssertEqual(Double(width) / Double(photo.width), 0.5, accuracy: 0.01, "Save copy writes the crop, not the crop editor's view")
        XCTAssertEqual(Double(height) / Double(photo.height), 0.6, accuracy: 0.01)

        session.commitEdit { $0.geometry.cropRect = .init(x: 0, y: 0, width: 0.8, height: 0.8) }
        session.undo()
        XCTAssertEqual(session.recipe.tools.edit.geometry.cropRect, .init(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
        session.redo()
        XCTAssertEqual(session.recipe.tools.edit.geometry.cropRect, .init(x: 0, y: 0, width: 0.8, height: 0.8))
    }

    /// Rotation and straightening, then a free crop: the saved copy is the preview at full resolution (same
    /// aspect, same content). Compared at the preview's size, mean difference per channel.
    func testSavedCopyMatchesThePreviewAfterRotatingStraighteningAndCropping() async throws {
        let photo = try await EditorTestSupport.photo(width: 1_280, height: 852)
        let session = try await EditorTestSupport.readySession(photo: photo, previewLongEdge: 640)
        session.commitEdit {
            $0.geometry.quarterTurns = 1
            $0.geometry.straighten = -6
            $0.geometry.cropAspect = .free
            $0.geometry.cropRect = .init(x: 0.15, y: 0.1, width: 0.6, height: 0.7)
        }
        await session.settleRendering()
        let preview = session.displayedImage
        let exported = try await session.exportedData()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(exported as CFData, nil))
        let export = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(Double(export.width) / Double(export.height), Double(preview.width) / Double(preview.height), accuracy: 0.01,
                       "same aspect")
        XCTAssertGreaterThan(export.height, export.width, "the quarter turn is in the saved copy")
        let a = try rgba(preview, width: preview.width, height: preview.height)
        let b = try rgba(export, width: preview.width, height: preview.height)
        var total = 0.0
        for i in 0..<a.count where i % 4 != 3 { total += abs(Double(a[i]) - Double(b[i])) }
        let mean = total / Double(a.count / 4 * 3)
        XCTAssertLessThan(mean, 4, "the saved copy shows what the preview shows (mean |Δ| \(mean) of 255)")
    }

    private func rgba(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }
}
