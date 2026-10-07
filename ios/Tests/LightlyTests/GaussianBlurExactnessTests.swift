import XCTest
@testable import Lightly

/// The blur's speed-up (2026-10-07) must not change a single float: compared with the direct implementation it replaced.
final class GaussianBlurExactnessTests: XCTestCase {
    /// The implementation before 2026-10-07, verbatim in arithmetic (reflection on every tap, strided vertical pass).
    private func reference(_ plane: [Float], width: Int, height: Int, sigma requested: Double, frameLongEdge: Int) -> [Float] {
        let sigma = max(requested, 0.3)
        let radius = Int(min(max(3, (3 * sigma).rounded(.up)), Double(max(frameLongEdge / 2 - 1, 1))))
        var kernel = (-radius...radius).map { Float(exp(-0.5 * pow(Double($0) / sigma, 2))) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var horizontal = [Float](repeating: 0, count: plane.count)
        var output = [Float](repeating: 0, count: plane.count)
        for row in 0..<height {
            for column in 0..<width {
                var sum: Float = 0
                for tap in -radius...radius { sum += kernel[tap + radius] * plane[row * width + DevelopPixelOperators.reflect(column + tap, width)] }
                horizontal[row * width + column] = sum
            }
        }
        for row in 0..<height {
            for column in 0..<width {
                var sum: Float = 0
                for tap in -radius...radius { sum += kernel[tap + radius] * horizontal[DevelopPixelOperators.reflect(row + tap, height) * width + column] }
                output[row * width + column] = sum
            }
        }
        return output
    }

    func testGaussianBlurMatchesTheDirectReference() {
        var generator = SystemRandomNumberGenerator()
        for (width, height, sigma) in [(97, 61, 0.2), (97, 61, 2.4), (64, 128, 7.5), (300, 9, 11.0), (5, 40, 3.0)] {
            let plane = (0..<(width * height)).map { _ in Float.random(in: -0.5...1.5, using: &generator) }
            let fast = DevelopPixelOperators.gaussianBlur(plane, width: width, height: height, sigma: sigma, frameLongEdge: max(width, height))
            let direct = reference(plane, width: width, height: height, sigma: sigma, frameLongEdge: max(width, height))
            XCTAssertEqual(fast, direct, "\(width)x\(height) sigma \(sigma)")
        }
    }
}
