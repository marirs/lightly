import SceneKit
import AppKit
// render_glasses3 <modelDir> <outPrefix> W H cx cy pxPerMetre ex.x ex.y ex.z ey.x ey.y ey.z ez.x ez.y ez.z <frame|front|lens> [face.obj]
// Generic version of render_glasses2 for any model written by normalize.py (model.obj + model.json): metres,
// x across, y up, z forward, origin at the lens centre. Each OBJ material group is named by its role key in
// model.json. Passes:
//   frame  textured frame and arms (lenses write depth only, so they still hide what is behind them)
//   front  the same, but only the front 1.2 cm (the compositor lets hair cover the arms, not the front)
//   lens   lens coverage in white, frame in black (the compositor tints the photo through the white)
// An invisible head ellipsoid and the photo's own face mesh (optional last argument) are drawn depth-only first.
let a = CommandLine.arguments
let dir = a[1], W = Double(a[3])!, H = Double(a[4])!, cx = Double(a[5])!, cy = Double(a[6])!, s = Double(a[7])!
let R = (8..<17).map { Double(a[$0])! }
let pass = a[17]; let lensPass = pass == "lens"

struct MaterialSpec: Decodable {
    let role: String
    let diffuse: String?; let normal: String?; let lens_mask: String?
    let color: [Double]?; let roughness: Double?; let metalness: Double?; let translucent: Bool?
}
struct ModelSpec: Decodable { let materials: [String: MaterialSpec] }
let spec = try JSONDecoder().decode(ModelSpec.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/model.json")))

func material(for key: String) -> SCNMaterial {
    let m = SCNMaterial(); m.isDoubleSided = true
    guard let ms = spec.materials[key] else { m.colorBufferWriteMask = []; return m }
    switch (ms.role, lensPass) {
    case ("lens", true):
        m.lightingModel = .constant; m.diffuse.contents = NSColor.white
    case ("lens", false):
        m.colorBufferWriteMask = []  // depth only: the compositor draws the glass
    case ("lv", true):
        // single-mesh models: the lens is where the opacity map is see-through (precomputed mask, white = lens)
        m.lightingModel = .constant; m.diffuse.contents = NSImage(contentsOfFile: ms.lens_mask!)
    case (_, true):
        m.lightingModel = .constant; m.diffuse.contents = NSColor.black  // the frame still occludes the lens
    default:
        m.lightingModel = .physicallyBased
        if let d = ms.diffuse, let img = NSImage(contentsOfFile: d) { m.diffuse.contents = img }
        else if let c = ms.color { m.diffuse.contents = NSColor(calibratedRed: c[0], green: c[1], blue: c[2], alpha: 1) }
        else { m.diffuse.contents = NSColor(calibratedWhite: 0.03, alpha: 1) }
        if let n = ms.normal, let img = NSImage(contentsOfFile: n) { m.normal.contents = img }
        m.roughness.contents = ms.roughness ?? 0.25; m.metalness.contents = ms.metalness ?? 0.0
        if ms.role == "lv" || ms.translucent == true { m.transparencyMode = .aOne; m.blendMode = .alpha }
    }
    return m
}

let src = try SCNScene(url: URL(fileURLWithPath: dir + "/model.obj"), options: nil)
let scene = SCNScene(); let holder = SCNNode(); let pair = SCNNode()
for child in src.rootNode.childNodes { pair.addChildNode(child) }
// Pantoscopic tilt: real frames sit with the arms running back and down to the ears, about 8 degrees.
pair.eulerAngles = SCNVector3(-0.14, 0, 0); holder.addChildNode(pair)
pair.enumerateHierarchy { node, _ in
    guard let g = node.geometry else { return }
    g.materials = g.materials.map { material(for: $0.name ?? "") }
}
// Invisible head: depth only, drawn first. Lens centre at the origin, arms at x = ±0.075.
let head = SCNNode(geometry: SCNSphere(radius: 1))
head.scale = SCNVector3(0.076, 0.115, 0.098); head.position = SCNVector3(0, -0.026, -0.098)
let hm = SCNMaterial(); hm.colorBufferWriteMask = []; hm.writesToDepthBuffer = true
head.geometry!.materials = [hm]; head.renderingOrder = -10
holder.addChildNode(head)
holder.transform = SCNMatrix4(m11: R[0] * s, m12: R[1] * s, m13: R[2] * s, m14: 0,
                              m21: R[3] * s, m22: R[4] * s, m23: R[5] * s, m24: 0,
                              m31: R[6] * s, m32: R[7] * s, m33: R[8] * s, m34: 0,
                              m41: cx - W / 2, m42: H / 2 - cy, m43: 0, m44: 1)
scene.rootNode.addChildNode(holder)
if a.count > 18 {
    let face = try SCNScene(url: URL(fileURLWithPath: a[18]), options: nil)
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
cam.camera!.orthographicScale = H / 2; cam.camera!.zFar = 5000 + (pass == "front" ? 0.012 : 0.25) * s
cam.position = SCNVector3(0, 0, 5000); scene.rootNode.addChildNode(cam)
if !lensPass {
    let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 1000
    key.eulerAngles = SCNVector3(-0.6, 0.4, 0); scene.rootNode.addChildNode(key)
    let amb = SCNNode(); amb.light = SCNLight(); amb.light!.type = .ambient; amb.light!.intensity = 400
    scene.rootNode.addChildNode(amb)
}
scene.background.contents = NSColor.clear
let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
r.scene = scene; r.pointOfView = cam
let image = r.snapshot(atTime: 0, with: CGSize(width: W, height: H), antialiasingMode: .multisampling4X)
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2] + "." + pass + ".png"))
