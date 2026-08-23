import Accelerate
import CoreGraphics
import Foundation

/// Analyses photographs using histogram and statistical methods.
///
/// All analysis uses the Accelerate framework for performance. No Core ML
/// models are involved — scene classification and quality models arrive in
/// Phase 4 (spec §23). The heuristic approach here is sufficient to produce
/// genuinely adaptive per-photograph recipes that satisfy the spec §5
/// requirement that Develop "analyses" the image.
///
/// Implemented as an actor to safely cache reusable intermediate context buffers
/// if necessary (a Phase 4 optimization).
actor HistogramAnalyser: ImageAnalysing {

    func analyse(_ image: CGImage) async throws -> ImageAnalysis {
        let width = image.width
        let height = image.height
        let pixelCount = width * height
        
        guard pixelCount > 0 else {
            throw LightlyError.developFailed
        }

        // 1. Extract raw RGBA data
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height
        var pixelData = [UInt8](repeating: 0, count: totalBytes)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw LightlyError.developFailed
        }

        // Extracting image pixels natively
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Convert [UInt8] to [Float] for vDSP
        var floatPixels = [Float](repeating: 0, count: totalBytes)
        vDSP_vfltu8(pixelData, 1, &floatPixels, 1, vDSP_Length(totalBytes))

        // Extract R, G, B channels
        var rChannel = [Float](repeating: 0, count: pixelCount)
        var gChannel = [Float](repeating: 0, count: pixelCount)
        var bChannel = [Float](repeating: 0, count: pixelCount)

        // Strided copy to split channels
        floatPixels.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            cblas_scopy(Int32(pixelCount), base, 4, &rChannel, 1)
            cblas_scopy(Int32(pixelCount), base + 1, 4, &gChannel, 1)
            cblas_scopy(Int32(pixelCount), base + 2, 4, &bChannel, 1)
        }

        // Compute means
        var meanR: Float = 0
        var meanG: Float = 0
        var meanB: Float = 0
        vDSP_meanv(rChannel, 1, &meanR, vDSP_Length(pixelCount))
        vDSP_meanv(gChannel, 1, &meanG, vDSP_Length(pixelCount))
        vDSP_meanv(bChannel, 1, &meanB, vDSP_Length(pixelCount))

        // Normalise means (0...1)
        let normR = meanR / 255.0
        let normG = meanG / 255.0
        let normB = meanB / 255.0

        // 2. White balance estimation (gray-world assumption)
        let rgRatio = normG > 0 ? (normR / normG) : 1.0
        let bgRatio = normG > 0 ? (normB / normG) : 1.0

        let tempOffset = Double(rgRatio - 1.0) * 100.0
        let tintOffset = Double(bgRatio - 1.0) * 100.0

        // 3. Luminance histogram and contrast computation
        var luminance = [Float](repeating: 0, count: pixelCount)
        var rCoeff: Float = 0.2126
        var gCoeff: Float = 0.7152
        var bCoeff: Float = 0.0722
        // L = 0.2126*R + 0.7152*G + 0.0722*B
        vDSP_vsmul(rChannel, 1, &rCoeff, &luminance, 1, vDSP_Length(pixelCount))

        // G contribution: temp = G * gCoeff, then luminance += temp
        var gScaled = [Float](repeating: 0, count: pixelCount)
        vDSP_vsmul(gChannel, 1, &gCoeff, &gScaled, 1, vDSP_Length(pixelCount))
        vDSP_vadd(luminance, 1, gScaled, 1, &luminance, 1, vDSP_Length(pixelCount))

        // B contribution: temp = B * bCoeff, then luminance += temp
        var bScaled = [Float](repeating: 0, count: pixelCount)
        vDSP_vsmul(bChannel, 1, &bCoeff, &bScaled, 1, vDSP_Length(pixelCount))
        vDSP_vadd(luminance, 1, bScaled, 1, &luminance, 1, vDSP_Length(pixelCount))

        var meanLum255: Float = 0
        vDSP_meanv(luminance, 1, &meanLum255, vDSP_Length(pixelCount))
        let meanLuminance = meanLum255 / 255.0

        // Standard deviation for contrast
        var sumOfSquares: Float = 0
        vDSP_svesq(luminance, 1, &sumOfSquares, vDSP_Length(pixelCount))
        let variance = (sumOfSquares / Float(pixelCount)) - (meanLum255 * meanLum255)
        let stdDev = variance > 0 ? sqrt(variance) : 0
        let contrastSpread = stdDev / 255.0

        // Extract clipping ratios from a histogram of luminance
        var lumUInt8 = [UInt8](repeating: 0, count: pixelCount)
        vDSP_vfixru8(luminance, 1, &lumUInt8, 1, vDSP_Length(pixelCount))

        var histogram = [Int](repeating: 0, count: 256)
        for val in lumUInt8 {
            histogram[Int(val)] += 1
        }

        let highlightCount = histogram[253] + histogram[254] + histogram[255]
        let highlightClippingRatio = Float(highlightCount) / Float(pixelCount)

        let shadowCount = histogram[0] + histogram[1] + histogram[2]
        let shadowClippingRatio = Float(shadowCount) / Float(pixelCount)

        // 4. Noise estimation
        let noiseLevel = try estimateNoise(from: image)

        return ImageAnalysis(
            meanLuminance: meanLuminance,
            highlightClippingRatio: highlightClippingRatio,
            shadowClippingRatio: shadowClippingRatio,
            colorTemperatureOffset: tempOffset,
            tintOffset: tintOffset,
            contrastSpread: contrastSpread,
            noiseLevel: noiseLevel
        )
    }

    /// Estimates image noise using local variance in a downsampled version.
    private func estimateNoise(from image: CGImage) throws -> Float {
        let maxSide: CGFloat = 256
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(maxSide / width, maxSide / height)

        let smallWidth = max(8, Int(width * scale))
        let smallHeight = max(8, Int(height * scale))

        let bytesPerRow = smallWidth * 4
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * smallHeight)

        guard let context = CGContext(
            data: &pixelData,
            width: smallWidth,
            height: smallHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw LightlyError.developFailed
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))

        let blocksX = smallWidth / 8
        let blocksY = smallHeight / 8
        guard blocksX > 0 && blocksY > 0 else { return 0 }

        var blockVariances = [Float]()
        blockVariances.reserveCapacity(blocksX * blocksY)

        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                var sum: Float = 0
                var sumSq: Float = 0

                for y in 0..<8 {
                    for x in 0..<8 {
                        let px = (bx * 8) + x
                        let py = (by * 8) + y
                        let idx = (py * bytesPerRow) + (px * 4)
                        
                        let r = Float(pixelData[idx])
                        let g = Float(pixelData[idx + 1])
                        let b = Float(pixelData[idx + 2])
                        let lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0

                        sum += lum
                        sumSq += lum * lum
                    }
                }

                let mean = sum / 64.0
                let variance = (sumSq / 64.0) - (mean * mean)
                blockVariances.append(max(0, variance))
            }
        }

        blockVariances.sort()
        let p25Index = blockVariances.count / 4
        let noiseVariance = blockVariances[p25Index]

        return min(1.0, noiseVariance / 0.01)
    }
}
