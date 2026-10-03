import Foundation

/// A point curve sampled into the 256-entry table the contract specifies (rendering-v2 §4.1 G7),
/// mirroring `reference_model.curve_table` and `apply_curve_table` line by line.
///
/// - 2 points: linear, holding the end values outside [x0, xN].
/// - 3 or more: a natural cubic spline (second derivative 0 at both ends), solved with the Thomas
///   algorithm exactly as the reference does, evaluated on clamp(t, x0, xN).
/// Samples are clamped to [0, 1] and stored as float32, as the reference stores them; lookup
/// widens them back to double.
struct ToneCurveTable: Equatable, Sendable {

    static let size = 256

    /// float32 samples at t = i/255, i = 0…255.
    let samples: [Float]

    init(points: [[Double]]) {
        let xs = points.map { $0[0] / 255 }
        let ys = points.map { $0[1] / 255 }
        let step = 1.0 / Double(Self.size - 1)
        let grid = (0..<Self.size).map { $0 == Self.size - 1 ? 1.0 : Double($0) * step }
        var out: [Double]
        if xs.count == 2 {
            out = grid.map { Self.linearInterpolation(xs: xs, ys: ys, at: $0) }
        } else {
            let second = Self.naturalSplineSecondDerivatives(xs: xs, ys: ys)
            out = grid.map { t in
                if t < xs[0] { return ys[0] }
                if t > xs[xs.count - 1] { return ys[ys.count - 1] }
                return Self.evaluateSpline(xs: xs, ys: ys, second: second, at: min(max(t, xs[0]), xs[xs.count - 1]))
            }
        }
        samples = out.map { Float(min(max($0, 0), 1)) }
    }

    /// `apply_curve_table`: p = clamp(x,0,1)·255, i = clamp(floor(p), 0, 254), linear between i and i+1.
    @inline(__always)
    func apply(_ x: Double) -> Double {
        let position = min(max(x, 0), 1) * Double(Self.size - 1)
        let index = min(max(Int(position.rounded(.down)), 0), Self.size - 2)
        let fraction = position - Double(index)
        return Double(samples[index]) * (1 - fraction) + Double(samples[index + 1]) * fraction
    }

    // MARK: - Reference algorithms

    /// `np.interp` for a two-point curve.
    private static func linearInterpolation(xs: [Double], ys: [Double], at t: Double) -> Double {
        if t <= xs[0] { return ys[0] }
        if t >= xs[1] { return ys[1] }
        let slope = (ys[1] - ys[0]) / (xs[1] - xs[0])
        return slope * (t - xs[0]) + ys[0]
    }

    /// Second derivatives at the knots (0 at both ends), the reference's tridiagonal solve.
    private static func naturalSplineSecondDerivatives(xs: [Double], ys: [Double]) -> [Double] {
        let n = xs.count
        var second = [Double](repeating: 0, count: n)
        guard n > 2 else { return second }
        let h = (0..<(n - 1)).map { xs[$0 + 1] - xs[$0] }
        let sub = Array(h[0..<(n - 2)])
        var diag = [Double](repeating: 0, count: n - 2)
        for i in 0..<(n - 2) { diag[i] = 2 * (h[i] + h[i + 1]) }
        let sup = Array(h[1..<(n - 1)])
        var rhs = [Double](repeating: 0, count: n - 2)
        for i in 0..<(n - 2) {
            let upper: Double = (ys[i + 2] - ys[i + 1]) / h[i + 1]
            let lower: Double = (ys[i + 1] - ys[i]) / h[i]
            rhs[i] = 6 * (upper - lower)
        }
        if n - 2 > 1 {
            for i in 1..<(n - 2) {
                let factor = sub[i] / diag[i - 1]
                diag[i] -= factor * sup[i - 1]
                rhs[i] -= factor * rhs[i - 1]
            }
        }
        var interior = [Double](repeating: 0, count: n - 2)
        interior[n - 3] = rhs[n - 3] / diag[n - 3]
        var i = n - 4
        while i >= 0 {
            interior[i] = (rhs[i] - sup[i] * interior[i + 1]) / diag[i]
            i -= 1
        }
        for k in 0..<(n - 2) { second[k + 1] = interior[k] }
        return second
    }

    private static func evaluateSpline(xs: [Double], ys: [Double], second: [Double], at q: Double) -> Double {
        let n = xs.count
        // np.searchsorted(xs, q, side="right") - 1, clipped to [0, n-2].
        var segment = 0
        while segment + 1 < n, xs[segment + 1] <= q { segment += 1 }
        segment = min(max(segment, 0), n - 2)
        let x0 = xs[segment], x1 = xs[segment + 1]
        let y0 = ys[segment], y1 = ys[segment + 1]
        let m0 = second[segment], m1 = second[segment + 1]
        let width = x1 - x0
        let a = (x1 - q) / width
        let b = (q - x0) / width
        return a * y0 + b * y1 + ((a * a * a - a) * m0 + (b * b * b - b) * m1) * width * width / 6
    }
}
