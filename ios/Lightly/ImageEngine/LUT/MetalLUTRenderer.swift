import CoreGraphics
import Foundation
import Metal

/// Applies a chain of 3D LUTs on the GPU, one pass per LUT (spec §4.1).
///
/// Auto and Look are separate passes on purpose: baking them into one LUT
/// was measured at up to 6/255 error (m1 941ff9d), so the contract forbids
/// it by default. Between passes the image stays float32; each pass clamps
/// its input to [0,1]; the result is clamped and rounded to 8-bit once.
///
/// Deferred: tiling for very large images. Each pass holds a float4 buffer
/// for the whole frame (16 B/px), which is fine for previews and for the
/// golden tests on the simulator but must be tiled before full-resolution
/// export on device. On-device verification (SE 3, 11 Pro Max) is a later
/// step; the simulator GPU is not the device GPU.
final class MetalLUTRenderer: @unchecked Sendable {
    // @unchecked: all stored state is immutable after init, and Metal
    // devices, queues and pipeline states are documented as thread-safe.

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let firstStage: MTLComputePipelineState
    private let laterStage: MTLComputePipelineState
    private let encode: MTLComputePipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw LUTError.metalUnavailable("no Metal device")
        }
        let library: MTLLibrary
        do {
            // Fast math off: the golden comparison relies on IEEE float
            // behaviour matching the desktop reference.
            let options = MTLCompileOptions()
            if #available(iOS 18.0, *) {
                options.mathMode = .safe
            } else {
                options.fastMathEnabled = false
            }
            library = try device.makeLibrary(source: LUTKernelSource.text, options: options)
        } catch {
            throw LUTError.metalUnavailable("LUT kernels failed to compile: \(error)")
        }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw LUTError.metalUnavailable("kernel \(name) missing")
            }
            return try device.makeComputePipelineState(function: function)
        }
        self.device = device
        self.queue = queue
        self.firstStage = try pipeline("lut_stage_from_rgba8")
        self.laterStage = try pipeline("lut_stage_from_float")
        self.encode = try pipeline("encode_rgba8")
    }

    // MARK: - Public

    /// Applies `passes` in order to an image and returns 8-bit sRGB.
    func apply(_ passes: [LUT3D], to image: CGImage) throws -> CGImage {
        let width = image.width, height = image.height
        let output = try apply(passes, toRGBA8: Self.rgba8Bytes(of: image), width: width, height: height)
        return try Self.makeImage(rgba8: output, width: width, height: height)
    }

    static let defaultMaximumTileSide = 2_048

    /// What the last `apply` cost, for tests and diagnostics.
    struct RenderStatistics: Equatable, Sendable {
        var tileCount = 0
        /// Largest total of GPU buffer/texture bytes alive at once.
        var peakBufferBytes = 0
    }

    private let statisticsLock = NSLock()
    private var currentStatistics = RenderStatistics()
    private var liveBufferBytes = 0
    private(set) var lastRenderStatistics: RenderStatistics? {
        get { statisticsLock.withLock { storedLastStatistics } }
        set { statisticsLock.withLock { storedLastStatistics = newValue } }
    }
    private var storedLastStatistics: RenderStatistics?

    /// Applies `passes` to packed RGBA8 (sRGB-encoded) pixels; returns RGBA8.
    ///
    /// Rendered in tiles of at most `maximumTileSide`², reusing one set of
    /// GPU buffers, so GPU working memory is ~40 B × tile area instead of
    /// 16 B/px of float for the whole frame (a 48 MP frame would need
    /// ~0.8 GB per float pass). LUT stages are per-pixel, so tiles need no
    /// overlap and cannot seam. Deferred: spatial operators (grain,
    /// vignette, local contrast) will need a halo per tile when they land.
    func apply(
        _ passes: [LUT3D], toRGBA8 pixels: [UInt8], width: Int, height: Int,
        maximumTileSide: Int = defaultMaximumTileSide
    ) throws -> [UInt8] {
        // Metal returns its buffers, textures and command buffers autoreleased. Off the main thread nothing drains
        // them until the calling task ends, so every call's GPU workspace stayed alive through a whole Save copy
        // (2026-10-07, 48 MP in the Simulator: about 1 GB left after the render). Each call drains its own.
        try autoreleasepool { try renderLock.withLock {
            var output = [UInt8](repeating: 0, count: pixels.count)
            try render(passes, pixels: pixels, width: width, height: height, maximumTileSide: maximumTileSide) { tile, workspace in
                try run(encode, input: workspace.finalFloats, output: workspace.encoded, lut: nil, pixelCount: tile.area)
                Self.copyRows(from: workspace.encoded, tile: tile, imageWidth: width, bytesPerPixel: 4, into: &output)
            }
            return output
        } }
    }

    /// The float result before the final clamp and encode. Exposed so tests
    /// can prove out-of-range LUT entries survive (no 8-bit clamping).
    func applyUnencoded(_ passes: [LUT3D], toRGBA8 pixels: [UInt8], width: Int, height: Int) throws -> [SIMD4<Float>] {
        // As `apply`: drain this call's autoreleased Metal objects (Develop calls this once per tile).
        try autoreleasepool { try renderLock.withLock {
            var output = [SIMD4<Float>](repeating: .zero, count: width * height)
            try render(passes, pixels: pixels, width: width, height: height, maximumTileSide: Self.defaultMaximumTileSide) { tile, workspace in
                let floats = workspace.finalFloats.contents().assumingMemoryBound(to: SIMD4<Float>.self)
                for row in 0..<tile.height {
                    for column in 0..<tile.width {
                        output[(tile.y + row) * width + tile.x + column] = floats[row * tile.width + column]
                    }
                }
            }
            return output
        } }
    }

    // MARK: - Tiles

    /// Serialises renders: they share the statistics and one GPU queue.
    private let renderLock = NSLock()

    struct Tile: Equatable {
        let x: Int, y: Int, width: Int, height: Int
        var area: Int { width * height }
    }

    static func tiles(width: Int, height: Int, maximumSide: Int) -> [Tile] {
        let side = max(1, maximumSide)
        return stride(from: 0, to: height, by: side).flatMap { y in
            stride(from: 0, to: width, by: side).map { x in
                Tile(x: x, y: y, width: min(side, width - x), height: min(side, height - y))
            }
        }
    }

    /// GPU buffers sized for the largest tile and reused for every tile.
    private struct Workspace {
        let source: MTLBuffer
        let floatsA: MTLBuffer
        let floatsB: MTLBuffer
        let encoded: MTLBuffer
        var finalFloats: MTLBuffer
    }

    private func makeWorkspace(capacity: Int) throws -> Workspace {
        let floatBytes = capacity * MemoryLayout<SIMD4<Float>>.stride
        let floatsA = try makeBuffer(length: floatBytes)
        return Workspace(
            source: try makeBuffer(length: capacity * 4),
            floatsA: floatsA,
            floatsB: try makeBuffer(length: floatBytes),
            encoded: try makeBuffer(length: capacity * 4),
            finalFloats: floatsA
        )
    }

    private func render(
        _ passes: [LUT3D], pixels: [UInt8], width: Int, height: Int, maximumTileSide: Int,
        finish: (Tile, Workspace) throws -> Void
    ) throws {
        guard width > 0, height > 0, pixels.count == width * height * 4 else {
            throw LUTError.renderFailed("pixel buffer size mismatch")
        }
        beginStatistics()
        // No passes still means "convert to float", via the identity LUT, so
        // the encode stage always sees the same input type.
        let textures = try (passes.isEmpty ? [LUT3D.identity()] : passes).map(makeTexture)
        let tiles = Self.tiles(width: width, height: height, maximumSide: maximumTileSide)
        var workspace = try makeWorkspace(capacity: tiles.map(\.area).max() ?? 0)

        for tile in tiles {
            Self.copyRows(of: pixels, tile: tile, imageWidth: width, into: workspace.source)
            workspace.finalFloats = try runPasses(textures, workspace: workspace, pixelCount: tile.area)
            try finish(tile, workspace)
            currentStatistics.tileCount += 1
        }
        lastRenderStatistics = currentStatistics
    }

    /// First pass reads 8-bit; later passes ping-pong between float buffers.
    private func runPasses(_ textures: [MTLTexture], workspace: Workspace, pixelCount: Int) throws -> MTLBuffer {
        var current = workspace.floatsA, spare = workspace.floatsB
        try run(firstStage, input: workspace.source, output: current, lut: textures[0], pixelCount: pixelCount)
        for texture in textures.dropFirst() {
            try run(laterStage, input: current, output: spare, lut: texture, pixelCount: pixelCount)
            swap(&current, &spare)
        }
        return current
    }

    private static func copyRows(of pixels: [UInt8], tile: Tile, imageWidth: Int, into buffer: MTLBuffer) {
        let destination = buffer.contents().assumingMemoryBound(to: UInt8.self)
        pixels.withUnsafeBufferPointer { source in
            for row in 0..<tile.height {
                let from = ((tile.y + row) * imageWidth + tile.x) * 4
                (destination + row * tile.width * 4).update(from: source.baseAddress! + from, count: tile.width * 4)
            }
        }
    }

    private static func copyRows(from buffer: MTLBuffer, tile: Tile, imageWidth: Int, bytesPerPixel: Int, into output: inout [UInt8]) {
        let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
        output.withUnsafeMutableBufferPointer { destination in
            for row in 0..<tile.height {
                let to = ((tile.y + row) * imageWidth + tile.x) * bytesPerPixel
                (destination.baseAddress! + to).update(from: source + row * tile.width * bytesPerPixel, count: tile.width * bytesPerPixel)
            }
        }
    }

    private func beginStatistics() {
        currentStatistics = RenderStatistics()
        liveBufferBytes = 0
    }

    private func account(allocatedBytes: Int) {
        liveBufferBytes += allocatedBytes
        currentStatistics.peakBufferBytes = max(currentStatistics.peakBufferBytes, liveBufferBytes)
    }

    // MARK: - Passes

    private func run(
        _ pipeline: MTLComputePipelineState, input: MTLBuffer, output: MTLBuffer,
        lut: MTLTexture?, pixelCount: Int
    ) throws {
        guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw LUTError.renderFailed("cannot create command encoder")
        }
        var count = UInt32(pixelCount)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 2)
        if let lut { encoder.setTexture(lut, index: 0) }
        let width = pipeline.threadExecutionWidth
        let groups = (pixelCount + width - 1) / width
        encoder.dispatchThreadgroups(
            MTLSize(width: groups, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw LUTError.renderFailed("\(error)") }
    }

    // MARK: - Resources

    private func makeBuffer(length: Int) throws -> MTLBuffer {
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw LUTError.renderFailed("cannot allocate \(length) bytes")
        }
        // Counted for the whole call and never released early, so the
        // reported peak is an upper bound on what was alive at once.
        account(allocatedBytes: length)
        return buffer
    }

    /// Uploads a LUT as an rgba32Float 3D texture via a blit, which works for
    /// private textures on every GPU, including the simulator's.
    private func makeTexture(_ lut: LUT3D) throws -> MTLTexture {
        let n = lut.dimension
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba32Float
        descriptor.width = n
        descriptor.height = n
        descriptor.depth = n
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw LUTError.renderFailed("cannot allocate LUT texture")
        }
        let rowBytes = n * LUT3D.channels * MemoryLayout<Float>.size
        let staging = try lut.values.withUnsafeBytes { bytes -> MTLBuffer in
            guard let buffer = device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared) else {
                throw LUTError.renderFailed("cannot allocate LUT staging buffer")
            }
            return buffer
        }
        guard let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else {
            throw LUTError.renderFailed("cannot create blit encoder")
        }
        blit.copy(
            from: staging, sourceOffset: 0, sourceBytesPerRow: rowBytes, sourceBytesPerImage: rowBytes * n,
            sourceSize: MTLSize(width: n, height: n, depth: n),
            to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        account(allocatedBytes: 2 * rowBytes * n * n)   // texture + staging
        return texture
    }

    // MARK: - CGImage bridging

    /// RGBA8 bytes in sRGB. The pipeline guarantees sRGB input (spec §4.3);
    /// anything else is converted rather than reinterpreted.
    static func rgba8Bytes(of image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: ColorPipeline.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw LUTError.renderFailed("cannot read source pixels") }
        return pixels
    }

    static func makeImage(rgba8 pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: ColorPipeline.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else {
            throw LUTError.renderFailed("cannot create output image")
        }
        return image
    }
}
