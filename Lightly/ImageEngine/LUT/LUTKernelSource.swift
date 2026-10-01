/// Metal source for the LUT stages, compiled at runtime by `MetalLUTRenderer`.
///
/// Why source and not a `.metal` file: the build machine has no Metal
/// Toolchain component, so an offline `.metal` file breaks the build.
/// Runtime compilation needs no toolchain and works on device and simulator;
/// it costs a one-off compile when the renderer is created. Deferred: move
/// this to a `.metal` file once the toolchain is installed
/// (`xcodebuild -downloadComponent MetalToolchain`), keeping this text as is.
///
/// Rendering contract v1, spec §4.1/§4.2. Trilinear interpolation is done by
/// hand from eight `read`s of a float 3D texture rather than a hardware
/// `sample`: texture filtering interpolates with reduced-precision weights,
/// the likely cause of CIColorCube's 5/255 error against the golden set.
/// Manual float32 weights follow the reference exactly: pos = v·(N−1),
/// cell = clamp(floor(pos), 0, N−2), frac = pos − cell, accumulated r→g→b.
enum LUTKernelSource {
    static let text = """
    #include <metal_stdlib>
    using namespace metal;

    // §4.2: every stage clamps its *input* to [0,1]; LUT entries are never
    // clamped, so a stage's output may leave [0,1].
    static float3 apply_lut_stage(float3 colour, texture3d<float, access::read> lut) {
        const int n = int(lut.get_width());
        const float3 x = clamp(colour, 0.0f, 1.0f);
        const float3 position = x * float(n - 1);
        const int3 cell = clamp(int3(floor(position)), int3(0), int3(n - 2));
        const float3 frac = position - float3(cell);

        float3 result = float3(0.0f);
        for (int dr = 0; dr < 2; ++dr) {
            const float wr = dr ? frac.x : 1.0f - frac.x;
            for (int dg = 0; dg < 2; ++dg) {
                const float wg = dg ? frac.y : 1.0f - frac.y;
                for (int db = 0; db < 2; ++db) {
                    const float wb = db ? frac.z : 1.0f - frac.z;
                    const uint3 texel = uint3(cell + int3(dr, dg, db));
                    result += (wr * wg * wb) * lut.read(texel).rgb;
                }
            }
        }
        return result;
    }

    // First stage: 8-bit sRGB-encoded source -> unclamped float.
    kernel void lut_stage_from_rgba8(device const uchar4 *source [[buffer(0)]],
                                     device float4 *destination [[buffer(1)]],
                                     constant uint &pixelCount [[buffer(2)]],
                                     texture3d<float, access::read> lut [[texture(0)]],
                                     uint index [[thread_position_in_grid]]) {
        if (index >= pixelCount) { return; }
        const float3 colour = float3(source[index].rgb) / 255.0f;
        destination[index] = float4(apply_lut_stage(colour, lut), 1.0f);
    }

    // Later stages: float -> float. The intermediate stays float32, so an
    // out-of-range Auto output is clamped by the next stage's input rule.
    kernel void lut_stage_from_float(device const float4 *source [[buffer(0)]],
                                     device float4 *destination [[buffer(1)]],
                                     constant uint &pixelCount [[buffer(2)]],
                                     texture3d<float, access::read> lut [[texture(0)]],
                                     uint index [[thread_position_in_grid]]) {
        if (index >= pixelCount) { return; }
        destination[index] = float4(apply_lut_stage(source[index].rgb, lut), 1.0f);
    }

    // O4: clamp once and encode 8-bit with the reference rounding
    // (x*255 + 0.5, clamp to [0,255], truncate).
    kernel void encode_rgba8(device const float4 *source [[buffer(0)]],
                             device uchar4 *destination [[buffer(1)]],
                             constant uint &pixelCount [[buffer(2)]],
                             uint index [[thread_position_in_grid]]) {
        if (index >= pixelCount) { return; }
        const float3 scaled = clamp(source[index].rgb * 255.0f + 0.5f, 0.0f, 255.0f);
        destination[index] = uchar4(uchar3(scaled), 255);
    }
    """
}
