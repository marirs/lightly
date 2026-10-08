import Foundation
import simd

/// Change background: removes the old background's colour cast from the subject's semi-transparent edge (2026-10-08).
///
/// Phone evidence (iPhone 11 Pro Max, 261008013, the red-wall portrait): the subject matte is computed at the analysis
/// size and stretched to the photo, so the edge and the pockets between curls hold wall pixels at coverage 0.4–1. The
/// foreground correction (ForegroundEstimate, at the working size) is smooth and cannot follow them pixel by pixel, so a
/// red line stayed along the fleece and red and teal specks in the curls, against dark and light replacements alike.
/// Shadowed wall seen through black curls has the same colour as a hair/wall mix, so no coverage correction can tell them
/// apart; a coverage correction tried offline also cut into subjects whose colour resembled a plain background (a grey
/// garment in the group portrait) and was dropped.
///
/// What this does: near the matte's soft edge, and only where the matte is not fully opaque (skin and clothing
/// interiors keep their colour), the subject colour loses its component along the old background's chroma direction, in
/// both senses (the wall's red and the over-corrected teal). Only when that background is strongly coloured (chroma at
/// least 0.3 of its brightness, linear light); a white, grey or black background leaves everything unchanged.
/// iOS only: Android's composite is a different pipeline (A4, `docs/v1/remaining-work.md`).
enum SpillSuppression {
    /// Chroma / brightness of the local background above which its cast is suppressed (offline evidence, 2026-10-08:
    /// the red wall measures well above it; the white, grey and dark backdrops of the other approved portraits below).
    static let minimumBackgroundSaturation: Float = 0.3
    /// Matte coverage at or above which a pixel counts as opaque subject and keeps its colour.
    static let opaqueCoverage: Float = 0.995
    /// Width of the zone around the soft edge, as a fraction of the long edge (30 px on a 4,256 px photo).
    static let zoneFraction: Float = 0.007

    /// Per pixel of the working image: the background's unit chroma direction (3 channels) and the zone weight
    /// (1 channel, 0 or 1). nil when no part of the edge borders a strongly coloured background.
    struct Field {
        let direction: FloatImage
        let zone: FloatImage

        /// Bilinear sample at a frame pixel (half-pixel centres), from the working-size field.
        @inline(__always)
        func sample(x: Int, y: Int, frameWidth: Int, frameHeight: Int) -> (direction: SIMD3<Float>, zone: Float) {
            let w = zone.width, h = zone.height
            let fx = min(max((Float(x) + 0.5) * Float(w) / Float(frameWidth) - 0.5, 0), Float(w - 1))
            let fy = min(max((Float(y) + 0.5) * Float(h) / Float(frameHeight) - 0.5, 0), Float(h - 1))
            let x0 = Int(fx), y0 = Int(fy), x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
            let tx = fx - Float(x0), ty = fy - Float(y0)
            // Four taps written out: this runs per frame pixel in the soft edge, so no per-pixel allocation.
            let j00 = y0 * w + x0, j10 = y0 * w + x1, j01 = y1 * w + x0, j11 = y1 * w + x1
            let w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty), w01 = (1 - tx) * ty, w11 = tx * ty
            let z = zone.data[j00] * w00 + zone.data[j10] * w10 + zone.data[j01] * w01 + zone.data[j11] * w11
            guard z > 0 else { return (SIMD3(repeating: 0), 0) }
            func dir(_ j: Int) -> SIMD3<Float> { SIMD3(direction.data[j * 3], direction.data[j * 3 + 1], direction.data[j * 3 + 2]) }
            return (dir(j00) * w00 + dir(j10) * w10 + dir(j01) * w01 + dir(j11) * w11, z)
        }
    }

    static func field(photo: FloatImage, matte: FloatImage) -> Field? {
        let n = photo.pixelCount
        // The old background around the subject: photo pixels where the matte is (nearly) 0, filled inward.
        var background = FloatImage(width: photo.width, height: photo.height, channels: 3)
        var coverage = FloatImage(width: photo.width, height: photo.height, channels: 1)
        var soft = FloatImage(width: photo.width, height: photo.height, channels: 1)
        for i in 0..<n {
            let a = matte.data[i]
            if a <= 0.02 {
                coverage.data[i] = 1
                for c in 0..<3 { background.data[i * 3 + c] = photo.data[i * 3 + c] }
            }
            soft.data[i] = a > 0.02 && a < 0.98 ? 1 : 0
        }
        guard coverage.data.contains(1) else { return nil }
        let filled = FloatImage.pullPushFill(premultiplied: background, coverage: coverage)
        let radius = max(1, Int((zoneFraction * Float(max(photo.width, photo.height))).rounded()))
        let near = soft.dilated(threshold: 0.5, radius: radius)
        var direction = FloatImage(width: photo.width, height: photo.height, channels: 3)
        var zone = FloatImage(width: photo.width, height: photo.height, channels: 1)
        var any = false
        for i in 0..<n where near.data[i] > 0 {
            let r = filled.data[i * 3], g = filled.data[i * 3 + 1], b = filled.data[i * 3 + 2]
            let mean = (r + g + b) / 3
            let cr = r - mean, cg = g - mean, cb = b - mean
            let chroma = (cr * cr + cg * cg + cb * cb).squareRoot()
            guard chroma >= minimumBackgroundSaturation * max(mean, 1e-4) else { continue }
            direction.data[i * 3] = cr / chroma; direction.data[i * 3 + 1] = cg / chroma; direction.data[i * 3 + 2] = cb / chroma
            zone.data[i] = 1
            any = true
        }
        return any ? Field(direction: direction, zone: zone) : nil
    }

    /// Removes the component of `subject` (linear RGB, one pixel) along `direction`, weighted by `zone`, unless the
    /// pixel is opaque subject.
    @inline(__always)
    static func apply(_ subject: inout SIMD3<Float>, coverage: Float, direction: SIMD3<Float>, zone: Float) {
        guard zone > 0, coverage < opaqueCoverage else { return }
        let mean = (subject.x + subject.y + subject.z) / 3
        let along = ((subject - SIMD3(repeating: mean)) * direction).sum()
        subject = simd_clamp(subject - direction * (along * zone), SIMD3(repeating: 0), SIMD3(repeating: 1))
    }
}
