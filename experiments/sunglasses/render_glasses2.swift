import SceneKit
import AppKit
// render_glasses2 <model.obj> <texDir> <outPrefix> W H cx cy pxPerMetre ex.x ex.y ex.z ey.x ey.y ey.z ez.x ez.y ez.z <frame|lens>
// Writes one of two passes the size of the photo (transparent background), both depth-tested against an invisible head:
//   <outPrefix>.frame.png  frame + arms with the model's own textures (base colour, normal, roughness)
//   <outPrefix>.lens.png   front-lens coverage (unlit white) so the compositor can tint the real photo through it
// The head is a depth-only ellipsoid behind the lenses, so the far arm and the arm tips past the temple are hidden.
let a = CommandLine.arguments
let tex = a[2], W = Double(a[4])!, H = Double(a[5])!, cx = Double(a[6])!, cy = Double(a[7])!, s = Double(a[8])!
let R = (9..<18).map { Double(a[$0])! }

let pass = a[18]  // "frame" (textured frame and arms), "front" (frame without arms, for hair masking) or "lens"
let lensPass = pass == "lens"
let src = try SCNScene(url: URL(fileURLWithPath: a[1]), options: nil)
let scene = SCNScene(); let holder = SCNNode(); let pair = SCNNode()
for child in src.rootNode.childNodes { pair.addChildNode(child) }
// Pantoscopic tilt: real frames sit with the arms running back and down to the ears, about 8 degrees.
pair.eulerAngles = SCNVector3(-0.14, 0, 0); holder.addChildNode(pair)
// SceneKit loads the OBJ as one node whose geometry has one element per OBJ object (BACK_LENS, tips, FRONT_LENS,
// main), in file order, so materials are assigned per element. Lens elements carry the "opacity" material.
pair.enumerateChildNodes { node, _ in
    guard let g = node.geometry else { return }
    let originalNames = g.materials.map { ($0.name ?? "").lowercased() }
    var lensElementsSeen = 0
    g.materials = (0..<g.elements.count).map { i in
        let name = i < originalNames.count ? originalNames[i] : ""
        let isLens = name.contains("opacity") || name.contains("lens")
        if isLens { lensElementsSeen += 1 }
        let m = SCNMaterial()
        if isLens && lensElementsSeen == 1 {
            // The back lens duplicates the front one; drawing both doubles the tint.
            m.colorBufferWriteMask = []; m.writesToDepthBuffer = false
        } else if lensPass {
            m.lightingModel = .constant
            m.diffuse.contents = isLens ? NSColor.white : NSColor.black  // frame drawn black so it still occludes the lens
        } else if isLens {
            m.colorBufferWriteMask = []  // lenses come from the compositor, which tints the real photo
        } else {
            m.lightingModel = .physicallyBased
            m.diffuse.contents = NSImage(contentsOfFile: tex + "/Image_3.jpg")
            m.normal.contents = NSImage(contentsOfFile: tex + "/Image_1.png")
            m.roughness.contents = 0.22; m.metalness.contents = 0.0
        }
        return m
    }
}
// Invisible head: depth only, drawn first. Model units are metres, lens plane at z = 0, arms at x = ±0.075.
let head = SCNNode(geometry: SCNSphere(radius: 1))
head.scale = SCNVector3(0.076, 0.115, 0.098); head.position = SCNVector3(0, -0.02, -0.098)
let hm = SCNMaterial(); hm.colorBufferWriteMask = []; hm.writesToDepthBuffer = true
head.geometry!.materials = [hm]; head.renderingOrder = -10
holder.addChildNode(head)
holder.transform = SCNMatrix4(m11: R[0] * s, m12: R[1] * s, m13: R[2] * s, m14: 0,
                              m21: R[3] * s, m22: R[4] * s, m23: R[5] * s, m24: 0,
                              m31: R[6] * s, m32: R[7] * s, m33: R[8] * s, m34: 0,
                              m41: cx - W / 2, m42: H / 2 - cy, m43: 0, m44: 1)
scene.rootNode.addChildNode(holder)
// Optional face occluder (argv[19]): the photo's own face mesh in scene units, depth only, so the nose and brow
// hide the far lens on turned heads. Written by wear.py from the 478 landmarks + MediaPipe's canonical triangles.
if a.count > 19 {
    let face = try SCNScene(url: URL(fileURLWithPath: a[19]), options: nil)
    for child in face.rootNode.childNodes {
        child.enumerateHierarchy { node, _ in
            guard let g = node.geometry else { return }
            let fm = SCNMaterial(); fm.colorBufferWriteMask = []; fm.writesToDepthBuffer = true; fm.isDoubleSided = true
            g.materials = [fm]; node.renderingOrder = -10
        }
        scene.rootNode.addChildNode(child)
    }
}
let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera!.usesOrthographicProjection = true
cam.camera!.orthographicScale = H / 2; cam.camera!.zFar = 5000 + (pass == "front" ? 0.012 : 0.25) * s  // "front" stops 1.2 cm behind the lenses; else the whole pair incl. arm tips
cam.position = SCNVector3(0, 0, 5000); scene.rootNode.addChildNode(cam)
if !lensPass {
    let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 1000
    key.eulerAngles = SCNVector3(-0.6, 0.4, 0); scene.rootNode.addChildNode(key)
    let amb = SCNNode(); amb.light = SCNLight(); amb.light!.type = .ambient; amb.light!.intensity = 400
    scene.rootNode.addChildNode(amb)
}
scene.background.contents = NSColor.clear

let path = a[3] + "." + pass + ".png"
let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
r.scene = scene; r.pointOfView = cam
let image = r.snapshot(atTime: 0, with: CGSize(width: W, height: H), antialiasingMode: .multisampling4X)
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
