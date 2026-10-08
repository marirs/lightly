import Foundation
import simd

/// Closed-form matting in a bounded crop. Known trimap pixels are fixed; only the uncertain pixels are solved.
/// Kept separate from Vision so the solver can be checked against the shared numerical fixtures before use.
enum LocalHairMatting {
    struct Result {
        let alpha: [Double]
        let converged: Bool
        let iterations: Int
    }

    /// RGB is interleaved sRGB in [0,1]. Trimap entries are 0, 1, or NaN for unknown.
    /// Cancellation and non-convergence never produce a replacement mask for the caller to adopt silently.
    static func solve(rgb: [Double], trimap: [Double], width: Int, height: Int,
                      initial: [Double], tolerance: Double = 1e-5,
                      maxIterations: Int = 512, maximumUnknownPixels: Int = 400_000,
                      checkpoint: () throws -> Void = {}) throws -> Result {
        let count = width * height
        precondition(width >= 3 && height >= 3 && rgb.count == count * 3)
        precondition(trimap.count == count && initial.count == count)
        var variables = [Int](repeating: -1, count: count)
        var pixels = [Int]()
        for i in 0..<count where trimap[i].isNaN { variables[i] = pixels.count; pixels.append(i) }
        guard !pixels.isEmpty else { return Result(alpha: trimap, converged: true, iterations: 0) }
        // The sparse system is the largest temporary allocation. A difficult, nearly all-unknown
        // crop must retain the existing Vision matte instead of exhausting the phone's memory.
        guard pixels.count <= maximumUnknownPixels else {
            return Result(alpha: initial, converged: false, iterations: 0)
        }
        let offsets = [-width-1, -width, -width+1, -1, 0, 1, width-1, width, width+1]
        var centres = [Int]()
        for y in 1..<(height-1) {
            if y % 32 == 0 { try checkpoint() }
            for x in 1..<(width-1) {
                let p = y * width + x
                if offsets.contains(where: { variables[p + $0] >= 0 }) { centres.append(p) }
            }
        }
        // A 3x3 window only links pixels in a 5x5 neighbourhood. Assemble that fixed stencil once;
        // CG then performs scalar sparse products instead of recomputing covariance products every iteration.
        var coefficients = [Double](repeating: 0, count: pixels.count * 25)
        var neighbours = [Int32](repeating: -1, count: pixels.count * 25)
        for (v, pixel) in pixels.enumerated() {
            let px = pixel % width, py = pixel / width
            for dy in -2...2 { for dx in -2...2 {
                let x = px + dx, y = py + dy
                if x >= 0 && x < width && y >= 0 && y < height {
                    neighbours[v*25+(dy+2)*5+dx+2] = Int32(variables[y*width+x])
                }
            } }
        }
        var rhs = [Double](repeating: 0, count: pixels.count)
        var diagonal = rhs
        for (k, centre) in centres.enumerated() {
            if k % 1024 == 0 { try checkpoint() }
            var mean = SIMD3<Double>(repeating: 0)
            for o in offsets {
                let p = (centre + o) * 3
                mean += SIMD3(rgb[p], rgb[p+1], rgb[p+2])
            }
            mean /= 9
            var covariance = simd_double3x3(diagonal: SIMD3(repeating: 1e-7 / 9))
            var deviation = [SIMD3<Double>]()
            for o in offsets {
                let c = (centre + o) * 3
                let d = SIMD3(rgb[c], rgb[c+1], rgb[c+2]) - mean
                deviation.append(d)
                covariance += simd_double3x3(columns: (d * (d.x / 9), d * (d.y / 9), d * (d.z / 9)))
            }
            let inverse = covariance.inverse
            for i in 0..<9 {
                let vi = variables[centre+offsets[i]]
                guard vi >= 0 else { continue }
                let projected = inverse * deviation[i]
                for j in 0..<9 {
                    let value = (i == j ? 1.0 : 0.0) - (1 + simd_dot(projected, deviation[j])) / 9
                    let pj = centre + offsets[j]
                    if variables[pj] < 0 { rhs[vi] -= value * trimap[pj] }
                    else {
                        let slot = (j / 3 - i / 3 + 2) * 5 + j % 3 - i % 3 + 2
                        coefficients[vi*25+slot] += value
                    }
                    if i == j { diagonal[vi] += value }
                }
            }
        }
        func multiply(_ x: [Double]) -> [Double] {
            var out = [Double](repeating: 0, count: pixels.count)
            coefficients.withUnsafeBufferPointer { weights in
                neighbours.withUnsafeBufferPointer { columns in
                    x.withUnsafeBufferPointer { input in
                        for i in out.indices {
                            var sum = 0.0
                            for slot in 0..<25 {
                                let j = i*25+slot, col = columns[j]
                                if col >= 0 { sum += weights[j] * input[Int(col)] }
                            }
                            out[i] = sum
                        }
                    }
                }
            }
            return out
        }
        func dot(_ a: [Double], _ b: [Double]) -> Double {
            var total = 0.0
            for i in a.indices { total += a[i] * b[i] }
            return total
        }
        // Incomplete Cholesky on the local stencil. This preconditioner preserves the solved
        // system but avoids hundreds of slow Jacobi iterations through a broad hair band.
        var lower = [Double](repeating: 0, count: pixels.count*13)
        var validFactor = true
        for i in pixels.indices {
            if i % 2048 == 0 { try checkpoint() }
            for slot in 0..<12 {
                let j = Int(neighbours[i*25+slot])
                guard j >= 0 else { continue }
                var value = coefficients[i*25+slot]
                for earlier in 0..<slot {
                    let k = Int(neighbours[i*25+earlier])
                    guard k >= 0 else { continue }
                    let dx = pixels[k] % width - pixels[j] % width
                    let dy = pixels[k] / width - pixels[j] / width
                    guard abs(dx) <= 2 && abs(dy) <= 2 else { continue }
                    let other = (dy+2)*5+dx+2
                    guard other < 12 else { continue }
                    value -= lower[i*13+earlier] * lower[j*13+other]
                }
                lower[i*13+slot] = value / lower[j*13+12]
            }
            var value = diagonal[i] * 1.1
            for slot in 0..<12 { value -= lower[i*13+slot]*lower[i*13+slot] }
            guard value > 1e-12 && value.isFinite else { validFactor = false; break }
            lower[i*13+12] = sqrt(value)
        }
        func applyPreconditioner(_ residual: [Double]) -> [Double] {
            guard validFactor else { return residual.indices.map { residual[$0] / max(diagonal[$0], 1e-12) } }
            var out = residual
            lower.withUnsafeBufferPointer { factors in
                neighbours.withUnsafeBufferPointer { columns in
                    out.withUnsafeMutableBufferPointer { buffer in
                        for i in buffer.indices {
                            var value = buffer[i]
                            for slot in 0..<12 {
                                let j = Int(columns[i*25+slot])
                                if j >= 0 { value -= factors[i*13+slot]*buffer[j] }
                            }
                            buffer[i] = value/factors[i*13+12]
                        }
                        for i in buffer.indices.reversed() {
                            buffer[i] /= factors[i*13+12]
                            for slot in 0..<12 {
                                let j = Int(columns[i*25+slot])
                                if j >= 0 { buffer[j] -= factors[i*13+slot]*buffer[i] }
                            }
                        }
                    }
                }
            }
            return out
        }
        var x = pixels.map { initial[$0] }
        let ax = multiply(x)
        var r = rhs.indices.map { rhs[$0] - ax[$0] }
        for i in diagonal.indices { diagonal[i] = max(diagonal[i], 1e-12) }
        var z = applyPreconditioner(r)
        var direction = z
        var rz = dot(r, z)
        // A zero RHS still needs convergence testing: the solution of a background-only band is zero.
        let bound = max(1e-12, tolerance * sqrt(dot(rhs, rhs)))
        var iterations = 0
        while sqrt(dot(r, r)) > bound && iterations < maxIterations {
            try checkpoint()
            let ad = multiply(direction)
            let denominator = dot(direction, ad)
            guard denominator > 0 && denominator.isFinite && rz.isFinite else { break }
            let step = rz / denominator
            for i in x.indices { x[i] += step * direction[i]; r[i] -= step * ad[i] }
            z = applyPreconditioner(r)
            let next = dot(r, z)
            guard rz != 0 else { break }
            let beta = next / rz
            for i in direction.indices { direction[i] = z[i] + beta * direction[i] }
            rz = next
            iterations += 1
        }
        let converged = sqrt(dot(r, r)) <= bound && x.allSatisfy(\.isFinite)
        var alpha = trimap
        for (i, pixel) in pixels.enumerated() { alpha[pixel] = min(1, max(0, x[i])) }
        return Result(alpha: alpha, converged: converged, iterations: iterations)
    }
}
