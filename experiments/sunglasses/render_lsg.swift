import SceneKit
import AppKit
// render_lsg <packDir> <pairId> <outPrefix> W H cx cy pxPerMetre ex.x ex.y ex.z ey.x ey.y ey.z ez.x ez.y ez.z <frame|front|lens> [face.obj]
// render_glasses3 reading the shipped pack (shared/sunglasses/out: sunglasses.json + LSG meshes) instead of the
// normalised OBJ: the reference for the apps' loaders. Pair geometry is metres, x across, y up, z forward, origin at
// the lens centre. Passes:
//   frame  textured frame and arms (lenses write depth only, so they still hide what is behind them)
//   front  the same, but only the front 1.2 cm (the compositor lets hair cover the arms, not the front)
//   lens   lens coverage in white, frame in black (the compositor tints the photo through the white)
// An invisible head ellipsoid and the photo's own face mesh (optional last argument) are drawn depth-only first.
let a = CommandLine.arguments
let W = Double(a[4])!, H = Double(a[5])!, cx = Double(a[6])!, cy = Double(a[7])!, s = Double(a[8])!
let R = (9..<18).map { Double(a[$0])! }
let pass = a[18]; let lensPass = pass == "lens"

// render_lsg <packDir> <pairId> <outPrefix> W H cx cy pxPerMetre ex.x ex.y ex.z ey.x ey.y ey.z ez.x ez.y ez.z <frame|front|lens> [face.obj]
struct PairMaterial: Decodable {
    let role: String; let baseColor: [Double]; let roughness: Double; let metalness: Double; let translucent: Bool
    let base: String?; let normal: String?
}
struct Pair: Decodable { let id: String; let mesh: String; let materials: [PairMaterial] }
struct Pack: Decodable { let pairs: [Pair] }
let packDir = a[1]
let pair = try JSONDecoder().decode(Pack.self, from: Data(contentsOf: URL(fileURLWithPath: packDir + "/sunglasses.json"))).pairs.first { $0.id == a[2] }!

/// LSG 1: "LSG1", u32 version, u32 vertexCount, u32 elementCount, interleaved {pos3 nrm3 uv2} f32, then per element
/// {u32 material, u32 indexCount, u32 indices}.
func loadLSG(_ path: String) -> (SCNGeometry, [Int]) {
    let d = try! Data(contentsOf: URL(fileURLWithPath: path))
    func u32(_ o: Int) -> Int { Int(d.subdata(in: o..<o + 4).withUnsafeBytes { $0.load(as: UInt32.self) }) }
    precondition(d.prefix(4) == Data("LSG1".utf8))
    let vc = u32(8), ec = u32(12), stride = 32
    let vdata = d.subdata(in: 16..<16 + vc * stride)
    let sources = [
        SCNGeometrySource(data: vdata, semantic: .vertex, vectorCount: vc, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride),
        SCNGeometrySource(data: vdata, semantic: .normal, vectorCount: vc, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 12, dataStride: stride),
        SCNGeometrySource(data: vdata, semantic: .texcoord, vectorCount: vc, usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 24, dataStride: stride),
    ]
    var o = 16 + vc * stride; var elements: [SCNGeometryElement] = []; var mats: [Int] = []
    for _ in 0..<ec {
        let m = u32(o), n = u32(o + 4); o += 8
        elements.append(SCNGeometryElement(data: d.subdata(in: o..<o + n * 4), primitiveType: .triangles, primitiveCount: n / 3, bytesPerIndex: 4))
        mats.append(m); o += n * 4
    }
    return (SCNGeometry(sources: sources, elements: elements), mats)
}

func material(_ ms: PairMaterial) -> SCNMaterial {
    let m = SCNMaterial(); m.isDoubleSided = true
    switch (ms.role, lensPass) {
    case ("lens", true): m.lightingModel = .constant; m.diffuse.contents = NSColor.white
    case ("lens", false): m.colorBufferWriteMask = []
    case (_, true): m.lightingModel = .constant; m.diffuse.contents = NSColor.black
    default:
        m.lightingModel = .physicallyBased
        if let b = ms.base, let img = NSImage(contentsOfFile: packDir + "/" + b) { m.diffuse.contents = img }
        else { m.diffuse.contents = NSColor(calibratedRed: ms.baseColor[0], green: ms.baseColor[1], blue: ms.baseColor[2], alpha: 1) }
        if let n = ms.normal, let img = NSImage(contentsOfFile: packDir + "/" + n) { m.normal.contents = img }
        m.roughness.contents = ms.roughness; m.metalness.contents = ms.metalness
        if ms.translucent { m.transparencyMode = .aOne; m.blendMode = .alpha }
    }
    return m
}

let (geometry, materialIndices) = loadLSG(packDir + "/" + pair.mesh)
geometry.materials = materialIndices.map { material(pair.materials[$0]) }
let scene = SCNScene(); let holder = SCNNode(); let pairNode = SCNNode(geometry: geometry)
// Pantoscopic tilt: real frames sit with the arms running back and down to the ears, about 8 degrees.
pairNode.eulerAngles = SCNVector3(-0.14, 0, 0); holder.addChildNode(pairNode)
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
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[3] + "." + pass + ".png"))
