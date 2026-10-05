import CoreGraphics
import Foundation

/// Stages 7–9 between Develop and Effects: background replacement, Focus & Blur, Portrait.
///
/// Focus & Blur's layered renderer is costly on the CPU, so it runs at a capped working
/// resolution and is merged into the full frame by defocus: where the result is sharp (focal band
/// and in-front-of-nothing subject) the full-resolution pixels are kept, where it is defocused the
/// working-resolution blur is used (it has no detail to lose there). A replacement is composited at
/// full resolution with the upsampled matte. Preview and export use the same code; only the caps
/// differ (interactive 640 px, preview 1024 px, export 2048 px on the long edge).
enum LayeredStages {

    struct Inputs: Sendable {
        var background: EditRecipe.Background
        var portrait: EditRecipe.Portrait
        var cache: SceneCache
        /// The develop global LUT at its Amount, to give a replacement the photo's colour.
        var developLUT: LUT3D?
        var autoLUT: LUT3D?
        /// Edit › Adjust's colour LUT (stage 5), part of the photo's global colour (stage 7 note).
        var adjustLUT: LUT3D? = nil
        /// Focus & Blur's R_max fraction from the displayed photo (RefocusRenderer); nil: contract 0.06.
        var maxBlurRadiusFraction: Float? = nil
    }

    static let interactiveCap = 640
    static let previewCap = 1_024
    static let exportCap = 2_048

    static func isActive(_ inputs: Inputs) -> Bool {
        (inputs.background.replacement != nil || inputs.background.focus.blur > 0)
            || inputs.portrait.faces.contains(where: PortraitRenderer.hasChanges)
    }

    /// Applies the stages to an RGBA8 sRGB frame.
    static func render(_ pixels: [UInt8], width: Int, height: Int, inputs: Inputs, cap: Int,
                       lutApplier: any DevelopLUTApplying) throws -> [UInt8] {
        guard isActive(inputs) else { return pixels }
        var full = FloatImage.linear(fromRGBA8: pixels, width: width, height: height)
        let background = inputs.background
        let wantsBackground = background.replacement != nil || background.focus.blur > 0

        if wantsBackground {
            try Task.checkCancellation()
            // The replacement at frame size, given the photo's global colour (stage 7 note).
            var replacementFull: FloatImage?
            if let replacement = background.replacement {
                var image: CGImage?
                if case .image(.bundled(let id), _, _, _) = replacement { image = inputs.cache.replacementImages[id] }
                if var rgba = BackgroundStage.replacementRGBA8(replacement, width: width, height: height, image: image) {
                    let passes = [inputs.autoLUT, inputs.developLUT, inputs.adjustLUT].compactMap { $0 }
                    if !passes.isEmpty {
                        rgba = try lutApplier.apply(passes, toRGBA8: rgba, width: width, height: height,
                                                    maximumTileSide: MetalLUTRenderer.defaultMaximumTileSide)
                    }
                    replacementFull = FloatImage.linear(fromRGBA8: rgba, width: width, height: height)
                }
            }
            let matteFull = inputs.cache.subject.map { matte -> FloatImage in
                var m = matte.matte.resized(width: width, height: height)
                BackgroundStage.applyRefinements(background.subject.refinements, to: &m)
                return m
            }
            // Sharp composite at full resolution: the subject over the (replaced) background. The subject's colour
            // is the estimated foreground (rendering-v2 revision 5): estimated at the working size, its correction
            // F − I up-sampled to the frame, so the old background's colour leaves hair while the frame keeps its
            // own detail. Before revision 5 the observed pixel was composited (the old wall's colour in hair).
            var composite = full
            if let replacementFull, let matteFull {
                let scale = min(1, Float(cap) / Float(max(width, height)))
                let ww = max(1, Int((Float(width) * scale).rounded())), wh = max(1, Int((Float(height) * scale).rounded()))
                let photoWorking = full.resized(width: ww, height: wh)
                var matteWorking = matteFull.resized(width: ww, height: wh)
                for i in 0..<matteWorking.data.count { matteWorking.data[i] = min(max(matteWorking.data[i], 0), 1) }
                let shift = ForegroundShiftCache.shared.shift(photo: photoWorking, matte: matteWorking)
                let shiftFull = shift.resized(width: width, height: height)
                for i in 0..<composite.pixelCount {
                    let a = matteFull.data[i]
                    for c in 0..<3 {
                        let subject = min(max(full.data[i * 3 + c] + shiftFull.data[i * 3 + c], 0), 1)
                        composite.data[i * 3 + c] = subject * a + replacementFull.data[i * 3 + c] * (1 - a)
                    }
                }
            }
            if background.focus.blur > 0 {
                // Focus & Blur at the working resolution.
                let scale = min(1, Float(cap) / Float(max(width, height)))
                let ww = max(1, Int((Float(width) * scale).rounded())), wh = max(1, Int((Float(height) * scale).rounded()))
                let working = full.resized(width: ww, height: wh)
                let replacementWorking = replacementFull?.resized(width: ww, height: wh)
                let blurred = BackgroundStage.render(working, background: background, cache: inputs.cache,
                                                     replacementLinear: replacementWorking, interactive: cap <= interactiveCap,
                                                     maxRadiusFraction: inputs.maxBlurRadiusFraction)
                let sharpWorking = composite.resized(width: ww, height: wh)
                // Defocus weight: how far the blurred result departs from the sharp composite,
                // relative to the local contrast; 1 where it is clearly blurred.
                var weight = FloatImage(width: ww, height: wh, channels: 1)
                for i in 0..<weight.pixelCount {
                    var d: Float = 0
                    for c in 0..<3 { d = max(d, abs(blurred.data[i * 3 + c] - sharpWorking.data[i * 3 + c])) }
                    weight.data[i] = min(d / 0.02, 1)
                }
                weight = weight.gaussianBlurred(sigma: 1.5)
                let blurredUp = blurred.resized(width: width, height: height)
                let weightUp = weight.resized(width: width, height: height)
                let sharpUp = sharpWorking.resized(width: width, height: height)
                for i in 0..<composite.pixelCount {
                    let w = weightUp.data[i]
                    for c in 0..<3 {
                        // Sharp: full detail plus the working-resolution change; defocused: the blur.
                        let keep = composite.data[i * 3 + c] + (blurredUp.data[i * 3 + c] - sharpUp.data[i * 3 + c])
                        composite.data[i * 3 + c] = keep * (1 - w) + blurredUp.data[i * 3 + c] * w
                    }
                }
            }
            full = composite
        }

        let edits = inputs.portrait.faces.filter(PortraitRenderer.hasChanges)
        if !edits.isEmpty, let people = inputs.cache.people {
            try Task.checkCancellation()
            let faces = edits.compactMap { edit -> PortraitRenderer.Face? in
                guard let detected = people.faces.first(where: { $0.box == edit.face.box }) else { return nil }
                return PortraitRenderer.Face(detected: detected, edit: edit)
            }
            let person = inputs.cache.personMatte?.resized(width: width, height: height)
            full = PortraitRenderer.render(full, faces: faces, personMatte: person)
        }
        return full.rgba8FromLinear()
    }
}


/// background.replace's F − I at the working size (rendering-v2 revision 5). The estimate depends on the photo and
/// the matte only, not on the replacement or the blur, and is sequential by definition: a render that changes only
/// those reuses it. One entry, keyed by content, so memory stays bounded.
final class ForegroundShiftCache: @unchecked Sendable {
    static let shared = ForegroundShiftCache()
    private let lock = NSLock()
    private var last: (key: Int, shift: FloatImage)?

    func shift(photo: FloatImage, matte: FloatImage) -> FloatImage {
        var hasher = Hasher()
        hasher.combine(photo.width); hasher.combine(photo.height)
        photo.data.withUnsafeBytes { hasher.combine(bytes: $0) }
        matte.data.withUnsafeBytes { hasher.combine(bytes: $0) }
        let key = hasher.finalize()
        if let hit = lock.withLock({ last?.key == key ? last?.shift : nil }) { return hit }
        let foreground = ForegroundEstimate.estimate(photo, alpha: matte)
        var shift = foreground
        for i in 0..<shift.data.count { shift.data[i] -= photo.data[i] }
        lock.withLock { last = (key, shift) }
        return shift
    }
}
