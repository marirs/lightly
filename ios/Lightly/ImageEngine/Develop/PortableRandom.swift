import Foundation

/// The contract's portable random source (rendering-v2 §6 F2): integer hashes and a Box-Muller
/// normal field, identical on every platform so preview and export get the same grain everywhere.
enum PortableRandom {

    /// C. Wellons' lowbias32, all arithmetic modulo 2³².
    @inline(__always)
    static func lowbias32(_ input: UInt32) -> UInt32 {
        var x = input
        x ^= x >> 16
        x = x &* 0x7FEB_352D
        x ^= x >> 15
        x = x &* 0x846C_A68B
        x ^= x >> 16
        return x
    }

    /// Standard normal values at integer cells `(i, j)`, row-major `rows × cols`.
    static func gaussianField(seed: UInt32, layer: UInt32, rows: Int, cols: Int) -> [Double] {
        let base = lowbias32(seed ^ lowbias32(layer))
        var field = [Double](repeating: 0, count: rows * cols)
        for i in 0..<rows {
            let rowHash = UInt32(truncatingIfNeeded: UInt64(i) &* 0x9E37_79B1)
            for j in 0..<cols {
                let h1 = lowbias32(base ^ lowbias32(rowHash ^ lowbias32(UInt32(j))))
                let h2 = lowbias32(h1 ^ 0x85EB_CA6B)
                let u1 = (Double(h1 >> 8) + 0.5) / 16_777_216
                let u2 = (Double(h2 >> 8) + 0.5) / 16_777_216
                field[i * cols + j] = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
            }
        }
        return field
    }
}
