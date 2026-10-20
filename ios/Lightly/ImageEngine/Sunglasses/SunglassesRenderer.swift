import Foundation
import SceneKit
import simd
import UIKit

/// `portrait.sunglasses` (rendering-v2 revision 9 §7.5): puts a 3D pair from the sunglasses pack on a face.
///
/// Reference implementation: experiments/sunglasses/wear.py with render_lsg.swift. The pair is rendered by SceneKit,
/// offscreen and orthographically, over the face's region only; the lenses are not drawn by SceneKit but composited
/// as tinted glass over the photo, so the eyes show through.
enum SunglassesRenderer {

    // MARK: - Pose (§7.5 "Pose" and "Placement")

    /// The head's frame in scene units (x right, y up, z towards the viewer, origin at the image centre, pixels).
    struct Pose: Equatable {
        var ex: SIMD3<Float>, ey: SIMD3<Float>, ez: SIMD3<Float>
        /// Pixels per metre, before Size (measurements, placement, occluders use it).
        var pixelsPerMetre: Float
        /// The pair's origin (lens centre) in scene units.
        var origin: SIMD3<Float>
        /// True when the profile correction turned the head (§7.5): the outline clip applies.
        var isProfile: Bool
    }

    /// Landmarks at the render size: analysis pixels × (render width / analysis width).
    static func scaledLandmarks(_ analysis: FaceSunglassesAnalysis, renderWidth: Int) -> [SIMD3<Float>] {
        let r = Float(renderWidth) / Float(analysis.analysisWidth)
        return analysis.landmarks.map { $0 * r }
    }

    /// §7.5 pose from the landmarks (render pixels) and the background probability (`background(x, y)` at render pixels).
    static func pose(landmarks P: [SIMD3<Float>], width W: Int, height H: Int, background: (Float, Float) -> Float) -> Pose {
        func w(_ i: Int) -> SIMD3<Float> { SIMD3(P[i].x, -P[i].y, -P[i].z) }
        var ex = simd_normalize(w(263) - w(33))
        var ez = simd_normalize(simd_cross(ex, w(10) - w(152)))
        let ey = simd_cross(ez, ex)
        let s = simd_length(w(263) - w(33)) / SunglassesConstants.interIrisReferenceMetres
        // Turn correction: the landmarker under-reports turns (it cannot report more than ~65 degrees). The closer the
        // far iris lies to the person's outline (walking outward, away from the near iris) within `yawRampMetres`, the
        // more the turn is raised towards 85 degrees; within `profileMarginMetres` the face is a profile.
        var isProfile = false
        let yaw = atan2(ez.x, ez.z)
        let (near, far) = yaw < 0 ? (473, 468) : (468, 473)
        let margin = farIrisMargin(P, near: near, far: far, width: W, height: H, pixelsPerMetre: s,
                                   upTo: SunglassesConstants.yawRampMetres, background: background)
        let target = SunglassesConstants.profileTargetYawDegrees * .pi / 180
        if let margin, abs(yaw) < target {
            isProfile = margin <= SunglassesConstants.profileMarginMetres
            let raised = abs(yaw) + (target - abs(yaw)) * (1 - margin / SunglassesConstants.yawRampMetres)
                * turnRaiseWeight(yawDegrees: abs(yaw) * 180 / .pi, isProfile: isProfile)
            let angle = (raised - abs(yaw)) * (yaw < 0 ? -1 : 1)
            ex = rotate(ex, about: ey, by: angle)
            ez = rotate(ez, about: ey, by: angle)
        }
        // Placement: the lens plane 15 mm in front of the irises along the head's own axis.
        func sc(_ i: Int) -> SIMD3<Float> { SIMD3(P[i].x - Float(W) / 2, Float(H) / 2 - P[i].y, -P[i].z) }
        let iris = (sc(468) + sc(473)) / 2
        return Pose(ex: ex, ey: ey, ez: ez, pixelsPerMetre: s, origin: iris + s * SunglassesConstants.eyeDepthMetres * ez,
                    isProfile: isProfile)
    }

    /// How much of the turn raise applies (0...1): none while the landmarker's own turn is under
    /// `turnRaiseStartYawDegrees`, where it reads turns truly, rising to all of it at `turnRaiseFullYawDegrees`; always
    /// all of it on a profile. Owner report 2026-10-20: a 35° face whose far iris lay 15 mm from the outline (a narrow
    /// temple against the background) was raised to 55°, so the pair was drawn turned further than the face and the near
    /// eye's outer corner showed beside the near lens.
    static func turnRaiseWeight(yawDegrees: Float, isProfile: Bool) -> Float {
        if isProfile { return 1 }
        let start = SunglassesConstants.turnRaiseStartYawDegrees, full = SunglassesConstants.turnRaiseFullYawDegrees
        return min(max((yawDegrees - start) / (full - start), 0), 1)
    }

    /// Metres from the far iris to the person's outline, walking outward until the background, or nil when the outline
    /// is further than `upTo`.
    ///
    /// The walk runs across the face, perpendicular to its forehead–chin line (10 → 152), from the far iris's position
    /// across the face at the near iris's height: on a profile the far eye is hidden and the landmarkers guess its
    /// height differently (owner report 2026-10-20: Android put it 22 px higher on profile_colour_woman_01, so its walk
    /// ran up to the brow, where the face reaches further, and the pair was turned 64° instead of iOS's 74°).
    static func farIrisMargin(_ P: [SIMD3<Float>], near: Int, far: Int, width W: Int, height H: Int, pixelsPerMetre s: Float,
                              upTo: Float, background: (Float, Float) -> Float) -> Float? {
        let nearIris = SIMD2(P[near].x, P[near].y), farIris = SIMD2(P[far].x, P[far].y)
        var toward = simd_normalize(SIMD2(-(P[152].y - P[10].y), P[152].x - P[10].x))
        if simd_dot(toward, farIris - nearIris) < 0 { toward = -toward }
        let start = nearIris + toward * simd_dot(farIris - nearIris, toward)
        for t in 0...max(Int(upTo * s), 0) {
            let q = start + toward * Float(t)
            let xi = Int(q.x), yi = Int(q.y)
            if xi < 0 || yi < 0 || xi >= W || yi >= H || background(Float(xi) + 0.5, Float(yi) + 0.5) > 0.5 { return Float(t) / s }
        }
        return nil
    }

    /// Rodrigues rotation of `v` about the unit `axis`.
    static func rotate(_ v: SIMD3<Float>, about axis: SIMD3<Float>, by angle: Float) -> SIMD3<Float> {
        let k = simd_normalize(axis)
        return v * cos(angle) + simd_cross(k, v) * sin(angle) + k * simd_dot(k, v) * (1 - cos(angle))
    }

    // MARK: - Lens (§7.5 "Composite" 3)

    /// Transmission T = 1 − 0.95 (darkness/100)^0.75.
    static func transmission(darkness: Double) -> Float { 1 - 0.95 * pow(Float(darkness / 100), 0.75) }

    static func tint(_ lens: EditRecipe.FaceEdit.Sunglasses.Lens) -> SIMD3<Float> {
        switch lens {
        case .brown: SIMD3(1.00, 0.76, 0.52)
        case .green: SIMD3(0.80, 1.00, 0.82)
        case .dark, .gradient, .mirror: SIMD3(0.92, 1.00, 0.95)
        }
    }

    /// The glass over one pixel: `t` runs from 0 at the lenses' top row to 1 at their bottom.
    static func glass(_ input: SIMD3<Float>, sunglasses g: EditRecipe.FaceEdit.Sunglasses, t: Float) -> SIMD3<Float> {
        let reflection = (0.16 * (1 - t) * (1 - t) + 0.03) * SIMD3<Float>(0.85, 0.90, 1.00)
        switch g.lens {
        case .gradient:
            return input * transmission(darkness: g.darkness * Double(1 - 0.7 * t)) * tint(.dark) + reflection
        case .mirror:
            let blueGrey = SIMD3<Float>(0.55, 0.65, 0.80) * (1 - t) + SIMD3<Float>(0.25, 0.30, 0.38) * t
            return input * transmission(darkness: g.darkness) * tint(.dark) + reflection * 3 + 0.35 * blueGrey
        default:
            return input * transmission(darkness: g.darkness) * tint(g.lens) + reflection
        }
    }

    // MARK: - Passes

    struct Passes {
        /// The rendered region in render pixels.
        let x0: Int, y0: Int, width: Int, height: Int
        /// Premultiplied sRGB RGBA8 (frame, front) and lens coverage (0…1).
        let frame: [UInt8], front: [UInt8]
        let lens: [Float]
    }

    /// Renders the three §7.5 passes over the pair's region of a W × H render.
    static func renderPasses(pair: SunglassesPack.Pair, pack: SunglassesPack, pose: Pose, size: Double,
                             landmarks P: [SIMD3<Float>], width W: Int, height H: Int, coverTopUp: Float? = nil) throws -> Passes {
        let s = pose.pixelsPerMetre
        // The pair reaches ~0.16 m behind its lenses and ~0.08 m to each side: a square of ±0.2 m around its origin
        // holds it at any turn.
        let cx = pose.origin.x + Float(W) / 2, cy = Float(H) / 2 - pose.origin.y, half = 0.2 * s
        let x0 = max(0, Int(cx - half)), y0 = max(0, Int(cy - half))
        let x1 = min(W, Int((cx + half).rounded(.up))), y1 = min(H, Int((cy + half).rounded(.up)))
        guard x1 - x0 > 2, y1 - y0 > 2 else { throw SunglassesError.modelFailed("region outside the photo") }
        let rw = x1 - x0, rh = y1 - y0

        let loaded = try pack.load(pair)
        let scene = SCNScene()
        let holder = SCNNode(), pairNode = SCNNode(geometry: loaded.mesh.geometry.copy() as? SCNGeometry)
        pairNode.eulerAngles = SCNVector3(SunglassesConstants.pantoscopicTiltRadians, 0, 0)
        holder.addChildNode(pairNode)
        // Invisible head: depth only, drawn first, in the pair's frame.
        let head = SCNNode(geometry: SCNSphere(radius: 1))
        let radii = SunglassesConstants.headRadiiMetres, centre = SunglassesConstants.headCentreMetres
        head.scale = SCNVector3(radii.x, radii.y, radii.z); head.position = SCNVector3(centre.x, centre.y, centre.z)
        head.geometry!.materials = [depthOnly()]; head.renderingOrder = -10
        holder.addChildNode(head)
        // Behind its centre the head does not narrow (matrix review 2026-10-15: an arm tip that curls inward went into the
        // ellipsoid and came out again before the ear box): an elliptic cylinder of the head's x and y radii continues it
        // to the back.
        let back = SCNNode(geometry: SCNCylinder(radius: 1, height: CGFloat(SunglassesConstants.headBackLengthMetres)))
        back.geometry!.materials = [depthOnly()]; back.renderingOrder = -10
        back.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)   // the cylinder's axis (y) along z
        let backHolder = SCNNode()
        backHolder.scale = SCNVector3(radii.x, radii.y, 1)
        backHolder.position = SCNVector3(centre.x, centre.y, centre.z - SunglassesConstants.headBackLengthMetres / 2)
        backHolder.addChildNode(back)
        holder.addChildNode(backHolder)
        let k = fittedScale(pixelsPerMetre: s, frontWidthMetres: loaded.mesh.frontWidthMetres, landmarks: P) * (1 + SunglassesConstants.sizePerUnit * Float(size))
        // Ears: depth-only boxes on both sides from the face's own ear (earClipStarts) to the back of the head. On a
        // turned face the far side's box starts just behind the hinge (farArmClipStartMetres): the head hides that arm.
        // The near side is the one whose +x points towards the viewer (ex.z > 0 → +x).
        let farSide: Float? = abs(pose.ex.z) > SunglassesConstants.farArmMinTurn ? (pose.ex.z > 0 ? -1 : 1) : nil
        let earStarts = earClipStarts(pose: pose, landmarks: P, width: W, height: H, scale: k)
        for side: Float in [-1, 1] {
            let inner = SunglassesConstants.earBoxInnerX, outer = SunglassesConstants.earBoxOuterX
            let front = side == farSide ? SunglassesConstants.farArmClipStartMetres : earStarts[side < 0 ? 0 : 1]
            let back: Float = 0.30
            let ear = SCNNode(geometry: SCNBox(width: CGFloat(outer - inner), height: 0.4, length: CGFloat(back - front), chamferRadius: 0))
            ear.position = SCNVector3(side * (inner + outer) / 2, 0, -(front + back) / 2)
            ear.geometry!.materials = [depthOnly()]; ear.renderingOrder = -10
            holder.addChildNode(ear)
        }
        let seat = seatedOrigin(pose: pose, landmarks: P, width: W, height: H, mesh: loaded.mesh, scale: k, coverTopUp: coverTopUp)
        let armAngles = armBendAngles(mesh: loaded.mesh, pose: pose, landmarks: P, width: W, height: H, scale: k,
                                      dropMetres: simd_dot(pose.origin - seat, pose.ey) / s)
        if armAngles != [0, 0] { pairNode.geometry = bentGeometry(loaded.mesh, angles: armAngles) }
        holder.transform = SCNMatrix4(m11: pose.ex.x * k, m12: pose.ex.y * k, m13: pose.ex.z * k, m14: 0,
                                      m21: pose.ey.x * k, m22: pose.ey.y * k, m23: pose.ey.z * k, m24: 0,
                                      m31: pose.ez.x * k, m32: pose.ez.y * k, m33: pose.ez.z * k, m34: 0,
                                      m41: seat.x, m42: seat.y, m43: 0, m44: 1)
        scene.rootNode.addChildNode(holder)
        // The photo's own face mesh, depth only, pushed 6 mm away so the nose bridge stays behind the frame's bridge.
        scene.rootNode.addChildNode(faceOccluder(P, pose: pose, width: W, height: H, zShift: -pose.origin.z - SunglassesConstants.faceMeshPushBackMetres * s))

        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera!.usesOrthographicProjection = true
        camera.camera!.orthographicScale = Double(rh) / 2
        camera.camera!.zNear = 1
        camera.position = SCNVector3(Float(x0) + Float(rw) / 2 - Float(W) / 2, Float(H) / 2 - (Float(y0) + Float(rh) / 2), 5000)
        scene.rootNode.addChildNode(camera)
        let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 1000
        key.eulerAngles = SCNVector3(-0.6, 0.4, 0)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light!.type = .ambient; ambient.light!.intensity = 400
        scene.rootNode.addChildNode(key); scene.rootNode.addChildNode(ambient)
        scene.background.contents = UIColor.clear

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene; renderer.pointOfView = camera
        // Large regions (full-resolution exports) have no sub-pixel rim detail to smooth: no supersampling past
        // `passSupersampleMaxSide`, which keeps each snapshot within ~64 MB.
        let ss = max(rw, rh) * SunglassesConstants.passSupersample <= SunglassesConstants.passSupersampleMaxSide
            ? SunglassesConstants.passSupersample : 1
        func snapshot(lensPass: Bool, frontOnly: Bool) -> [UInt8] {
            pairNode.geometry!.materials = loaded.mesh.materialIndices.map { index in
                material(pair.materials[index], textures: loaded.textures[index], lensPass: lensPass)
            }
            key.isHidden = lensPass; ambient.isHidden = lensPass
            camera.camera!.zFar = Double(5000 + (frontOnly ? SunglassesConstants.frontDepthMetres : 0.25) * k)
            // The same orthographic view at `ss` × the pixels, then box-averaged (premultiplied) to the region's size.
            let image = renderer.snapshot(atTime: 0, with: CGSize(width: rw * ss, height: rh * ss), antialiasingMode: .multisampling4X)
            return boxDownsample(rgba8Premultiplied(image, width: rw * ss, height: rh * ss), width: rw, height: rh, factor: ss)
        }
        let frame = snapshot(lensPass: false, frontOnly: false)
        let front = snapshot(lensPass: false, frontOnly: true)
        let lensPixels = snapshot(lensPass: true, frontOnly: false)
        // Lens pass: lenses white, frame black, premultiplied, so red/255 is the lens coverage.
        let lens = (0..<(rw * rh)).map { Float(lensPixels[$0 * 4]) / 255 }
        return Passes(x0: x0, y0: y0, width: rw, height: rh, frame: frame, front: front, lens: lens)
    }

    /// Where each side's ear box starts behind the lens plane, in pair metres, for the −x and +x sides: at the face's own
    /// ear, the depth of its contour point by the ear (234 on −x, 454 on +x, at the tragus) plus `earBehindContourMetres`
    /// (to the top front of the ear, where a real arm goes behind it), clamped to `earClipMinStartMetres`...
    /// `earClipStartMetres`. Owner review 2026-10-20: on a 3/4 face the ear starts ~9 cm behind the lenses, so the fixed
    /// 12 cm (tuned on profiles, where the near ear measures 11.6–12 cm) left the arm's tip showing on top of the ear.
    static func earClipStarts(pose: Pose, landmarks P: [SIMD3<Float>], width W: Int, height H: Int, scale k: Float) -> [Float] {
        let fixed = SunglassesConstants.earClipStartMetres
        guard P.count > 454 else { return [fixed, fixed] }
        func start(_ i: Int) -> Float {
            let q = SIMD3<Float>(P[i].x - Float(W) / 2, Float(H) / 2 - P[i].y, -P[i].z)
            let behind = simd_dot(pose.origin - q, pose.ez) / pose.pixelsPerMetre + SunglassesConstants.earBehindContourMetres
            return min(max(behind, SunglassesConstants.earClipMinStartMetres), fixed) * pose.pixelsPerMetre / k
        }
        return [start(234), start(454)]
    }

    /// Each arm's turn about its hinge (radians, + raises the arm's far end), for the −x and +x arms, so the arm's centre
    /// passes `armRestAboveContourMetres` above the contour point at the top of that side's ear (127 on −x, 356 on +x)
    /// at that point's depth. `dropMetres`: how far the seat lowered the pair (head metres). 0 where the arm has no
    /// profile at that depth (or no face mesh).
    static func armBendAngles(mesh: SunglassesPack.Mesh, pose: Pose, landmarks P: [SIMD3<Float>], width W: Int, height H: Int,
                              scale k: Float, dropMetres: Float) -> [Float] {
        guard P.count > 473, mesh.armCentreY.count == 2 else { return [0, 0] }
        let s = pose.pixelsPerMetre, r = k / s, tilt = SunglassesConstants.pantoscopicTiltRadians
        func sc(_ i: Int) -> SIMD3<Float> { SIMD3(P[i].x - Float(W) / 2, Float(H) / 2 - P[i].y, -P[i].z) }
        let iris = (sc(468) + sc(473)) / 2
        return [(0, 127), (1, 356)].map { side, landmark -> Float in
            let up = simd_dot(sc(landmark) - iris, pose.ey) / s, back = simd_dot(pose.origin - sc(landmark), pose.ez) / s
            let depth = back / r   // pair metres behind the lens plane
            guard depth > SunglassesConstants.armBendFullDepthMetres,
                  let armY = armCentre(mesh.armCentreY[side], atDepth: depth) else { return 0 }
            // The arm's centre at that depth, in head metres above the irises, as placed (tilted, scaled, seated).
            let placedUp = r * (armY * cos(tilt) + depth * sin(tilt)) - dropMetres
            let raise = (up + SunglassesConstants.armRestAboveContourMetres - placedUp) / (r * cos(tilt))
            let angle = atan2(raise, depth - SunglassesConstants.armHingeDepthMetres)
            return min(max(angle, -SunglassesConstants.armBendMaxRadians), SunglassesConstants.armBendMaxRadians)
        }
    }

    /// Linear interpolation of an arm profile (`SunglassesPack.armProfileDepthsMetres`); nil outside it or across a gap.
    static func armCentre(_ profile: [Float], atDepth depth: Float) -> Float? {
        let depths = SunglassesPack.armProfileDepthsMetres, step = depths[1] - depths[0]
        let t = (depth - depths[0]) / step
        guard t >= 0, Int(t) + 1 < depths.count, Int(t) < profile.count - 1 else { return nil }
        let a = profile[Int(t)], b = profile[Int(t) + 1], f = t - Float(Int(t))
        guard !a.isNaN, !b.isNaN else { return a.isNaN ? (b.isNaN ? nil : b) : a }
        return a + (b - a) * f
    }

    /// The pair's geometry with each arm turned about its hinge line (x, at `armHingeDepthMetres` behind the lens plane
    /// and the arm's own height there): no turn in front of the hinge, all of it from `armBendFullDepthMetres` back, a
    /// smoothstep between (a real hinge bends there). Normals turn with their vertices.
    static func bentGeometry(_ mesh: SunglassesPack.Mesh, angles: [Float]) -> SCNGeometry {
        var data = mesh.vertexData
        let hingeZ = -SunglassesConstants.armHingeDepthMetres, fullZ = -SunglassesConstants.armBendFullDepthMetres
        let hingeY = [0, 1].map { armCentre(mesh.armCentreY[$0], atDepth: SunglassesConstants.armHingeDepthMetres + 0.01) ?? 0 }
        data.withUnsafeMutableBytes { raw in
            let f = raw.bindMemory(to: Float.self)
            for i in 0..<mesh.vertexCount {
                let o = i * 8, x = f[o], y = f[o + 1], z = f[o + 2]
                guard z < hingeZ else { continue }
                let side = x < 0 ? 0 : 1
                let u = min(max((hingeZ - z) / (hingeZ - fullZ), 0), 1)
                let a = angles[side] * u * u * (3 - 2 * u)
                guard a != 0 else { continue }
                let c = cos(a), sn = sin(a), dy = y - hingeY[side], dz = z - hingeZ
                f[o + 1] = hingeY[side] + dy * c - dz * sn
                f[o + 2] = hingeZ + dy * sn + dz * c
                let ny = f[o + 4], nz = f[o + 5]
                f[o + 4] = ny * c - nz * sn
                f[o + 5] = ny * sn + nz * c
            }
        }
        let stride = 32, n = mesh.vertexCount
        let sources = [
            SCNGeometrySource(data: data, semantic: .vertex, vectorCount: n, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride),
            SCNGeometrySource(data: data, semantic: .normal, vectorCount: n, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 12, dataStride: stride),
            SCNGeometrySource(data: data, semantic: .texcoord, vectorCount: n, usesFloatComponents: true,
                              componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 24, dataStride: stride),
        ]
        return SCNGeometry(sources: sources, elements: mesh.geometry.elements)
    }

    /// The pair's origin, lowered along the head's up axis so its bridge rests on the nose (owner report 2026-10-16:
    /// the bridge floated a centimetre above the nose, at the brows; the lens centre was on the pupils, but on most
    /// pairs the bridge sits high on the lenses). Target: the bridge's lowest point at landmark 6, the nasal ridge just
    /// below the eye line. The drop is never negative and at most `seatMaxDropOfLensHalfHeight` × half the lens height,
    /// so the pupils stay in the lens's upper part as real frames sit.
    /// `coverTopUp`: when the face's own glasses were painted out, the painted area's highest point above the irises
    /// along ey (scene units): the pair is lowered only while its front's top still reaches it, so the painted-out
    /// strip never shows above the new pair (owner report 2026-10-16: smeared brows above a lowered Club).
    static func seatedOrigin(pose: Pose, landmarks P: [SIMD3<Float>], width W: Int, height H: Int, mesh: SunglassesPack.Mesh,
                             scale k: Float, coverTopUp: Float? = nil) -> SIMD3<Float> {
        guard P.count > 473 else { return pose.origin }
        func sc(_ i: Int) -> SIMD3<Float> { SIMD3(P[i].x - Float(W) / 2, Float(H) / 2 - P[i].y, -P[i].z) }
        let iris = (sc(468) + sc(473)) / 2
        let noseRidge = simd_dot(sc(6) - iris, pose.ey)                  // scene units, + up
        // Full on a near-frontal face, fading out with the turn: on a turned face the lowered far lens met the nose
        // occluder and lost pieces (2026-10-16), and there the eye line already sits the pair well.
        let yaw = abs(atan2(pose.ez.x, pose.ez.z)) * 180 / .pi
        let fade = min(max((SunglassesConstants.seatFadeEndYawDegrees - yaw)
                           / (SunglassesConstants.seatFadeEndYawDegrees - SunglassesConstants.seatFadeStartYawDegrees), 0), 1)
        var drop = fade * min(max(mesh.bridgeBottomMetres * k - noseRidge, 0),
                              SunglassesConstants.seatMaxDropOfLensHalfHeight * mesh.lensHalfHeightMetres * k)
        if let coverTopUp {
            let originUp = simd_dot(pose.origin - iris, pose.ey)
            drop = min(drop, max(0, originUp + mesh.frontTopMetres * k - coverTopUp))
        }
        return pose.origin - pose.ey * drop
    }

    /// The painted-out area's highest point above the irises along ey (scene units at the render size): points of the
    /// patch's rectangle (`sunglasses.removed.rect`, normalised), sampled on a 32 × 32 grid, within 0.06 m of the
    /// irises along ex. nil when none.
    static func paintedTopUp(_ rect: EditRecipe.Rect, pose: Pose, landmarks P: [SIMD3<Float>], width W: Int, height H: Int) -> Float? {
        let irisX = (P[468].x + P[473].x) / 2 - Float(W) / 2, irisY = Float(H) / 2 - (P[468].y + P[473].y) / 2
        let ex2 = simd_normalize(SIMD2(pose.ex.x, pose.ex.y)), ey2 = simd_normalize(SIMD2(pose.ey.x, pose.ey.y))
        let reach = 0.06 * pose.pixelsPerMetre
        var best: Float?
        for j in 0...31 { for i in 0...31 {
            let x = Float(rect.x + rect.width * Double(i) / 31) * Float(W) - Float(W) / 2
            let y = Float(H) / 2 - Float(rect.y + rect.height * Double(j) / 31) * Float(H)
            let d = SIMD2(x - irisX, y - irisY)
            guard abs(simd_dot(d, ex2)) < reach else { continue }
            let up = simd_dot(d, ey2)
            if best == nil || up > best! { best = up }
        } }
        return best
    }

    /// The pair's scale in pixels per metre before the Size slider: the eye-corner scale, but never so large that the
    /// front is wider than `widthFitCheekFactor` × the face's width at the cheek points 234/454.
    static func fittedScale(pixelsPerMetre s: Float, frontWidthMetres: Float, landmarks P: [SIMD3<Float>]) -> Float {
        guard frontWidthMetres > 0, P.count > 454 else { return s }
        let cheeks = simd_distance(SIMD3(P[454].x, -P[454].y, -P[454].z), SIMD3(P[234].x, -P[234].y, -P[234].z))
        guard cheeks > 0 else { return s }   // no face mesh (a fixed-pose render)
        return min(s, SunglassesConstants.widthFitCheekFactor * cheeks / frontWidthMetres)
    }

    /// Averages each `factor` × `factor` block of a premultiplied RGBA8 image (`width·factor` × `height·factor`).
    static func boxDownsample(_ big: [UInt8], width: Int, height: Int, factor: Int) -> [UInt8] {
        guard factor > 1 else { return big }
        let bigWidth = width * factor, n = factor * factor
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            var sum = SIMD4<Int>.zero
            for dy in 0..<factor { for dx in 0..<factor {
                let i = ((y * factor + dy) * bigWidth + x * factor + dx) * 4
                sum &+= SIMD4(Int(big[i]), Int(big[i + 1]), Int(big[i + 2]), Int(big[i + 3]))
            } }
            let o = (y * width + x) * 4
            for c in 0..<4 { out[o + c] = UInt8((sum[c] + n / 2) / n) }
        } }
        return out
    }

    private static func depthOnly() -> SCNMaterial {
        let m = SCNMaterial(); m.colorBufferWriteMask = []; m.writesToDepthBuffer = true; m.isDoubleSided = true
        return m
    }

    private static func material(_ spec: SunglassesPack.Material, textures: (base: UIImage?, normal: UIImage?)?, lensPass: Bool) -> SCNMaterial {
        let m = SCNMaterial(); m.isDoubleSided = true
        switch (spec.role, lensPass) {
        case (.lens, true): m.lightingModel = .constant; m.diffuse.contents = UIColor.white
        case (.lens, false): m.colorBufferWriteMask = []   // depth only: the compositor draws the glass
        case (.frame, true): m.lightingModel = .constant; m.diffuse.contents = UIColor.black   // still hides the lens behind it
        case (.frame, false):
            m.lightingModel = .physicallyBased
            if let base = textures?.base { m.diffuse.contents = base }
            else { m.diffuse.contents = UIColor(red: spec.baseColor[0], green: spec.baseColor[1], blue: spec.baseColor[2], alpha: 1) }
            if let normal = textures?.normal { m.normal.contents = normal }
            m.roughness.contents = spec.roughness; m.metalness.contents = spec.metalness
            if spec.translucent { m.transparencyMode = .aOne; m.blendMode = .alpha }
        }
        return m
    }

    /// The face mesh (468 landmarks, MediaPipe's canonical triangles) in scene units, depth only.
    private static func faceOccluder(_ P: [SIMD3<Float>], pose: Pose, width W: Int, height H: Int, zShift: Float) -> SCNNode {
        let vertices = (0..<468).map { SCNVector3(P[$0].x - Float(W) / 2, Float(H) / 2 - P[$0].y, -P[$0].z + zShift) }
        // On a profile the whole mesh hides the far lens behind the face; otherwise only the nose (see noseTriangles).
        // Near frontal (|yaw| under `noseOcclusionMinYawDegrees`) nothing: a lens sits in front of the nose, and with the
        // pair resting on the nose (seatedOrigin) the nose cut its lower inner corners (2026-10-16).
        let yawDegrees = abs(atan2(pose.ez.x, pose.ez.z)) * 180 / .pi
        let indices: [UInt16] = pose.isProfile ? FaceMeshTriangles.indices
            : (yawDegrees < SunglassesConstants.noseOcclusionMinYawDegrees ? [] : noseTriangles(P, pose: pose, width: W, height: H))
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)], elements: [element])
        geometry.materials = [depthOnly()]
        let node = SCNNode(geometry: geometry); node.renderingOrder = -10
        return node
    }

    /// The face mesh's nose (matrix review 2026-10-15): only triangles whose three landmarks lie within
    /// `noseHalfWidthMetres` of the face's centre line and between `noseTopMetres` and `noseBottomMetres` (head frame,
    /// from the irises' midpoint) occlude. The rest of the mesh (brows, cheeks) is too coarse in depth this close to the
    /// lenses and cut jagged pieces out of the far lens; the head ellipsoid covers those parts.
    static func noseTriangles(_ P: [SIMD3<Float>], pose: Pose, width W: Int, height H: Int) -> [UInt16] {
        func scene(_ i: Int) -> SIMD3<Float> { SIMD3(P[i].x - Float(W) / 2, Float(H) / 2 - P[i].y, -P[i].z) }
        let iris = (scene(468) + scene(473)) / 2, s = pose.pixelsPerMetre
        let isNose: [Bool] = (0..<468).map { i in
            let d = scene(i) - iris
            let x = simd_dot(d, pose.ex) / s, y = simd_dot(d, pose.ey) / s
            return abs(x) < SunglassesConstants.noseHalfWidthMetres && y < SunglassesConstants.noseTopMetres
                && y > SunglassesConstants.noseBottomMetres
        }
        let all = FaceMeshTriangles.indices
        var out: [UInt16] = []
        for t in stride(from: 0, to: all.count, by: 3) where isNose[Int(all[t])] && isNose[Int(all[t + 1])] && isNose[Int(all[t + 2])] {
            out.append(contentsOf: all[t..<t + 3])
        }
        return out
    }

    private static func rgba8Premultiplied(_ image: UIImage, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let cg = image.cgImage else { return pixels }
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    // MARK: - Composite (§7.5 "Composite" 2–5)

    /// The person's analysis maps at render pixels, over every face (hair: max, background: min).
    struct Maps {
        let analyses: [FaceSunglassesAnalysis]
        let scale: Float   // analysis pixels per render pixel
        // Called per pixel: plain loops, no intermediate arrays.
        func hair(_ x: Float, _ y: Float) -> Float {
            var best: Float = 0
            for a in analyses { if let v = a.hair.sample(x: x * scale, y: y * scale), v > best { best = v } }
            return best
        }
        func background(_ x: Float, _ y: Float) -> Float {
            var best: Float = 1
            for a in analyses { if let v = a.background.sample(x: x * scale, y: y * scale), v < best { best = v } }
            return best
        }
    }

    /// Composites one face's pair onto `image` (linear RGB at render size; the arithmetic is in sRGB-encoded values).
    static func composite(_ passes: Passes, onto image: inout FloatImage, sunglasses g: EditRecipe.FaceEdit.Sunglasses,
                          pose: Pose, irisSpan d: Float, maps: Maps) {
        let rw = passes.width, rh = passes.height, n = rw * rh
        // Per-pixel planes over the region.
        var background = [Float](repeating: 1, count: n), hair = FloatImage(width: rw, height: rh, channels: 1)
        DispatchQueue.concurrentPerform(iterations: rh) { y in
            for x in 0..<rw {
                let px = Float(passes.x0 + x) + 0.5, py = Float(passes.y0 + y) + 0.5
                background[y * rw + x] = maps.background(px, py)
                hair.data[y * rw + x] = maps.hair(px, py)
            }
        }
        hair = hair.gaussianBlurred(sigma: 2)
        var frameAlpha = (0..<n).map { Float(passes.frame[$0 * 4 + 3]) / 255 }
        let frontAlpha = (0..<n).map { Float(passes.front[$0 * 4 + 3]) / 255 }
        var lens = passes.lens
        // 5. Profile clip (applied to coverage up front): lens and frame stay within 4 mm of the person.
        if pose.isProfile {
            let near = nearPerson(background, width: rw, height: rh, radius: SunglassesConstants.profileOverhangMetres * pose.pixelsPerMetre)
            for i in 0..<n { lens[i] *= near[i]; frameAlpha[i] *= near[i] }
        }
        // 2. Contact shadow: coverage blurred, shifted down-right, multiplies the photo on the person.
        var coverage = FloatImage(width: rw, height: rh, channels: 1)
        for i in 0..<n { coverage.data[i] = max(frameAlpha[i], lens[i]) }
        coverage = coverage.gaussianBlurred(sigma: max(1, SunglassesConstants.shadowSigmaOfIrisSpan * d))
        let dx = Int(SunglassesConstants.shadowOffsetOfIrisSpan.x * d), dy = Int(SunglassesConstants.shadowOffsetOfIrisSpan.y * d)
        // Lens rows, for the reflection and gradient (t = 0 at the top lens row, 1 at the bottom one).
        var top = rh, bottom = -1
        for y in 0..<rh { for x in 0..<rw where lens[y * rw + x] > 0.5 { top = min(top, y); bottom = max(bottom, y); break } }
        let span = Float(max(1, bottom - top))

        for y in 0..<rh {
            let t = min(max(Float(y - top) / span, 0), 1)
            for x in 0..<rw {
                let i = y * rw + x
                let o = image.index(passes.x0 + x, passes.y0 + y)
                // §7.5 composites in sRGB-encoded values, as the approved trial renders did (linear blending lightens
                // the lenses and brightens the frame's anti-aliased edges against skin).
                var px = ColourMath.encoded(fromLinear: SIMD3(image.data[o], image.data[o + 1], image.data[o + 2]))
                let sx = x - dx, sy = y - dy
                if background[i] < 0.5, sx >= 0, sy >= 0, sx < rw, sy < rh {
                    px *= 1 - coverage.data[sy * rw + sx] * SunglassesConstants.shadowStrength
                }
                // 3. Lenses: the photo seen through the tinted glass.
                let l = lens[i]
                if l > 0 { px = px * (1 - l) + glass(px, sunglasses: g, t: t) * l }
                // 4. Frame: hair covers the arms (frame beyond the front 12 mm), never the front.
                let fa = frameAlpha[i]
                if fa > 0 {
                    let hairCover = min(max((hair.data[i] - 0.3) / 0.4, 0), 1)
                    let alpha = min(frontAlpha[i] + (fa - frontAlpha[i]) * (1 - hairCover), fa)
                    let p = passes.frame, a8 = Float(p[i * 4 + 3])
                    // Unpremultiplied sRGB-encoded frame colour.
                    let colour = SIMD3(min(Float(p[i * 4]) / a8, 1), min(Float(p[i * 4 + 1]) / a8, 1), min(Float(p[i * 4 + 2]) / a8, 1))
                    px = px * (1 - alpha) + colour * alpha
                }
                let back = ColourMath.linear(fromEncoded: px)
                image.data[o] = back.x; image.data[o + 1] = back.y; image.data[o + 2] = back.z
            }
        }
    }

    /// About 1 within `radius` pixels of the person (background < 0.5), 0 beyond: dilated at quarter resolution as the
    /// reference, then up-sampled and kept soft. The reference thresholded it, which leaves a quarter-resolution
    /// staircase where the clip crosses the frame's bridge on a profile.
    static func nearPerson(_ background: [Float], width: Int, height: Int, radius: Float) -> [Float] {
        var person = FloatImage(width: width, height: height, channels: 1)
        for i in 0..<person.pixelCount { person.data[i] = background[i] < 0.5 ? 1 : 0 }
        let qw = max(1, width / 4), qh = max(1, height / 4)
        let quarter = person.resized(width: qw, height: qh).dilated(threshold: 0.5, radius: max(1, Int(radius / 4)))
        let up = quarter.gaussianBlurred(sigma: 0.75).resized(width: width, height: height)
        return (0..<person.pixelCount).map { min(max((up.data[$0] - 0.25) / 0.5, 0), 1) }
    }

    // MARK: - Stage entry

    /// Applies every face's sunglasses to `image` (linear RGB at render size). Faces without a pair, without an analysis,
    /// or not readable are left unchanged.
    /// `removedPatch` finds a painted-out glasses patch by digest (RemovePatchStore); a missing one is skipped, never
    /// recomputed (remove-evaluation §7).
    static func render(_ image: inout FloatImage, faces: [(edit: EditRecipe.FaceEdit, analysis: FaceSunglassesAnalysis)],
                       allAnalyses: [FaceSunglassesAnalysis], pack: SunglassesPack, removedPatch: (String) -> RemovePatch? = { _ in nil }) {
        guard let first = allAnalyses.first else { return }
        let maps = Maps(analyses: allAnalyses, scale: Float(first.analysisWidth) / Float(image.width))
        for face in faces {
            guard let g = face.edit.sunglasses, let id = g.pair, let pair = pack.pair(id), face.analysis.isReadable else { continue }
            // 1. The face's own glasses, painted out (only while a pair is chosen).
            var painted: EditRecipe.Rect?
            if let removed = g.removed, let patch = removedPatch(removed.patch.sha256) {
                SunglassesRemoval.composite(patch, onto: &image)
                painted = removed.rect
            }
            let P = scaledLandmarks(face.analysis, renderWidth: image.width)
            let pose = pose(landmarks: P, width: image.width, height: image.height, background: maps.background)
            let coverTop = painted.map { paintedTopUp($0, pose: pose, landmarks: P, width: image.width, height: image.height) } ?? nil
            guard let passes = try? renderPasses(pair: pair, pack: pack, pose: pose, size: g.size, landmarks: P,
                                                 width: image.width, height: image.height, coverTopUp: coverTop) else { continue }
            let d = face.analysis.irisSpan * Float(image.width) / Float(face.analysis.analysisWidth)
            composite(passes, onto: &image, sunglasses: g, pose: pose, irisSpan: d, maps: maps)
        }
    }
}
