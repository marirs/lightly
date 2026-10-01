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

    /// Applies `passes` to packed RGBA8 (sRGB-encoded) pixels; returns RGBA8.
    func apply(_ passes: [LUT3D], toRGBA8 pixels: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        let pixelCount = width * height
        let floats = try floatBuffer(applying: passes, toRGBA8: pixels, pixelCount: pixelCount)
        let encoded = try makeBuffer(length: pixelCount * 4)
        try run(encode, input: floats, output: encoded, lut: nil, pixelCount: pixelCount)
        return Array(UnsafeBufferPointer(start: encoded.contents().assumingMemoryBound(to: UInt8.self), count: pixelCount * 4))
    }

    /// The float result before the final clamp and encode. Exposed so tests
    /// can prove out-of-range LUT entries survive (no 8-bit clamping).
    func applyUnencoded(_ passes: [LUT3D], toRGBA8 pixels: [UInt8], width: Int, height: Int) throws -> [SIMD4<Float>] {
        let pixelCount = width * height
        let floats = try floatBuffer(applying: passes, toRGBA8: pixels, pixelCount: pixelCount)
        return Array(UnsafeBufferPointer(start: floats.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: pixelCount))
    }

    // MARK: - Passes

    private func floatBuffer(applying passes: [LUT3D], toRGBA8 pixels: [UInt8], pixelCount: Int) throws -> MTLBuffer {
        guard pixels.count == pixelCount * 4 else { throw LUTError.renderFailed("pixel buffer size mismatch") }
        // No passes still means "convert to float", via the identity LUT, so
        // the encode stage always sees the same input type.
        let chain = passes.isEmpty ? [LUT3D.identity()] : passes
        let source = try pixels.withUnsafeBytes { bytes -> MTLBuffer in
            guard let buffer = device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared) else {
                throw LUTError.renderFailed("cannot allocate source buffer")
            }
            return buffer
        }
        var current = try makeBuffer(length: pixelCount * MemoryLayout<SIMD4<Float>>.stride)
        try run(firstStage, input: source, output: current, lut: try makeTexture(chain[0]), pixelCount: pixelCount)
        for lut in chain.dropFirst() {
            let next = try makeBuffer(length: pixelCount * MemoryLayout<SIMD4<Float>>.stride)
            try run(laterStage, input: current, output: next, lut: try makeTexture(lut), pixelCount: pixelCount)
            current = next
        }
        return current
    }

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
