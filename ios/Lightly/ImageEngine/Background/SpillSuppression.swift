import Foundation
import simd

/// Removes strongly coloured background spill near the subject edge. The general correction affects soft coverage.
/// For locally refined hair, an additional field reconstructs chroma from opaque crown hair, including contaminated
/// pixels the matte still calls opaque. Detected face contours and clothing below the head are excluded; brightness
/// and hair texture stay intact. Neutral backgrounds do not trigger correction. Older cached edits retain their
/// previous treatment because the caller only supplies faces for the versioned local-hair matte.
enum SpillSuppression {
    /// Chroma / brightness of the local background above which its cast is suppressed (offline evidence, 2026-10-08:
    /// the red wall measures well above it; the white, grey and dark backdrops of the other approved portraits below).
    static let minimumBackgroundSaturation: Float = 0.3
    /// Matte coverage at or above which the general edge correction leaves the subject colour alone.
    static let opaqueCoverage: Float = 0.995
    /// Width of the zone around the soft edge, as a fraction of the long edge (30 px on a 4,256 px photo).
    static let zoneFraction: Float = 0.007

    /// Per pixel of the working image: the background's unit chroma direction (3 channels) and the zone weight
    /// (1 channel, 0 or 1). nil when no part of the edge borders a strongly coloured background.
    struct Field {
        let direction: FloatImage
        let zone: FloatImage
        var hair: FloatImage? = nil

        func hairSample(x: Int, y: Int, frameWidth: Int, frameHeight: Int) -> SIMD4<Float> {
            guard let hair else { return .zero }
            let fx = min(max((Float(x)+0.5)*Float(hair.width)/Float(frameWidth)-0.5,0),Float(hair.width-1))
            let fy = min(max((Float(y)+0.5)*Float(hair.height)/Float(frameHeight)-0.5,0),Float(hair.height-1))
            let x0=Int(fx),y0=Int(fy),x1=min(x0+1,hair.width-1),y1=min(y0+1,hair.height-1)
            let tx=fx-Float(x0),ty=fy-Float(y0)
            func v(_ x:Int,_ y:Int)->SIMD4<Float> { let i=(y*hair.width+x)*4; return SIMD4(hair.data[i],hair.data[i+1],hair.data[i+2],hair.data[i+3]) }
            return (v(x0,y0)*(1-tx)+v(x1,y0)*tx)*(1-ty)+(v(x0,y1)*(1-tx)+v(x1,y1)*tx)*ty
        }

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

    static func field(photo: FloatImage, matte: FloatImage, faces: [DetectedFace] = []) -> Field? {
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
        guard any else { return nil }
        return Field(direction: direction, zone: zone, hair: hairField(photo: photo, matte: matte, zone: zone, faces: faces))
    }

    /// Preserve the hue of observed, opaque crown hair in the uncertain edge. A face's skin
    /// and every other face are excluded from both sampling and application.
    private static func hairField(photo: FloatImage, matte: FloatImage, zone: FloatImage, faces: [DetectedFace]) -> FloatImage? {
        guard !faces.isEmpty else { return nil }
        let w=photo.width,h=photo.height
        let bounds=CGRect(x:0,y:0,width:w,height:h)
        let protection=HairDetailRefinement.protectionMask(faces:faces,region:bounds,width:w,height:h,sourceWidth:w,sourceHeight:h)
        var out=FloatImage(width:w,height:h,channels:4)
        for face in faces {
            let f=face.box
            let rect=CGRect(x:f.x*Double(w),y:f.y*Double(h),width:f.width*Double(w),height:f.height*Double(h))
            let region=CGRect(x:rect.minX-rect.width,y:rect.minY-1.4*rect.height,width:3*rect.width,height:3.2*rect.height).intersection(bounds)
            var colour=FloatImage(width:w,height:h,channels:3), seeds=FloatImage(width:w,height:h,channels:1)
            var count=0
            for y in max(0,Int(region.minY))..<max(0,min(h,Int(rect.minY-0.25*rect.height))) {
                for x in max(0,Int(region.minX))..<min(w,Int(region.maxX)) {
                    let i=y*w+x
                    guard matte.data[i] >= 0.9999, protection.data[i] == 0 else { continue }
                    let mean=(photo.data[i*3]+photo.data[i*3+1]+photo.data[i*3+2])/3
                    guard mean > 0.002 else { continue }
                    seeds.data[i]=1; count += 1
                    for c in 0..<3 { colour.data[i*3+c]=photo.data[i*3+c]/mean }
                }
            }
            guard count >= 16 else { continue }
            let filled=FloatImage.pullPushFill(premultiplied:colour,coverage:seeds)
            for y in max(0,Int(region.minY))..<min(h,Int(rect.maxY)) {
                for x in max(0,Int(region.minX))..<min(w,Int(region.maxX)) {
                    let i=y*w+x
                    guard zone.data[i] > 0, protection.data[i] == 0 else { continue }
                    let weight=Float(HairDetailRefinement.weight(x:Double(x)+0.5,y:Double(y)+0.5,region:region,face:rect,protectRectangle:false))
                    if weight > out.data[i*4+3] {
                        for c in 0..<3 { out.data[i*4+c]=filled.data[i*3+c]*weight }
                        out.data[i*4+3]=weight
                    }
                }
            }
        }
        return out
    }

    static func restoreHairHue(_ subject: inout SIMD3<Float>, reference: SIMD4<Float>, opaque: Bool = false) {
        var weight=reference.w
        guard weight > 0 else { return }
        let mean=(subject.x+subject.y+subject.z)/3
        let colour=SIMD3(reference.x,reference.y,reference.z)/weight
        if opaque {
            let difference=simd_length(subject/max(mean,0.002)-colour)
            weight *= min(1,max(0,(difference-0.25)/0.25))
        }
        subject=simd_clamp(subject*(1-weight)+colour*(mean*weight),SIMD3(repeating:0),SIMD3(repeating:1))
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
