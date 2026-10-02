import Foundation

/// A 3D colour lookup table in the rendering contract's layout (spec §4.2).
///
/// RGBA float32, red fastest: `index = r + N·g + N²·b`, sRGB-encoded domain
/// and codomain. Entries may lie outside [0,1] (Auto LUTs span roughly
/// −0.14…1.35); they are kept as floats and never clamped here — the
/// contract clamps a stage's *input* and the final output only.
struct LUT3D: Equatable, Sendable {

    static let contractDimension = 33
    static let channels = 4

    let dimension: Int
    /// `dimension³ × 4` floats, RGBA, red fastest.
    let values: [Float]

    init(dimension: Int, values: [Float]) throws {
        guard dimension >= 2, values.count == dimension * dimension * dimension * Self.channels else {
            throw LUTError.invalidSize(dimension: dimension, valueCount: values.count)
        }
        self.dimension = dimension
        self.values = values
    }

    /// Loads a raw little-endian float32 file (as written by the desktop
    /// reference, e.g. `fused_lut.f32`).
    init(contentsOf url: URL, dimension: Int = contractDimension) throws {
        let data = try Data(contentsOf: url)
        let expectedBytes = dimension * dimension * dimension * Self.channels * MemoryLayout<Float>.size
        guard data.count == expectedBytes else {
            throw LUTError.invalidSize(dimension: dimension, valueCount: data.count / MemoryLayout<Float>.size)
        }
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        try self.init(dimension: dimension, values: floats)
    }

    /// The exact identity LUT.
    static func identity(dimension: Int = contractDimension) -> LUT3D {
        lut(dimension: dimension) { $0 }
    }

    /// Builds a LUT by evaluating `transform` at every grid colour.
    static func lut(dimension: Int, _ transform: (SIMD3<Float>) -> SIMD3<Float>) -> LUT3D {
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * channels)
        let step = 1 / Float(dimension - 1)
        for b in 0..<dimension {
            for g in 0..<dimension {
                for r in 0..<dimension {
                    let output = transform(SIMD3(Float(r) * step, Float(g) * step, Float(b) * step))
                    values += [output.x, output.y, output.z, 1]
                }
            }
        }
        // Size is correct by construction.
        return try! LUT3D(dimension: dimension, values: values)
    }

    /// Strength blend toward identity, `I + s·(L − I)` (spec §4.2).
    func blendedTowardIdentity(strength: Float) -> LUT3D {
        let identity = Self.identity(dimension: dimension).values
        let blended = zip(values, identity).map { lutValue, identityValue in
            identityValue + strength * (lutValue - identityValue)
        }
        return try! LUT3D(dimension: dimension, values: blended)
    }
}

enum LUTError: Error, Equatable {
    case invalidSize(dimension: Int, valueCount: Int)
    case metalUnavailable(String)
    case renderFailed(String)
}
