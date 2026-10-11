import CryptoKit
import Foundation

/// A table look's develop.global stage: a precomputed LUT file shipped in the pack
/// (`globalOverride` with `source: "cube"`, rendering-v2 §4.4), used in place of the recipe bake.
///
/// The file has exactly the grid, layout and domain of the app's own global bake
/// (rendering-v2 §Bake): 33³ nodes, `[b][g][r][rgb]` with red fastest, sRGB-encoded in and out,
/// stored as little-endian IEEE half floats. Only that one encoding is accepted; anything else in
/// the manifest refuses the preset.
struct GlobalTableRef: Sendable, Equatable {
    static let supportedSource = "cube"
    static let supportedDimension = LUT3D.contractDimension
    static let supportedEncoding = "rgb-float16-red-fastest"
    /// Table files live in the pack's `luts/` folder and nowhere else.
    static let tableDirectoryName = "luts"
    static let tableFileExtension = "f16"

    /// The manifest's `lutFile`, relative to the pack directory (e.g. `luts/look-<id>.f16`).
    let relativePath: String
    /// `relativePath` resolved against the pack directory the manifest was read from.
    let fileURL: URL
    /// Lowercase hex SHA-256 of the file's bytes; checked when the file is read.
    let sha256: String
    let dimension: Int

    var expectedByteCount: Int { dimension * dimension * dimension * 3 * MemoryLayout<UInt16>.size }

    /// Whether `lutFile` names a plain file directly inside `luts/`. The manifest is untrusted, so a
    /// path that could reach outside the pack (`..`, nested folders, absolute paths) is refused.
    static func isAcceptedRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == tableDirectoryName else { return false }
        let fileName = components[1]
        return fileName.hasSuffix(".\(tableFileExtension)") && fileName.count > tableFileExtension.count + 1
            && !fileName.hasPrefix(".") && !fileName.contains("\\")
    }

    static func isLowercaseHexSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

/// Why a table look's LUT could not be used. The frame fails rather than rendering without the
/// Look: showing the photo unchanged under a selected preset would misrepresent it.
enum GlobalTableError: Error, Equatable {
    case unreadable(path: String, detail: String)
    case unexpectedSize(path: String, expectedBytes: Int, actualBytes: Int)
    case digestMismatch(path: String, expected: String, actual: String)
    case nonFiniteValue(path: String, index: Int)
}

/// Reads table LUT files and adapts them to the dimensions the renderer asks for.
enum GlobalTableLoader {

    /// Reads, verifies and converts the table to the in-memory LUT the recipe bake produces
    /// (RGBA float32, alpha 1, red fastest), at the table's own dimension.
    static func load(_ table: GlobalTableRef) throws -> LUT3D {
        let data: Data
        do { data = try Data(contentsOf: table.fileURL) } catch {
            throw GlobalTableError.unreadable(path: table.relativePath, detail: error.localizedDescription)
        }
        try verify(data, against: table)
        return try decodeHalfFloatRGB(data, table: table)
    }

    /// The size check comes first so a truncated file reports as such rather than as a digest mismatch.
    static func verify(_ data: Data, against table: GlobalTableRef) throws {
        guard data.count == table.expectedByteCount else {
            throw GlobalTableError.unexpectedSize(path: table.relativePath, expectedBytes: table.expectedByteCount,
                                                  actualBytes: data.count)
        }
        let digest = PresetPackLoader.sha256Hex(data)
        guard digest == table.sha256 else {
            throw GlobalTableError.digestMismatch(path: table.relativePath, expected: table.sha256, actual: digest)
        }
    }

    private static func decodeHalfFloatRGB(_ data: Data, table: GlobalTableRef) throws -> LUT3D {
        let nodeCount = table.dimension * table.dimension * table.dimension
        var rgba = [Float](repeating: 1, count: nodeCount * LUT3D.channels)
        let firstNonFinite: Int? = data.withUnsafeBytes { raw in
            for node in 0..<nodeCount {
                for channel in 0..<3 {
                    let sourceIndex = node * 3 + channel
                    let bits = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: sourceIndex * 2, as: UInt16.self))
                    let value = Float(Float16(bitPattern: bits))
                    guard value.isFinite else { return sourceIndex }
                    rgba[node * LUT3D.channels + channel] = value
                }
            }
            return nil
        }
        if let firstNonFinite { throw GlobalTableError.nonFiniteValue(path: table.relativePath, index: firstNonFinite) }
        return try LUT3D(dimension: table.dimension, values: rgba)
    }

    /// The table at another grid size, by trilinear lookup of `lut` at each new node.
    ///
    /// v3 differs: a recipe look bakes every dimension directly from its recipe; a table only exists
    /// at 33³, so the coarser drag/preview LUTs (17³) are resampled from it. With 17³ every new node
    /// lands exactly on a 33³ node (32 / 16 = 2), so the resample is exact there.
    static func resample(_ lut: LUT3D, toDimension dimension: Int) -> LUT3D {
        guard dimension != lut.dimension else { return lut }
        let sourceRGB = rgbValues(of: lut)
        let step = 1 / Double(dimension - 1)
        return LUT3D.lut(dimension: dimension) { colour in
            let position = SIMD3<Double>(Double(colour.x), Double(colour.y), Double(colour.z))
            // `LUT3D.lut` hands over Float grid colours; recompute them in Double so the lookup lands on exact
            // source nodes instead of one rounding step beside them.
            let exact = (position / step).rounded(.toNearestOrEven) * step
            let value = TrilinearLookup.apply(rgb: sourceRGB, dimension: lut.dimension, to: exact)
            return SIMD3<Float>(Float(value.x), Float(value.y), Float(value.z))
        }
    }

    private static func rgbValues(of lut: LUT3D) -> [Float] {
        let nodeCount = lut.dimension * lut.dimension * lut.dimension
        var rgb = [Float](repeating: 0, count: nodeCount * 3)
        for node in 0..<nodeCount {
            for channel in 0..<3 { rgb[node * 3 + channel] = lut.values[node * LUT3D.channels + channel] }
        }
        return rgb
    }
}
