import CoreGraphics
import CryptoKit
import Foundation

/// A drawn signature, kept as vector strokes (approved "Draw signature").
///
/// The strokes are polylines in the coordinate space of the pad they were drawn on. `viewBox` is
/// the box the watermark stage maps onto the watermark's height (as the prototype's `sigSvg` maps
/// its `viewBox="0 0 170 50"`), and `strokeWidth` is in the same units, so a signature keeps its
/// own look at every size.
struct DrawnSignature: Equatable, Sendable {
    struct Point: Equatable, Sendable { var x: Double; var y: Double }
    struct Box: Equatable, Sendable { var x: Double; var y: Double; var width: Double; var height: Double }

    var strokes: [[Point]]
    var viewBox: Box
    var strokeWidth: Double

    /// The prototype's drawn signature: stroke width 2.4 in a 50-unit-tall view box, i.e. 4.8 % of
    /// the watermark's height.
    static let strokeWidthPerHeight = 2.4 / 50

    /// Stored bytes: a canonical JSON text with fixed two-decimal numbers, so the same strokes
    /// always give the same bytes and therefore the same version digest.
    var canonicalData: Data {
        func n(_ v: Double) -> String { String(format: "%.2f", v) }
        let strokesText = strokes.map { stroke in "[" + stroke.map { "[\(n($0.x)),\(n($0.y))]" }.joined(separator: ",") + "]" }
        let text = "{\"format\":1,\"strokeWidth\":\(n(strokeWidth)),\"strokes\":[\(strokesText.joined(separator: ","))],"
            + "\"viewBox\":[\(n(viewBox.x)),\(n(viewBox.y)),\(n(viewBox.width)),\(n(viewBox.height))]}"
        return Data(text.utf8)
    }

    /// Reads the canonical JSON written by `canonicalData`. nil for anything else.
    init?(canonicalData data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? Int == 1,
              let width = (object["strokeWidth"] as? NSNumber)?.doubleValue,
              let box = object["viewBox"] as? [NSNumber], box.count == 4,
              let strokes = object["strokes"] as? [[[NSNumber]]] else { return nil }
        self.strokeWidth = width
        self.viewBox = Box(x: box[0].doubleValue, y: box[1].doubleValue, width: box[2].doubleValue, height: box[3].doubleValue)
        self.strokes = strokes.map { stroke in stroke.compactMap { $0.count == 2 ? Point(x: $0[0].doubleValue, y: $0[1].doubleValue) : nil } }
        guard viewBox.width > 0, viewBox.height > 0, !self.strokes.allSatisfy(\.isEmpty) else { return nil }
    }

    init(strokes: [[Point]], viewBox: Box, strokeWidth: Double) {
        self.strokes = strokes
        self.viewBox = viewBox
        self.strokeWidth = strokeWidth
    }

    /// A pad drawing as a signature: the view box is as tall as the pen width implies (so the
    /// signature keeps the prototype's stroke-to-height proportion, 2.4 : 50), centred on the
    /// ink, and at least as tall as the ink. nil when nothing was drawn.
    static func fromPad(strokes: [[Point]], penWidth: Double) -> DrawnSignature? {
        let points = strokes.flatMap { $0 }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        let inkHeight = maxY - minY + penWidth
        let height = max(penWidth / strokeWidthPerHeight, inkHeight)
        // The prototype's path starts 6 units in from the view box's left edge (of 50 tall).
        let margin = height * 6 / 50
        let centreY = (minY + maxY) / 2
        let box = Box(x: minX - margin, y: centreY - height / 2, width: maxX - minX + 2 * margin, height: height)
        return DrawnSignature(strokes: strokes.filter { !$0.isEmpty }, viewBox: box, strokeWidth: penWidth)
    }
}

extension DrawnSignature {
    /// The strokes mapped from the view box onto a rect `height` tall at `origin`, smoothed through
    /// the midpoints of the sampled points (quadratic segments), as one path to stroke with round
    /// caps and joins. The stroke width at that height is `strokeWidth × height / viewBox.height`.
    func path(origin: CGPoint, height: Double) -> CGPath {
        let scale = height / viewBox.height
        func map(_ p: Point) -> CGPoint {
            CGPoint(x: Double(origin.x) + (p.x - viewBox.x) * scale, y: Double(origin.y) + (p.y - viewBox.y) * scale)
        }
        let path = CGMutablePath()
        for stroke in strokes where !stroke.isEmpty {
            let points = stroke.map(map)
            path.move(to: points[0])
            guard points.count > 1 else { path.addLine(to: points[0]); continue }
            for i in 1..<(points.count - 1) {
                let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: points[i])
            }
            path.addLine(to: points[points.count - 1])
        }
        return path
    }

    func lineWidth(atHeight height: Double) -> Double { strokeWidth * height / viewBox.height }

    var aspectRatio: Double { viewBox.width / viewBox.height }

    /// The prototype's drawn signature (`SIG_DRAWN`, view box 170 × 50, stroke 2.4), flattened to
    /// points. Used by design captures and tests to reproduce the approved screens.
    static let prototypeSample: DrawnSignature = {
        let path = "M6 38c10-20 16-30 20-28 5 3-9 28-3 30 6 2 10-18 15-17 4 1-1 15 4 15 5 0 7-12 12-12 4 0 2 10 6 10 6 0 10-14 18-14 6 0 3 9 9 9 7 0 12-8 22-10"
        let numbers = path.dropFirst().replacingOccurrences(of: "c", with: " ").replacingOccurrences(of: "-", with: " -")
            .split(separator: " ").compactMap { Double($0) }
        var current = Point(x: numbers[0], y: numbers[1])
        var points = [current]
        var index = 2
        // Relative cubic segments ("c" repeated implicitly), 16 samples each.
        while index + 5 < numbers.count {
            let c1 = Point(x: current.x + numbers[index], y: current.y + numbers[index + 1])
            let c2 = Point(x: current.x + numbers[index + 2], y: current.y + numbers[index + 3])
            let end = Point(x: current.x + numbers[index + 4], y: current.y + numbers[index + 5])
            for step in 1...16 {
                let t = Double(step) / 16, u = 1 - t
                let x = u * u * u * current.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x
                let y = u * u * u * current.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y
                points.append(Point(x: x, y: y))
            }
            current = end
            index += 6
        }
        return DrawnSignature(strokes: [points], viewBox: Box(x: 0, y: 0, width: 170, height: 50), strokeWidth: 2.4)
    }()
}

/// The kinds of saved signature (edit recipe `signatureRef.kind`).
typealias SignatureKind = EditRecipe.Watermark.SignatureRef.Kind

/// One saved signature: its stable id, its kind and its stored bytes (canonical strokes for a
/// drawn one, a PNG with the paper removed for an imported one).
struct SavedSignature: Equatable, Sendable {
    let id: String
    let kind: SignatureKind
    let data: Data

    /// Edit recipe `signatureVersion`: the first 12 hex digits of the SHA-256 of the stored bytes.
    var version: String { Self.version(of: data) }

    static func version(of data: Data) -> String {
        String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    var reference: EditRecipe.Watermark.SignatureRef {
        .init(signatureId: id, signatureVersion: version, kind: kind)
    }

    var drawn: DrawnSignature? { kind == .drawn ? DrawnSignature(canonicalData: data) : nil }
}
