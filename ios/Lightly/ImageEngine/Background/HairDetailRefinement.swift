import CoreGraphics
import Foundation
import Vision
import simd

/// Refines uncertain hair coverage from the photograph rather than desaturating opaque pixels.
/// Face interiors and clothing keep the original matte. Runs once during subject analysis, never during a render.
enum HairDetailRefinement {
    static func refine(image: CGImage, prior: FloatImage, faces: [DetectedFace]) throws -> FloatImage {
        guard !faces.isEmpty else { return prior }
        let scale = min(1, 2048.0 / Double(max(image.width, image.height)))
        let ow = max(1, Int((Double(image.width) * scale).rounded()))
        let oh = max(1, Int((Double(image.height) * scale).rounded()))
        var output = prior.resized(width: ow, height: oh)
        var adopted = false
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        for detectedFace in faces {
            let face = detectedFace.box
            try Task.checkCancellation()
            let fw = face.width * Double(image.width), fh = face.height * Double(image.height)
            let fx = face.x * Double(image.width), fy = face.y * Double(image.height)
            let region = CGRect(x: fx-fw, y: fy-1.4*fh, width: 3*fw, height: 3.2*fh).intersection(bounds).integral
            guard region.width >= 32, region.height >= 32, let crop = image.cropping(to: region),
                  let working = AnalysisProxy.downscaled(crop, maximumLongEdge: 1449) else { continue }
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            do { try VNImageRequestHandler(cgImage: working).perform([request]) }
            catch { continue } // Keep the previously computed matte when this optional detail request is unavailable.
            try Task.checkCancellation()
            guard let buffer = request.results?.first?.pixelBuffer else { continue }
            let w = working.width, h = working.height
            let alpha = OnDeviceSceneAnalyser.floatImage(from: buffer).resized(width: w, height: h)
            let rgba = try MetalLUTRenderer.rgba8Bytes(of: working)
            var rgb = [Double](repeating: 0, count: w*h*3)
            for i in 0..<(w*h) { for c in 0..<3 { rgb[i*3+c] = Double(rgba[i*4+c]) / 255 } }
            // Colour-based local matting is underconstrained on hair against a similarly dark,
            // neutral backdrop. Preserve Vision there instead of inventing coverage from noise.
            guard hasChromaticBackground(rgb: rgb, alpha: alpha) else { continue }
            let protected = protectionMask(faces: faces, region: region, width: w, height: h,
                                           sourceWidth: image.width, sourceHeight: image.height)
            let headBottom = (fy+fh-region.minY) * Double(h)/region.height
            let trimap = makeTrimap(rgb: rgb, alpha: alpha, faceTop: headBottom, protected: protected, seedTop: (fy-region.minY)*Double(h)/region.height)
            guard trimap.contains(0), trimap.contains(1) else { continue }
            let result = try LocalHairMatting.solve(rgb: rgb, trimap: trimap, width: w, height: h,
                                                    initial: alpha.data.map(Double.init), checkpoint: { try Task.checkCancellation() })
            guard result.converged else { continue }
            adopted = true
            let solved = FloatImage(width: w, height: h, channels: 1, data: result.alpha.map(Float.init))
            let x0 = max(0, Int(region.minX*scale)), x1 = min(ow, Int(ceil(region.maxX*scale)))
            let y0 = max(0, Int(region.minY*scale)), y1 = min(oh, Int(ceil(region.maxY*scale)))
            for y in y0..<y1 { for x in x0..<x1 {
                let sx = (Double(x)+0.5)/scale, sy = (Double(y)+0.5)/scale
                let localX = (sx-region.minX)*Double(w)/region.width-0.5
                let localY = (sy-region.minY)*Double(h)/region.height-0.5
                let protection = sample(protected, x: localX, y: localY)
                let weight = weight(x: sx, y: sy, region: region,
                                    face: CGRect(x: fx, y: fy, width: fw, height: fh), protectRectangle: false) * Double(1-protection)
                guard weight > 0 else { continue }
                let a = sample(solved, x: (sx-region.minX)*Double(w)/region.width-0.5,
                               y: (sy-region.minY)*Double(h)/region.height-0.5)
                let i = y*ow+x
                output.data[i] += Float(weight) * (a-output.data[i])
            } }
        }
        return adopted ? output : prior
    }

    static func hasChromaticBackground(rgb: [Double], alpha: FloatImage) -> Bool {
        var background = 0, chromatic = 0
        for i in 0..<alpha.pixelCount where alpha.data[i] <= 0.005 {
            background += 1
            let p = i*3, mean = (rgb[p]+rgb[p+1]+rgb[p+2])/3
            let chroma = simd_length(SIMD3(rgb[p]-mean, rgb[p+1]-mean, rgb[p+2]-mean))
            if mean > 0.03 && chroma > 0.3*mean { chromatic += 1 }
        }
        return background > 0 && Double(chromatic)/Double(background) >= 0.1
    }

    /// Feather only outside the face/ears and above the bottom of the head. No rectangular seam at the crop edge.
    static func weight(x: Double, y: Double, region: CGRect, face: CGRect, protectRectangle: Bool = true) -> Double {
        func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
        let feather = max(1, face.width * 0.106)
        let outsideFace = clamp(max((face.minX-face.width*0.2-x)/feather,
                                    (x-face.maxX-face.width*0.2)/feather,
                                    (face.minY-face.height*0.1-y)/feather))
        let head = clamp((face.maxY-y)/max(1, face.height*0.133))
        let edge = max(1, face.width*0.0664)
        let crop = clamp(min((x-region.minX)/edge, (region.maxX-x)/edge,
                             (y-region.minY)/edge, (region.maxY-y)/edge))
        return (protectRectangle ? outsideFace : 1) * head * crop
    }

    static func makeTrimap(rgb: [Double], alpha: FloatImage, faceTop: Double, protected: FloatImage? = nil, seedTop: Double? = nil) -> [Double] {
        let w = alpha.width, h = alpha.height, n = w*h
        var fg = erode(alpha.data.map { $0 >= 0.995 }, width: w, height: h, radius: 15)
        let bg = erode(alpha.data.map { $0 <= 0.005 }, width: w, height: h, radius: 3)
        // Nearest known background, filled with a bounded breadth-first pass. No inference from skin colours.
        var owner = [Int](repeating: -1, count: n), queue = [Int]()
        queue.reserveCapacity(n)
        for i in 0..<n where bg[i] { owner[i] = i; queue.append(i) }
        var cursor = 0
        while cursor < queue.count {
            let i = queue[cursor]; cursor += 1
            let x = i % w, y = i / w
            for neighbour in [x > 0 ? i-1 : -1, x+1 < w ? i+1 : -1, y > 0 ? i-w : -1, y+1 < h ? i+w : -1]
                where neighbour >= 0 && owner[neighbour] < 0 {
                owner[neighbour] = owner[i]; queue.append(neighbour)
            }
        }
        var along = [Double](repeating: 0, count: n), saturation = along, seeds = [Double]()
        for i in 0..<n where Double(i/w) < faceTop && (protected?.data[i] ?? 0) < 0.01 && owner[i] >= 0 {
            let b = owner[i]*3, p = i*3
            let mean = (rgb[b]+rgb[b+1]+rgb[b+2])/3
            let chroma = SIMD3(rgb[b]-mean, rgb[b+1]-mean, rgb[b+2]-mean)
            let norm = simd_length(chroma)
            let ownMean = (rgb[p]+rgb[p+1]+rgb[p+2])/3
            let ownChroma = SIMD3(rgb[p]-ownMean, rgb[p+1]-ownMean, rgb[p+2]-ownMean)
            along[i] = simd_dot(ownChroma, chroma) / (max(0.01, ownMean) * max(norm, 1e-6))
            saturation[i] = norm / max(mean, 0.01)
            if fg[i] && along[i] < 0.2 && Double(i/w) < (seedTop ?? faceTop) { seeds.append(along[i]) }
        }
        if !seeds.isEmpty {
            seeds.sort()
            let threshold = seeds[min(seeds.count-1, Int(Double(seeds.count-1)*0.95))] + 0.2
            for i in 0..<n where Double(i/w) < faceTop && (protected?.data[i] ?? 0) < 0.01 && saturation[i] > 0.3 && along[i] > threshold { fg[i] = false }
        }
        return (0..<n).map { fg[$0] ? 1 : bg[$0] ? 0 : Double.nan }
    }


    /// Use the detected jaw/cheeks and forehead, rather than a box that also protects wall between side curls.
    static func protectionMask(faces: [DetectedFace], region: CGRect, width: Int, height: Int,
                               sourceWidth: Int, sourceHeight: Int, includeEars: Bool = false) -> FloatImage {
        var bytes = [UInt8](repeating: 0, count: width*height)
        bytes.withUnsafeMutableBytes { ptr in
            guard let context = CGContext(data: ptr.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(gray: 1, alpha: 1)
            context.setStrokeColor(gray: 1, alpha: 1)
            for face in faces {
                func point(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: (p.x*Double(sourceWidth)-region.minX)*Double(width)/region.width,
                            y: (p.y*Double(sourceHeight)-region.minY)*Double(height)/region.height)
                }
                let b = face.box
                if includeEars {
                    // Colour correction must not mistake ears outside Vision's jaw contour for hair.
                    // This protection is deliberately separate from matte refinement.
                    for side in [0.035, 0.965] {
                        let centre = point(CGPoint(x: b.x + side*b.width, y: b.y + 0.47*b.height))
                        let rx = 0.11*b.width*Double(sourceWidth)*Double(width)/region.width
                        let ry = 0.25*b.height*Double(sourceHeight)*Double(height)/region.height
                        context.fillEllipse(in: CGRect(x: centre.x-rx, y: centre.y-ry, width: 2*rx, height: 2*ry))
                    }
                }
                guard face.faceContour.count > 4 else {
                    context.fill(CGRect(x: (b.x*Double(sourceWidth)-region.minX)*Double(width)/region.width,
                                        y: (b.y*Double(sourceHeight)-region.minY)*Double(height)/region.height,
                                        width: b.width*Double(sourceWidth)*Double(width)/region.width,
                                        height: b.height*Double(sourceHeight)*Double(height)/region.height))
                    continue
                }
                let contour = face.faceContour.map(point)
                let path = CGMutablePath(); path.addLines(between: contour)
                // Close the jaw contour across the forehead, following the two detected temples.
                let foreheadY = (b.y*Double(sourceHeight)-region.minY)*Double(height)/region.height
                path.addLine(to: CGPoint(x: contour.last!.x, y: foreheadY))
                path.addLine(to: CGPoint(x: contour.first!.x, y: foreheadY)); path.closeSubpath()
                context.setLineWidth(2)
                context.setLineJoin(.round)
                context.addPath(path); context.drawPath(using: .fillStroke)
            }
        }
        return FloatImage(width: width, height: height, channels: 1, data: bytes.map { Float($0)/255 })
    }

    private static func erode(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var rows = mask, result = mask
        for y in 0..<height {
            var missing = 0
            for x in 0..<min(width, radius+1) where !mask[y*width+x] { missing += 1 }
            for x in 0..<width {
                rows[y*width+x] = missing == 0
                if x-radius >= 0 && !mask[y*width+x-radius] { missing -= 1 }
                if x+radius+1 < width && !mask[y*width+x+radius+1] { missing += 1 }
            }
        }
        for x in 0..<width {
            var missing = 0
            for y in 0..<min(height, radius+1) where !rows[y*width+x] { missing += 1 }
            for y in 0..<height {
                result[y*width+x] = missing == 0
                if y-radius >= 0 && !rows[(y-radius)*width+x] { missing -= 1 }
                if y+radius+1 < height && !rows[(y+radius+1)*width+x] { missing += 1 }
            }
        }
        return result
    }

    private static func sample(_ image: FloatImage, x: Double, y: Double) -> Float {
        let x = min(Double(image.width-1), max(0, x)), y = min(Double(image.height-1), max(0, y))
        let ix = Int(x), iy = Int(y), jx = min(ix+1, image.width-1), jy = min(iy+1, image.height-1)
        let tx = Float(x-Double(ix)), ty = Float(y-Double(iy))
        return (image.data[iy*image.width+ix]*(1-tx)+image.data[iy*image.width+jx]*tx)*(1-ty)
             + (image.data[jy*image.width+ix]*(1-tx)+image.data[jy*image.width+jx]*tx)*ty
    }
}
