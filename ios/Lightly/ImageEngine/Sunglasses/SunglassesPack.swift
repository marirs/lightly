import CryptoKit
import Foundation
import SceneKit
import UIKit

/// The bundled sunglasses pack (`SunglassesPack/`, format "lightly-sunglasses-pack" 1, built by
/// shared/sunglasses/build_sunglasses.py): the ten owner-approved pairs of Portrait › Sunglasses (rendering-v2 §7.5).
///
/// Pair geometry is in metres: x across (the wearer's left at +x), y up, z forward, origin at the centre of the lenses.
/// Every file is checked against the manifest's SHA-256 before use; a pair whose files do not match is not offered.
struct SunglassesPack: Sendable {

    struct Material: Decodable, Sendable, Equatable {
        enum Role: String, Decodable, Sendable { case lens, frame }
        let role: Role
        let baseColor: [Double]
        let roughness: Double
        let metalness: Double
        let translucent: Bool
        let base: String?
        let baseSha256: String?
        let normal: String?
        let normalSha256: String?
    }

    struct Pair: Decodable, Sendable, Equatable, Identifiable {
        let id: String
        /// Owner-approved shape name shown under the tile (Oval, Club, Pilot, ...).
        let name: String
        let order: Int
        let mesh: String
        let meshSha256: String
        let thumbnail: String
        let thumbnailSha256: String
        let materials: [Material]
    }

    private struct Manifest: Decodable {
        let format: String
        let formatVersion: Int
        let pairs: [Pair]
    }

    enum LoadError: Error, Equatable {
        case missing
        case unsupportedFormat(String)
        case digestMismatch(String)
        case malformedMesh(String)
    }

    let root: URL
    /// The pairs in the approved order.
    let pairs: [Pair]

    static let bundled: SunglassesPack? = try? SunglassesPack(root: Bundle.main.bundleURL.appendingPathComponent("SunglassesPack"))

    init(root: URL) throws {
        let manifestURL = root.appendingPathComponent("sunglasses.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw LoadError.missing }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.format == "lightly-sunglasses-pack", manifest.formatVersion == 1 else {
            throw LoadError.unsupportedFormat("\(manifest.format) \(manifest.formatVersion)")
        }
        // Paths come from the manifest; only the pair's own files under the pack root are accepted.
        for pair in manifest.pairs {
            guard pair.id.range(of: "^sun-[0-9a-f]{12}$", options: .regularExpression) != nil,
                  pair.mesh == "mesh/\(pair.id).lsg", pair.thumbnail == "thumb/\(pair.id).png" else {
                throw LoadError.unsupportedFormat("pair \(pair.id) names \(pair.mesh), \(pair.thumbnail)")
            }
            for material in pair.materials {
                for path in [material.base, material.normal].compactMap({ $0 }) where !path.hasPrefix("tex/\(pair.id)-") || path.contains("..") {
                    throw LoadError.unsupportedFormat("pair \(pair.id) names texture \(path)")
                }
            }
        }
        self.root = root
        self.pairs = manifest.pairs.sorted { $0.order < $1.order }
    }

    func pair(_ id: String) -> Pair? { pairs.first { $0.id == id } }

    /// Reads a pack file after checking its SHA-256 against the manifest.
    func verifiedData(_ path: String, sha256 expected: String) throws -> Data {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw LoadError.digestMismatch(path) }
        return data
    }

    /// The pair's tile picture, verified and decoded once.
    func thumbnail(_ pair: Pair) -> UIImage? {
        if let hit = Self.thumbnails.withLock({ $0[pair.id] }) { return hit }
        let image = (try? verifiedData(pair.thumbnail, sha256: pair.thumbnailSha256)).flatMap { UIImage(data: $0) }
        Self.thumbnails.withLock { $0[pair.id] = image }
        return image
    }

    private static let thumbnails = LockedBox<[String: UIImage?]>([:])

    // MARK: - LSG 1

    /// A decoded LSG mesh: one SceneKit geometry whose elements are in file order, and each element's material index.
    struct Mesh {
        let geometry: SCNGeometry
        let materialIndices: [Int]
        /// The front's width in metres: the x extent of the vertices within `SunglassesConstants.frontPlaneMetres` of
        /// the lens plane (used to fit the pair to narrow faces).
        let frontWidthMetres: Float
        /// The lowest point of the bridge (frame vertices within 4 mm of x = 0 and 2 cm of the lens plane), metres above
        /// the lens centre: where the pair rests on the nose. 0 when the pair has no such vertices.
        var bridgeBottomMetres: Float = 0
        /// Half the lenses' height (metres), from the lens vertices.
        var lensHalfHeightMetres: Float = 0
    }

    /// LSG 1 (shared/sunglasses/build_sunglasses.py): "LSG1", u32 version, u32 vertexCount, u32 elementCount, then
    /// vertexCount × {f32 position[3], normal[3], uv[2]} interleaved (32 bytes, uv origin top-left), then per element
    /// {u32 materialIndex, u32 indexCount, u32 indices[indexCount]} (triangles). Little-endian.
    static func decodeLSG(_ data: Data, materialCount: Int) throws -> Mesh {
        func u32(_ offset: Int) throws -> Int {
            guard offset + 4 <= data.count else { throw LoadError.malformedMesh("truncated at \(offset)") }
            return Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) })
        }
        guard data.count >= 16, data.prefix(4) == Data("LSG1".utf8), try u32(4) == 1 else { throw LoadError.malformedMesh("header") }
        let vertexCount = try u32(8), elementCount = try u32(12), stride = 32
        let vertexEnd = 16 + vertexCount * stride
        guard vertexCount > 0, elementCount > 0, vertexEnd <= data.count else { throw LoadError.malformedMesh("vertices") }
        let vertices = data.subdata(in: 16..<vertexEnd)
        let sources = [
            SCNGeometrySource(data: vertices, semantic: .vertex, vectorCount: vertexCount, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride),
            SCNGeometrySource(data: vertices, semantic: .normal, vectorCount: vertexCount, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 12, dataStride: stride),
            SCNGeometrySource(data: vertices, semantic: .texcoord, vectorCount: vertexCount, usesFloatComponents: true,
                              componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 24, dataStride: stride),
        ]
        var offset = vertexEnd
        var elements: [SCNGeometryElement] = []
        var materialIndices: [Int] = []
        for _ in 0..<elementCount {
            let material = try u32(offset), count = try u32(offset + 4)
            offset += 8
            guard material < materialCount, count % 3 == 0, offset + count * 4 <= data.count else { throw LoadError.malformedMesh("element") }
            let indices = data.subdata(in: offset..<offset + count * 4)
            // Every index must address a vertex (a bad index would read outside the vertex buffer on the GPU).
            let inRange = indices.withUnsafeBytes { raw in
                raw.bindMemory(to: UInt32.self).allSatisfy { Int(UInt32(littleEndian: $0)) < vertexCount }
            }
            guard inRange else { throw LoadError.malformedMesh("index out of range") }
            elements.append(SCNGeometryElement(data: indices, primitiveType: .triangles, primitiveCount: count / 3, bytesPerIndex: 4))
            materialIndices.append(material)
            offset += count * 4
        }
        let frontXs = vertices.withUnsafeBytes { raw in
            (0..<vertexCount).compactMap { i -> Float? in
                let z = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * stride + 8, as: UInt32.self)))
                guard abs(z) < SunglassesConstants.frontPlaneMetres else { return nil }
                return Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * stride, as: UInt32.self)))
            }
        }
        let frontWidth = (frontXs.max() ?? 0) - (frontXs.min() ?? 0)
        return Mesh(geometry: SCNGeometry(sources: sources, elements: elements), materialIndices: materialIndices, frontWidthMetres: frontWidth)
    }

    /// The pair's mesh and its textures, verified. Cached per pair id: the files never change while the app runs.
    func load(_ pair: Pair) throws -> (mesh: Mesh, textures: [Int: (base: UIImage?, normal: UIImage?)]) {
        if let hit = Self.cache.withLock({ $0[pair.id] }) { return hit }
        let mesh = try Self.decodeLSG(try verifiedData(pair.mesh, sha256: pair.meshSha256), materialCount: pair.materials.count)
        var textures: [Int: (base: UIImage?, normal: UIImage?)] = [:]
        for (index, material) in pair.materials.enumerated() {
            let base = try material.base.map { UIImage(data: try verifiedData($0, sha256: material.baseSha256 ?? "")) } ?? nil
            let normal = try material.normal.map { UIImage(data: try verifiedData($0, sha256: material.normalSha256 ?? "")) } ?? nil
            textures[index] = (base, normal)
        }
        var fitted = mesh
        Self.measureFit(&fitted, data: try verifiedData(pair.mesh, sha256: pair.meshSha256), pair: pair)
        let loaded = (mesh: fitted, textures: textures)
        Self.cache.withLock { $0[pair.id] = loaded }
        return loaded
    }

    /// Fills `bridgeBottomMetres` and `lensHalfHeightMetres` from the LSG data (frame vs lens by material role).
    static func measureFit(_ mesh: inout Mesh, data: Data, pair: Pair) {
        func u32(_ o: Int) -> Int { Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }) }
        func f32(_ o: Int) -> Float { Float(bitPattern: UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) })) }
        let vertexCount = u32(8), elementCount = u32(12)
        var offset = 16 + vertexCount * 32
        var bridgeBottom = Float.infinity, lensTop = -Float.infinity, lensBottom = Float.infinity
        for _ in 0..<elementCount {
            let material = u32(offset), count = u32(offset + 4)
            offset += 8
            let isLens = pair.materials.indices.contains(material) && pair.materials[material].role == .lens
            for k in 0..<count {
                let v = 16 + u32(offset + k * 4) * 32
                let x = f32(v), y = f32(v + 4), z = f32(v + 8)
                guard abs(z) < SunglassesConstants.frontPlaneMetres + 0.01 else { continue }
                if isLens { lensTop = max(lensTop, y); lensBottom = min(lensBottom, y) }
                else if abs(x) < 0.004, abs(z) < SunglassesConstants.frontPlaneMetres { bridgeBottom = min(bridgeBottom, y) }
            }
            offset += count * 4
        }
        mesh.bridgeBottomMetres = bridgeBottom.isFinite ? bridgeBottom : 0
        mesh.lensHalfHeightMetres = lensTop > lensBottom ? (lensTop - lensBottom) / 2 : 0
    }

    private static let cache = LockedBox<[String: (mesh: Mesh, textures: [Int: (base: UIImage?, normal: UIImage?)])]>([:])
}

/// A small lock-protected value (the pack cache is filled from render threads).
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
