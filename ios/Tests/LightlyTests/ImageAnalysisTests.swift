import CoreGraphics
import XCTest
@testable import Lightly

final class ImageAnalysisTests: XCTestCase {

    private func makeSolidColorImage(r: UInt8, g: UInt8, b: UInt8, width: Int = 100, height: Int = 100) -> CGImage {
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let offset = i * 4
            pixelData[offset] = r
            pixelData[offset + 1] = g
            pixelData[offset + 2] = b
            pixelData[offset + 3] = 255
        }
        let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func makeImageWithClipping(blackPixels: Int = 0, whitePixels: Int = 0, totalPixels: Int = 10000) -> CGImage {
        let width = 100
        let height = 100
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<blackPixels {
            let offset = i * 4
            pixelData[offset] = 0
            pixelData[offset + 1] = 0
            pixelData[offset + 2] = 0
            pixelData[offset + 3] = 255
        }
        for i in 0..<whitePixels {
            let offset = (blackPixels + i) * 4
            pixelData[offset] = 255
            pixelData[offset + 1] = 255
            pixelData[offset + 2] = 255
            pixelData[offset + 3] = 255
        }
        for i in (blackPixels + whitePixels)..<totalPixels {
            let offset = i * 4
            pixelData[offset] = 128
            pixelData[offset + 1] = 128
            pixelData[offset + 2] = 128
            pixelData[offset + 3] = 255
        }
        let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    func testAnalyseDarkImage() async throws {
        let image = makeSolidColorImage(r: 30, g: 30, b: 30)
        let analyser = HistogramAnalyser()
        let analysis = try await analyser.analyse(image)

        XCTAssertLessThan(analysis.meanLuminance, 0.2)
    }

    func testAnalyseBrightImage() async throws {
        let image = makeSolidColorImage(r: 220, g: 220, b: 220)
        let analyser = HistogramAnalyser()
        let analysis = try await analyser.analyse(image)

        XCTAssertGreaterThan(analysis.meanLuminance, 0.7)
    }

    func testAnalyseNeutralImage() async throws {
        let image = TestFixtures.makeImage()
        let analyser = HistogramAnalyser()
        let analysis = try await analyser.analyse(image)

        XCTAssertGreaterThan(analysis.meanLuminance, 0.1)
        XCTAssertLessThan(analysis.meanLuminance, 0.9)
    }

    func testHighlightClippingDetection() async throws {
        let image = makeImageWithClipping(whitePixels: 500) // 5% of 10000 pixels
        let analyser = HistogramAnalyser()
        let analysis = try await analyser.analyse(image)

        XCTAssertGreaterThan(analysis.highlightClippingRatio, 0)
    }

    func testShadowClippingDetection() async throws {
        let image = makeImageWithClipping(blackPixels: 500) // 5% of 10000 pixels
        let analyser = HistogramAnalyser()
        let analysis = try await analyser.analyse(image)

        XCTAssertGreaterThan(analysis.shadowClippingRatio, 0)
    }
}
