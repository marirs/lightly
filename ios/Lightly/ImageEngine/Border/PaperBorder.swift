import Foundation

/// Deterministic paper in source-width coordinates: preview and export sample the same surface.
enum PaperBorder {
    static func noise(_ x: Double, _ y: Double) -> Double {
        func hash(_ x: Int, _ y: Int) -> Double {
            var n = UInt32(truncatingIfNeeded: x) &* 374761393 &+ UInt32(truncatingIfNeeded: y) &* 668265263
            n = (n ^ (n >> 13)) &* 1274126177
            return Double((n ^ (n >> 16)) & 65535) / 65535
        }
        let ix = Int(floor(x)), iy = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
        let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
        let a = hash(ix, iy) * (1-u) + hash(ix+1, iy) * u
        let b = hash(ix, iy+1) * (1-u) + hash(ix+1, iy+1) * u
        return a * (1-v) + b * v
    }

    static func paint(_ b: EditRecipe.Border, placement p: BorderStage.Placement, pixels: inout [UInt8]) {
        let scale = Double(p.frameWidth), rgb = BorderStage.rgba(b.colour)
        let base = [Double(rgb.0), Double(rgb.1), Double(rgb.2)]
        let amplitude = b.paperFinish == .clean ? 0 : (b.paperFinish == .deckled ? 0.0025 : 0.009)
        let limit = Int(ceil(amplitude * scale + 2))
        for y in 0..<p.canvasHeight {
            for x in 0..<p.canvasWidth {
                let px = x - p.side, py = y - p.top
                let inside = px >= 0 && py >= 0 && px < p.frameWidth && py < p.frameHeight
                let distance = min(px, py, p.frameWidth - 1 - px, p.frameHeight - 1 - py)
                if inside && distance > limit { continue }
                let u = Double(x) / scale, v = Double(y) / scale
                let edge = amplitude * scale * (0.18 + 0.55 * noise(u * 93, v * 93) + 0.27 * noise(u * 431, v * 431))
                let coverage = inside ? min(1, max(0, edge - Double(distance))) : 1
                if coverage <= 0 { continue }
                let fibre = (noise(u * 850, v * 210) - 0.5) * 13 + (noise(u * 230, v * 230) - 0.5) * 7
                let variation = fibre * b.texture / 100
                let rim = inside && b.paperFinish != .clean ? 5.0 : 0
                let i = (y * p.canvasWidth + x) * 4
                for c in 0..<3 {
                    let paper = min(255, max(0, base[c] + variation + rim))
                    pixels[i+c] = UInt8(min(255, max(0, (Double(pixels[i+c]) * (1-coverage) + paper * coverage).rounded())))
                }
            }
        }
    }
}
