import CoreGraphics
import Foundation

/// Stage `portrait` (rendering-v2 stage 9): per-face retouching inside landmark-derived regions.
///
/// CONTRACT GAP (reported in docs/v1/slice3-ios.md): rendering-v2 gives this stage's parameters,
/// ranges and the rule "eye colour/shape and skin tone colour are never changed", but no
/// equations. These operators are this port's provisional ones, written to that rule:
/// - every adjustment works on OKLab lightness, or pulls chroma toward its own local mean (blemish
///   redness, blotches), so no region's average colour changes;
/// - nothing moves geometry, so eye shape and face shape are untouched.
/// Regions, all feathered and computed per face on a crop around it:
/// - skin: an ellipse on the face box, minus the eyes, brows and lips, weighted by similarity to
///   the face's median skin colour;
/// - under-eye: a crescent below each eye; eyes: the eye polygons; teeth: bright, low-chroma
///   pixels inside the inner lips; hair: the person matte around the head minus the face.
enum PortraitRenderer {

    struct Face {
        let detected: DetectedFace
        let edit: EditRecipe.FaceEdit
    }

    /// Applies every face's edits to a linear RGB image. `personMatte` (optional, same size)
    /// limits the hair operators.
    static func render(_ image: FloatImage, faces: [Face], personMatte: FloatImage?) -> FloatImage {
        var out = image
        for face in faces where hasChanges(face.edit) {
            apply(face, to: &out, personMatte: personMatte)
        }
        return out
    }

    static func hasChanges(_ e: EditRecipe.FaceEdit) -> Bool {
        e.skin.smoothing > 0 || e.skin.blemishes > 0 || e.skin.evenTone > 0 || e.underEye.brighten > 0 || e.underEye.softenLines > 0
            || e.eyes.brighten > 0 || e.eyes.clarity > 0 || e.teeth.brighten > 0 || e.hair.definition > 0 || e.hair.flyaways > 0
            || e.hair.shine > 0
    }

    // MARK: - One face

    private static func apply(_ face: Face, to image: inout FloatImage, personMatte: FloatImage?) {
        let W = Float(image.width), H = Float(image.height)
        let box = face.detected.box
        // Crop: the face box grown to include hair and shoulders around the head.
        let cx0 = max(0, Int((Float(box.x) - Float(box.width) * 0.9) * W)), cx1 = min(image.width, Int((Float(box.x + box.width) + Float(box.width) * 0.9) * W))
        let cy0 = max(0, Int((Float(box.y) - Float(box.height) * 0.9) * H)), cy1 = min(image.height, Int((Float(box.y + box.height) + Float(box.height) * 0.4) * H))
        guard cx1 - cx0 > 8, cy1 - cy0 > 8 else { return }
        let cw = cx1 - cx0, chh = cy1 - cy0
        var crop = FloatImage(width: cw, height: chh, channels: 3)
        for y in 0..<chh { for x in 0..<cw { for c in 0..<3 {
            crop.data[(y * cw + x) * 3 + c] = image.data[((y + cy0) * image.width + x + cx0) * 3 + c]
        } } }
        // OKLab planes.
        var L = FloatImage(width: cw, height: chh, channels: 1), A = L, B = L
        for i in 0..<crop.pixelCount {
            let lab = ColourMath.oklab(fromEncoded: ColourMath.encoded(fromLinear: SIMD3(crop.data[i * 3], crop.data[i * 3 + 1], crop.data[i * 3 + 2])))
            L.data[i] = lab.x; A.data[i] = lab.y; B.data[i] = lab.z
        }
        // Untouched OKLab planes: only pixels an operator changed are written back, so the
        // OKLab round trip never alters the rest of the crop.
        let originalL = L, originalA = A, originalB = B
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: Double(Float(p.x) * W - Float(cx0)), y: Double(Float(p.y) * H - Float(cy0))) }
        let faceWidthPx = Float(box.width) * W
        let feather = max(1.5, faceWidthPx * 0.02)
        let d = face.detected

        // Region masks.
        let faceEllipse = ellipseMask(width: cw, height: chh,
                                      centre: local(CGPoint(x: box.x + box.width / 2, y: box.y + box.height * 0.48)),
                                      radii: (faceWidthPx * 0.5, Float(box.height) * H * 0.6), feather: feather * 2)
        let eyes = union(polygonMask(width: cw, height: chh, points: d.leftEye.map(local), grow: faceWidthPx * 0.02, feather: feather),
                         polygonMask(width: cw, height: chh, points: d.rightEye.map(local), grow: faceWidthPx * 0.02, feather: feather))
        let brows = union(polygonMask(width: cw, height: chh, points: d.leftEyebrow.map(local), grow: faceWidthPx * 0.03, feather: feather),
                          polygonMask(width: cw, height: chh, points: d.rightEyebrow.map(local), grow: faceWidthPx * 0.03, feather: feather))
        let lips = polygonMask(width: cw, height: chh, points: d.outerLips.map(local), grow: faceWidthPx * 0.02, feather: feather)
        // Skin is judged on broad chroma, so a red mark inside the skin is still skin (it is
        // what Blemishes must reach) while hair, eyes and background are not.
        let sigmaLow = max(4, faceWidthPx * 0.12)
        let aLow = RefocusRenderer.blurLarge(A, sigma: sigmaLow), bLow = RefocusRenderer.blurLarge(B, sigma: sigmaLow)
        let skin = skinMask(face: faceEllipse, exclusions: [eyes, brows, lips], A: aLow, B: bLow)

        let e = face.edit
        // Skin: smoothing with texture kept, blemishes, even tone.
        if e.skin.smoothing > 0 || e.skin.blemishes > 0 || e.skin.evenTone > 0 {
            let sigmaFine = max(0.6, faceWidthPx * 0.004), sigmaMid = max(2, faceWidthPx * 0.03)
            let fineBlur = L.gaussianBlurred(sigma: sigmaFine), midBlur = L.gaussianBlurred(sigma: sigmaMid)
            let lowBlur = RefocusRenderer.blurLarge(L, sigma: sigmaLow)
            let s = Float(e.skin.smoothing) / 100, keep = Float(e.skin.keepTexture) / 100, tone = Float(e.skin.evenTone) / 100
            let blemish = Float(e.skin.blemishes) / 100
            for i in 0..<L.pixelCount {
                let m = skin.data[i]
                guard m > 0.001 else { continue }
                let fine = L.data[i] - fineBlur.data[i], mid = fineBlur.data[i] - midBlur.data[i]
                var low = midBlur.data[i]
                // Even tone: flatten low-frequency lightness blotches toward the broad skin level.
                low += tone * 0.6 * (lowBlur.data[i] - low)
                var lightness = low + mid * (1 - s) + fine * (1 - s * (1 - keep))
                var a = A.data[i], b = B.data[i]
                // Blemishes: temporary marks are redder than the skin around them; pull their
                // redness and darkness back to the local mean. Brown moles and freckles are not
                // redder, so they stay.
                // Redness against the broad skin chroma: a small mark barely moves that mean.
                let redness = a - aLow.data[i]
                if blemish > 0, redness > 0.006 {
                    let w = blemish * min((redness - 0.006) / 0.02, 1)
                    a += (aLow.data[i] - a) * w
                    b += (bLow.data[i] - b) * w * 0.5
                    lightness += max(midBlur.data[i] - lightness, 0) * w
                }
                if tone > 0 {
                    // Blotch chroma toward the broad local chroma: the skin's own colour, kept.
                    a += (aLow.data[i] - a) * tone * 0.3
                    b += (bLow.data[i] - b) * tone * 0.3
                }
                L.data[i] += (lightness - L.data[i]) * m
                A.data[i] += (a - A.data[i]) * m
                B.data[i] += (b - B.data[i]) * m
            }
        }

        // Under-eye crescents.
        if e.underEye.brighten > 0 || e.underEye.softenLines > 0 {
            let under = union(underEyeMask(width: cw, height: chh, eye: d.leftEye.map(local), faceWidth: faceWidthPx, feather: feather),
                              underEyeMask(width: cw, height: chh, eye: d.rightEye.map(local), faceWidth: faceWidthPx, feather: feather))
            let soft = L.gaussianBlurred(sigma: max(1, faceWidthPx * 0.008))
            let reference = RefocusRenderer.blurLarge(L, sigma: max(3, faceWidthPx * 0.08))
            for i in 0..<L.pixelCount {
                let m = under.data[i] * (1 - eyes.data[i])
                guard m > 0.001 else { continue }
                var l = L.data[i]
                l += (soft.data[i] - l) * Float(e.underEye.softenLines) / 100 * 0.8
                l += max(reference.data[i] - l, 0) * Float(e.underEye.brighten) / 100 * 0.7
                L.data[i] += (l - L.data[i]) * m
            }
        }

        // Eyes: lightness only (colour never changed), clarity as local contrast.
        if e.eyes.brighten > 0 || e.eyes.clarity > 0 {
            let eyeMean = L.gaussianBlurred(sigma: max(1, faceWidthPx * 0.01))
            for i in 0..<L.pixelCount {
                let m = eyes.data[i]
                guard m > 0.001 else { continue }
                var l = L.data[i]
                l += (l - eyeMean.data[i]) * Float(e.eyes.clarity) / 100 * 0.8
                l += (1 - l) * Float(e.eyes.brighten) / 100 * 0.12
                L.data[i] += (min(max(l, 0), 1) - L.data[i]) * m
            }
        }

        // Teeth: bright, low-chroma pixels inside the inner lips; lightness only, capped.
        if e.teeth.brighten > 0, d.innerLips.count >= 3 {
            let mouth = polygonMask(width: cw, height: chh, points: d.innerLips.map(local), grow: 0, feather: feather * 0.5)
            for i in 0..<L.pixelCount {
                let chroma = (A.data[i] * A.data[i] + B.data[i] * B.data[i]).squareRoot()
                let toothLike = min(max((L.data[i] - 0.45) / 0.15, 0), 1) * min(max((0.09 - chroma) / 0.04, 0), 1)
                let m = mouth.data[i] * toothLike
                guard m > 0.001 else { continue }
                // Natural range: at most 40 % of the way to L 0.92, never past it.
                let target = min(L.data[i] + (0.92 - L.data[i]) * 0.4 * Float(e.teeth.brighten) / 100, 0.92)
                L.data[i] += (max(target, L.data[i]) - L.data[i]) * m
            }
        }

        // Hair & beard: the person matte around the head, outside the skin and face features.
        if e.hair.definition > 0 || e.hair.flyaways > 0 || e.hair.shine > 0 {
            var hair = FloatImage(width: cw, height: chh, channels: 1)
            let head = ellipseMask(width: cw, height: chh, centre: local(CGPoint(x: box.x + box.width / 2, y: box.y + box.height * 0.45)),
                                   radii: (faceWidthPx * 1.05, Float(box.height) * H * 1.05), feather: feather * 3)
            for y in 0..<chh { for x in 0..<cw {
                let i = y * cw + x
                let person: Float = personMatte.map { $0.data[(y + cy0) * $0.width + x + cx0] } ?? 1
                hair.data[i] = head.data[i] * person * (1 - skin.data[i]) * (1 - eyes.data[i]) * (1 - lips.data[i])
            } }
            let hairMean = L.gaussianBlurred(sigma: max(1, faceWidthPx * 0.015))
            let fine = L.gaussianBlurred(sigma: max(0.8, faceWidthPx * 0.004))
            let edge = personMatte != nil ? edgeBand(hair) : hair
            for i in 0..<L.pixelCount {
                let m = hair.data[i]
                guard m > 0.001 else { continue }
                var l = L.data[i]
                l += (l - hairMean.data[i]) * Float(e.hair.definition) / 100 * 0.9
                if l > hairMean.data[i] { l += (l - hairMean.data[i]) * Float(e.hair.shine) / 100 * 1.2 }
                l += (fine.data[i] - l) * Float(e.hair.flyaways) / 100 * edge.data[i]
                L.data[i] += (min(max(l, 0), 1) - L.data[i]) * m
            }
        }

        // Back to linear RGB in the crop.
        for i in 0..<crop.pixelCount
        where L.data[i] != originalL.data[i] || A.data[i] != originalA.data[i] || B.data[i] != originalB.data[i] {
            let encoded = ColourMath.encoded(fromOKLab: SIMD3(L.data[i], A.data[i], B.data[i]))
            let linear = ColourMath.linear(fromEncoded: encoded)
            let (x, y) = (i % cw, i / cw)
            let o = ((y + cy0) * image.width + x + cx0) * 3
            image.data[o] = linear.x; image.data[o + 1] = linear.y; image.data[o + 2] = linear.z
        }
    }

    // MARK: - Masks

    static func ellipseMask(width: Int, height: Int, centre: CGPoint, radii: (Float, Float), feather: Float) -> FloatImage {
        var out = FloatImage(width: width, height: height, channels: 1)
        for y in 0..<height { for x in 0..<width {
            let dx = (Float(x) - Float(centre.x)) / radii.0, dy = (Float(y) - Float(centre.y)) / radii.1
            let r = (dx * dx + dy * dy).squareRoot()
            let edge = feather / max(radii.0, radii.1)
            out.data[y * width + x] = min(max((1 - r) / max(edge, 1e-3) + 0.5, 0), 1)
        } }
        return out
    }

    /// A filled polygon, grown by `grow` px and feathered by `feather` px.
    static func polygonMask(width: Int, height: Int, points: [CGPoint], grow: Float, feather: Float) -> FloatImage {
        var out = FloatImage(width: width, height: height, channels: 1)
        guard points.count >= 3 else { return out }
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        let bounds = path.boundingBox.insetBy(dx: -CGFloat(grow + feather * 2), dy: -CGFloat(grow + feather * 2))
        let x0 = max(0, Int(bounds.minX)), x1 = min(width - 1, Int(bounds.maxX)), y0 = max(0, Int(bounds.minY)), y1 = min(height - 1, Int(bounds.maxY))
        guard x0 <= x1, y0 <= y1 else { return out }
        for y in y0...y1 { for x in x0...x1 where path.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
            out.data[y * width + x] = 1
        } }
        if grow >= 1 { out = out.dilated(threshold: 0.5, radius: Int(grow.rounded())) }
        return out.gaussianBlurred(sigma: max(feather / 2, 0.5))
    }

    static func underEyeMask(width: Int, height: Int, eye: [CGPoint], faceWidth: Float, feather: Float) -> FloatImage {
        guard eye.count >= 3 else { return FloatImage(width: width, height: height, channels: 1) }
        let xs = eye.map { Float($0.x) }, ys = eye.map { Float($0.y) }
        let minX = xs.min()!, maxX = xs.max()!, maxY = ys.max()!, eyeHeight = max(ys.max()! - ys.min()!, faceWidth * 0.04)
        let centre = CGPoint(x: Double((minX + maxX) / 2), y: Double(maxY + eyeHeight * 0.9))
        return ellipseMask(width: width, height: height, centre: centre, radii: ((maxX - minX) * 0.55, eyeHeight * 0.75), feather: feather * 2)
    }

    static func skinMask(face: FloatImage, exclusions: [FloatImage], A: FloatImage, B: FloatImage) -> FloatImage {
        var core: [Float] = [], coreB: [Float] = []
        for i in 0..<face.pixelCount where face.data[i] > 0.9 && exclusions.allSatisfy({ $0.data[i] < 0.1 }) {
            core.append(A.data[i]); coreB.append(B.data[i])
        }
        let medianA = RefocusRenderer.median(core), medianB = RefocusRenderer.median(coreB)
        var out = face
        for i in 0..<out.pixelCount {
            let distance = ((A.data[i] - medianA) * (A.data[i] - medianA) + (B.data[i] - medianB) * (B.data[i] - medianB)).squareRoot()
            let similarity = min(max(1 - (distance - 0.02) / 0.04, 0), 1)
            var m = face.data[i] * similarity
            for exclusion in exclusions { m *= 1 - exclusion.data[i] }
            out.data[i] = m
        }
        return out
    }

    static func union(_ a: FloatImage, _ b: FloatImage) -> FloatImage {
        var out = a
        for i in 0..<out.pixelCount { out.data[i] = max(a.data[i], b.data[i]) }
        return out
    }

    /// Where a mask is partial: its outer band (flyaways live at the hair's silhouette).
    static func edgeBand(_ mask: FloatImage) -> FloatImage {
        let blurred = mask.boxFiltered(radius: 3)
        var out = mask
        for i in 0..<out.pixelCount { out.data[i] = min(1, 4 * blurred.data[i] * (1 - blurred.data[i])) }
        return out
    }
}
