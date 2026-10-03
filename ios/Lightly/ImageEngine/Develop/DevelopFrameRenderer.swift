import CoreGraphics
import Foundation
import simd

/// Applies LUT passes on the GPU: the encoded RGBA8 result, or the float result before encoding
/// (which the CPU pixel stages continue from). `MetalLUTRenderer` in the app.
protocol DevelopLUTApplying: Sendable {
    func apply(_ passes: [LUT3D], toRGBA8 pixels: [UInt8], width: Int, height: Int, maximumTileSide: Int) throws -> [UInt8]
    func applyUnencoded(_ passes: [LUT3D], toRGBA8 pixels: [UInt8], width: Int, height: Int) throws -> [SIMD4<Float>]
}

extension MetalLUTRenderer: DevelopLUTApplying {}

/// What a recipe asks the Develop stages to do to the pixels, resolved against the pack.
///
/// Built from the committed (or previewed) recipe: Auto is stage 1 (no model ships, so it is never
/// present), then the Look at its Amount. Spatial and finishing amounts are already multiplied by
/// the Amount (rendering-v2 §4.2).
struct DevelopRenderPlan: Sendable {
    /// The preset's global LUT blended toward identity by the Amount; nil = no Look.
    let lookLUT: LUT3D?
    let spatial: PresetRecipe.Spatial
    let finishing: PresetRecipe.Finishing
    /// The preset the plan came from, for the review evidence.
    let presetID: String?

    static let identity = DevelopRenderPlan(lookLUT: nil, spatial: .init(), finishing: .init(), presetID: nil)

    var isIdentity: Bool { lookLUT == nil && spatial.isEmpty && finishing.isEmpty }
    var hasPixelStages: Bool { !spatial.isEmpty || !finishing.isEmpty }

    /// The plan for a Look at `strength` (Amount / 100). Strength 0 changes nothing.
    static func look(_ preset: PresetPack.Preset, strength: Double, cache: DevelopLUTCache) -> DevelopRenderPlan {
        guard strength > 0 else { return .identity }
        let lut = cache.lut(for: preset)
        var spatial = preset.recipe.spatial
        if var nr = spatial.noiseReduction {
            nr.luminance *= strength
            nr.color *= strength
            spatial.noiseReduction = nr.luminance == 0 && nr.color == 0 ? nil : nr
        }
        spatial.clarity = spatial.clarity.map { $0 * strength }
        spatial.texture = spatial.texture.map { $0 * strength }
        if var sharpening = spatial.sharpening {
            sharpening.amount *= strength
            spatial.sharpening = sharpening
        }
        return DevelopRenderPlan(
            lookLUT: strength >= 1 ? lut : lut.blendedTowardIdentity(strength: Float(strength)),
            spatial: spatial,
            // Finishing amounts are scaled by the evaluators (they take the strength).
            finishing: preset.recipe.finishing,
            presetID: preset.id,
            finishingStrength: strength)
    }

    /// Multiplier for the finishing amounts (vignette, grain).
    var finishingStrength: Double = 1

    init(lookLUT: LUT3D?, spatial: PresetRecipe.Spatial, finishing: PresetRecipe.Finishing, presetID: String?,
         finishingStrength: Double = 1) {
        self.lookLUT = lookLUT
        self.spatial = spatial
        self.finishing = finishing
        self.presetID = presetID
        self.finishingStrength = finishingStrength
    }
}

/// Renders the Develop stages of one frame (preview or export) from RGBA8 sRGB pixels: the global
/// LUT on the GPU, then spatial and finishing on the CPU, in tiles with a halo so memory stays
/// bounded at full resolution and tiles cannot seam.
struct DevelopFrameRenderer: Sendable {

    let lutApplier: any DevelopLUTApplying
    let model: DevelopModel

    /// Tile side for the CPU pixel stages (excluding the halo).
    static let tileSide = 1_024
    /// Long edge of the proxy clarity's large Gaussian is computed on (see DevelopPixelOperators).
    static let clarityProxyLongEdge = 256

    /// - Parameter includePixelStages: false renders the global stage only. Used for the first,
    ///   fast frame of a preview while the person scrubs; the full frame follows (see
    ///   `EditorSession`). Export always includes them.
    /// - Parameter includeFinishing: false leaves out the preset's vignette and grain, which belong
    ///   to stage 10 (Effects): when Background or Portrait edits exist they run in between, and
    ///   `finish(_:pixels:width:height:)` applies the finishing afterwards.
    func render(_ plan: DevelopRenderPlan, pixels: [UInt8], width: Int, height: Int,
                includePixelStages: Bool = true, includeFinishing: Bool = true,
                tileSide: Int = DevelopFrameRenderer.tileSide) throws -> [UInt8] {
        var plan = plan
        if !includeFinishing { plan = DevelopRenderPlan(lookLUT: plan.lookLUT, spatial: plan.spatial, finishing: .init(),
                                                        presetID: plan.presetID, finishingStrength: plan.finishingStrength) }
        guard !plan.isIdentity else { return pixels }
        let passes = plan.lookLUT.map { [$0] } ?? []
        guard includePixelStages, plan.hasPixelStages else {
            return passes.isEmpty ? pixels
                : try lutApplier.apply(passes, toRGBA8: pixels, width: width, height: height,
                                       maximumTileSide: MetalLUTRenderer.defaultMaximumTileSide)
        }
        let longEdge = max(width, height)
        let halo = plan.spatial.isEmpty ? 0 : DevelopPixelOperators.haloPixels(for: plan.spatial, longEdge: longEdge, model: model)
        let clarityProxy = plan.spatial.clarity.map { _ in
            makeClarityProxy(plan: plan, pixels: pixels, width: width, height: height)
        }
        let vignette = plan.finishing.vignette.flatMap {
            DevelopPixelOperators.VignetteEvaluator($0, strength: plan.finishingStrength, frameWidth: width, frameHeight: height, model: model)
        }
        let grain = plan.finishing.grain.flatMap {
            DevelopPixelOperators.GrainEvaluator($0, strength: plan.finishingStrength, frameWidth: width, frameHeight: height, model: model)
        }

        var output = [UInt8](repeating: 255, count: width * height * 4)
        for tile in MetalLUTRenderer.tiles(width: width, height: height, maximumSide: tileSide) {
            // Export runs in a task that Save copy › Cancel cancels: stop between tiles.
            try Task.checkCancellation()
            // The region is the tile plus the halo, clipped to the frame.
            let x0 = max(tile.x - halo, 0), y0 = max(tile.y - halo, 0)
            let x1 = min(tile.x + tile.width + halo, width), y1 = min(tile.y + tile.height + halo, height)
            let regionWidth = x1 - x0, regionHeight = y1 - y0
            var regionPixels = [UInt8](repeating: 0, count: regionWidth * regionHeight * 4)
            for row in 0..<regionHeight {
                let from = ((y0 + row) * width + x0) * 4
                regionPixels.replaceSubrange(row * regionWidth * 4..<(row + 1) * regionWidth * 4,
                                             with: pixels[from..<from + regionWidth * 4])
            }
            let floats = passes.isEmpty
                ? regionPixels.withUnsafeBufferPointer { bytes in
                    (0..<(regionWidth * regionHeight)).map { i in
                        SIMD4<Float>(Float(bytes[i * 4]) / 255, Float(bytes[i * 4 + 1]) / 255, Float(bytes[i * 4 + 2]) / 255, 1)
                    }
                }
                : try lutApplier.applyUnencoded(passes, toRGBA8: regionPixels, width: regionWidth, height: regionHeight)

            var colours = floats.map { DevelopPixelOperators.simdClamp(SIMD3($0.x, $0.y, $0.z)) }
            if !plan.spatial.isEmpty {
                colours = applySpatial(plan.spatial, floats: floats, regionOrigin: (x0, y0), regionSize: (regionWidth, regionHeight),
                                           frameSize: (width, height), clarityProxy: clarityProxy)
            }
            // Finishing and encoding, inner tile only.
            output.withUnsafeMutableBufferPointer { destination in
                let base = destination.baseAddress!
                colours.withUnsafeBufferPointer { source in
                    DispatchQueue.concurrentPerform(iterations: tile.height) { row in
                        let frameY = tile.y + row
                        for column in 0..<tile.width {
                            let frameX = tile.x + column
                            var colour = source[(frameY - y0) * regionWidth + (frameX - x0)]
                            if let vignette { colour = vignette.apply(colour, x: frameX, y: frameY) }
                            if let grain { colour = grain.apply(colour, x: frameX, y: frameY) }
                            let offset = (frameY * width + frameX) * 4
                            base[offset] = Self.encode8(colour.x)
                            base[offset + 1] = Self.encode8(colour.y)
                            base[offset + 2] = Self.encode8(colour.z)
                            base[offset + 3] = 255
                        }
                    }
                }
            }
        }
        return output
    }

    /// Stage 10's preset finishing (vignette, then grain) on an already-developed frame.
    func finish(_ plan: DevelopRenderPlan, pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        let vignette = plan.finishing.vignette.flatMap {
            DevelopPixelOperators.VignetteEvaluator($0, strength: plan.finishingStrength, frameWidth: width, frameHeight: height, model: model)
        }
        let grain = plan.finishing.grain.flatMap {
            DevelopPixelOperators.GrainEvaluator($0, strength: plan.finishingStrength, frameWidth: width, frameHeight: height, model: model)
        }
        guard vignette != nil || grain != nil else { return pixels }
        var output = pixels
        output.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    var colour = SIMD3<Float>(Float(base[o]) / 255, Float(base[o + 1]) / 255, Float(base[o + 2]) / 255)
                    if let vignette { colour = vignette.apply(colour, x: x, y: y) }
                    if let grain { colour = grain.apply(colour, x: x, y: y) }
                    base[o] = Self.encode8(colour.x); base[o + 1] = Self.encode8(colour.y); base[o + 2] = Self.encode8(colour.z)
                }
            }
        }
        return output
    }

    /// The reference rounding: x·255 + 0.5, clamped, truncated.
    @inline(__always)
    static func encode8(_ value: Float) -> UInt8 {
        UInt8(min(max(value * 255 + 0.5, 0), 255))
    }

    // MARK: - Spatial

    private struct ClarityProxy {
        let blurred: [Float]
        let width: Int
        let height: Int
    }

    // swiftlint:disable:next function_parameter_count
    private func applySpatial(_ spatial: PresetRecipe.Spatial, floats: [SIMD4<Float>], regionOrigin: (Int, Int),
                              regionSize: (Int, Int), frameSize: (Int, Int), clarityProxy: ClarityProxy?) -> [SIMD3<Float>] {
        let (regionWidth, regionHeight) = regionSize
        let frameLongEdge = max(frameSize.0, frameSize.1)
        var region = floats.withUnsafeBufferPointer {
            DevelopPixelOperators.toLab(rgb: $0, width: regionWidth, height: regionHeight)
        }
        if let nr = spatial.noiseReduction {
            DevelopPixelOperators.noiseReduction(&region, nr, frameLongEdge: frameLongEdge, model: model)
        }
        if spatial.clarity != nil || spatial.texture != nil {
            let largeBlur = clarityProxy.map { sampleProxy($0, regionOrigin: regionOrigin, regionSize: regionSize, frameSize: frameSize) }
            DevelopPixelOperators.clarityAndTexture(&region, clarity: spatial.clarity ?? 0, texture: spatial.texture ?? 0,
                                                    largeBlur: largeBlur, frameLongEdge: frameLongEdge, model: model)
        }
        if let sharpening = spatial.sharpening {
            DevelopPixelOperators.sharpening(&region, sharpening, frameLongEdge: frameLongEdge, model: model)
        }
        var colours = [SIMD3<Float>](repeating: .zero, count: regionWidth * regionHeight)
        colours.withUnsafeMutableBufferPointer { destination in
            let base = destination.baseAddress!
            DispatchQueue.concurrentPerform(iterations: regionHeight) { row in
                for column in 0..<regionWidth {
                    let i = row * regionWidth + column
                    base[i] = ColourMath.encoded(fromOKLab: SIMD3(region.lightness[i], region.a[i], region.b[i]))
                }
            }
        }
        return colours
    }

    /// The developed photo (global stage) at `clarityProxyLongEdge`, as OKLab L blurred by the
    /// clarity Gaussian at proxy scale.
    private func makeClarityProxy(plan: DevelopRenderPlan, pixels: [UInt8], width: Int, height: Int) -> ClarityProxy {
        let scale = Double(Self.clarityProxyLongEdge) / Double(max(width, height))
        let proxyWidth = max(1, Int((Double(width) * min(scale, 1)).rounded()))
        let proxyHeight = max(1, Int((Double(height) * min(scale, 1)).rounded()))
        var lightness = [Float](repeating: 0, count: proxyWidth * proxyHeight)
        let lut = plan.lookLUT
        for py in 0..<proxyHeight {
            let ys = py * height / proxyHeight, ye = max((py + 1) * height / proxyHeight, ys + 1)
            for px in 0..<proxyWidth {
                let xs = px * width / proxyWidth, xe = max((px + 1) * width / proxyWidth, xs + 1)
                // Box average of the source block (encoded values, as a downscaler would).
                var sum = SIMD3<Double>.zero
                for y in ys..<ye {
                    for x in xs..<xe {
                        let o = (y * width + x) * 4
                        sum += SIMD3(Double(pixels[o]), Double(pixels[o + 1]), Double(pixels[o + 2]))
                    }
                }
                var colour = sum / Double((ye - ys) * (xe - xs)) / 255
                if let lut { colour = Self.lookup(lut, colour) }
                lightness[py * proxyWidth + px] = ColourMath.oklab(fromEncoded: SIMD3<Float>(colour)).x
            }
        }
        let sigma = model.radiusClarity * Double(max(proxyWidth, proxyHeight))
        let blurred = DevelopPixelOperators.gaussianBlur(lightness, width: proxyWidth, height: proxyHeight, sigma: sigma,
                                                         frameLongEdge: max(proxyWidth, proxyHeight))
        return ClarityProxy(blurred: blurred, width: proxyWidth, height: proxyHeight)
    }

    /// Bilinear, half-pixel centres, from frame coordinates to the proxy.
    private func sampleProxy(_ proxy: ClarityProxy, regionOrigin: (Int, Int), regionSize: (Int, Int), frameSize: (Int, Int)) -> [Float] {
        let (regionWidth, regionHeight) = regionSize
        var out = [Float](repeating: 0, count: regionWidth * regionHeight)
        func axis(_ position: Int, _ frame: Int, _ proxyCount: Int) -> (Int, Int, Float) {
            let source = min(max((Double(position) + 0.5) * Double(proxyCount) / Double(frame) - 0.5, 0), Double(proxyCount - 1))
            let lower = Int(source.rounded(.down))
            return (lower, min(lower + 1, proxyCount - 1), Float(source - Double(lower)))
        }
        for row in 0..<regionHeight {
            let (y0, y1, fy) = axis(regionOrigin.1 + row, frameSize.1, proxy.height)
            for column in 0..<regionWidth {
                let (x0, x1, fx) = axis(regionOrigin.0 + column, frameSize.0, proxy.width)
                let top = proxy.blurred[y0 * proxy.width + x0] * (1 - fx) + proxy.blurred[y0 * proxy.width + x1] * fx
                let bottom = proxy.blurred[y1 * proxy.width + x0] * (1 - fx) + proxy.blurred[y1 * proxy.width + x1] * fx
                out[row * regionWidth + column] = top * (1 - fy) + bottom * fy
            }
        }
        return out
    }

    /// CPU trilinear lookup in an RGBA LUT3D (the same arithmetic as the Metal kernel).
    static func lookup(_ lut: LUT3D, _ colour: SIMD3<Double>) -> SIMD3<Double> {
        let n = lut.dimension
        let position = simd_clamp(colour, .zero, .one) * Double(n - 1)
        let cell = SIMD3<Int>(min(max(Int(position.x), 0), n - 2), min(max(Int(position.y), 0), n - 2), min(max(Int(position.z), 0), n - 2))
        let f = position - SIMD3(Double(cell.x), Double(cell.y), Double(cell.z))
        var out = SIMD3<Double>.zero
        for db in 0...1 {
            for dg in 0...1 {
                for dr in 0...1 {
                    let w = (dr == 1 ? f.x : 1 - f.x) * (dg == 1 ? f.y : 1 - f.y) * (db == 1 ? f.z : 1 - f.z)
                    let index = (((cell.z + db) * n + (cell.y + dg)) * n + (cell.x + dr)) * 4
                    out += SIMD3(Double(lut.values[index]), Double(lut.values[index + 1]), Double(lut.values[index + 2])) * w
                }
            }
        }
        return out
    }
}
