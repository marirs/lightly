import CoreGraphics
import CoreImage
import Foundation
import OSLog

/// Auto on iOS 1.0 (owner approval 2026-10-06): Apple Core Image auto enhancement, `CIImage.autoAdjustmentFilters`.
/// It is neither the Apple Photos algorithm nor a model we trained, and the app never says otherwise.
///
/// - Composition is never changed: `.crop` and `.level` (straightening) are off; red-eye correction is off.
/// - The per-pixel proposals (face balance, vibrance, tone curve) pass the image-dependent guards in
///   `CoreImageAutoGuards` and are baked into the Auto LUT at stage 1 of the existing pipeline: the same LUT for preview
///   and Save copy, on the original's pixels, with no tile boundaries (nothing is enhanced twice).
/// - **Not applied: CIHighlightShadowAdjust** (recorded in `omitted`). It is local, not per-pixel: through a LUT its
///   shadows differ from the filter by up to 18–20/255 at 1600 px (experiments/auto-ci/lut_worst.swift; an earlier
///   800 px check showing 2/255 was misleading). Auto is therefore the reduced Core Image set, not the complete
///   enhancement; supporting it would need a spatial stage whose preview and export agree.
/// - The correction is the filters and their parameters. The session stores them (`json`), and a restored session
///   rebuilds the LUT from them (`lut()`) without analysing the photo again.
struct CoreImageAutoCorrection: Equatable, Sendable {
    struct Parameter: Equatable, Sendable {
        var isVector: Bool
        var values: [Double]
    }
    struct Filter: Equatable, Sendable {
        var name: String
        var parameters: [String: Parameter]
    }

    static let engine = "CIImage.autoAdjustmentFilters"
    /// Recipe `auto.modelId` / `modelVersion` for this correction (the recipe's three weights are unused: zeros).
    static let recipeModelID = "coreimage-auto"
    static let recipeModelVersion = "1"
    static let appliedFilterNames: Set<String> = ["CIFaceBalance", "CIVibrance", "CIToneCurve"]

    var filters: [Filter]
    /// Proposed by Core Image but not applied (a guard removed it, or it is not per-pixel).
    var omitted: [String]
    /// The guards' measurements and decisions, kept with the correction for review.
    var notes: [String] = []

    // MARK: Analysis

    static func analyse(_ image: CGImage) -> CoreImageAutoCorrection {
        let options: [CIImageAutoAdjustmentOption: Any] = [.enhance: true, .redEye: false, .crop: false, .level: false]
        var proposed = CIImage(cgImage: image).autoAdjustmentFilters(options: options)
        var omitted: [String] = []
        proposed.removeAll { filter in
            let drop = !appliedFilterNames.contains(filter.name)
            if drop { omitted.append(filter.name == "CIHighlightShadowAdjust" ? "CIHighlightShadowAdjust (local: not applied)" : filter.name) }
            return drop
        }
        let guarded = CoreImageAutoGuards.guarded(proposed, proxy: image)
        omitted += proposed.map(\.name).filter { name in !guarded.filters.contains { $0.name == name } }
        var filters: [Filter] = []
        for filter in guarded.filters {
            var parameters: [String: Parameter] = [:]
            for key in filter.inputKeys where key != kCIInputImageKey {
                if let number = filter.value(forKey: key) as? NSNumber {
                    parameters[key] = Parameter(isVector: false, values: [number.doubleValue])
                } else if let vector = filter.value(forKey: key) as? CIVector {
                    parameters[key] = Parameter(isVector: true, values: (0..<vector.count).map { Double(vector.value(at: $0)) })
                }
            }
            filters.append(Filter(name: filter.name, parameters: parameters))
        }
        var correction = CoreImageAutoCorrection(filters: filters, omitted: omitted)
        correction.notes = guarded.notes
        return correction
    }

    // MARK: LUT

    /// The applied filters evaluated on every grid colour (sRGB-encoded in and out, the contract's LUT domain).
    func lut(dimension: Int = LUT3D.contractDimension) -> LUT3D? {
        let n = dimension
        var lattice = [Float](repeating: 1, count: n * n * n * 4)
        let step = 1 / Float(n - 1)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let i = (r + n * g + n * n * b) * 4
            lattice[i] = Float(r) * step; lattice[i + 1] = Float(g) * step; lattice[i + 2] = Float(b) * step
        } } }
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = n * n, height = n
        var image = CIImage(bitmapData: lattice.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: sRGB)
        for filter in filters {
            guard let ci = CIFilter(name: filter.name) else { return nil }
            ci.setValue(image, forKey: kCIInputImageKey)
            for (key, parameter) in filter.parameters {
                if parameter.isVector {
                    ci.setValue(CIVector(values: parameter.values.map { CGFloat($0) }, count: parameter.values.count), forKey: key)
                } else {
                    ci.setValue(NSNumber(value: parameter.values.first ?? 0), forKey: key)
                }
            }
            guard let output = ci.outputImage else { return nil }
            image = output
        }
        var out = [Float](repeating: 0, count: n * n * n * 4)
        let context = CIContext(options: [.cacheIntermediates: false])
        out.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: sRGB)
        }
        // Core Image reads `bitmapData` and writes `toBitmap` in the same row order, so rows map straight back
        // (CoreImageAutoTests checks the identity bake).
        var values = out
        for i in stride(from: 3, to: values.count, by: 4) { values[i] = 1 }
        return try? LUT3D(dimension: n, values: values)
    }

    // MARK: Storage

    var json: [String: Any] {
        ["engine": Self.engine, "omitted": omitted, "notes": notes,
         "filters": filters.map { f in
             ["name": f.name, "parameters": f.parameters.mapValues { ["vector": $0.isVector, "values": $0.values] as [String: Any] }] as [String: Any]
         }]
    }

    init(filters: [Filter], omitted: [String]) {
        self.filters = filters
        self.omitted = omitted
    }

    init?(json object: Any?) {
        guard let o = object as? [String: Any], o["engine"] as? String == Self.engine, let list = o["filters"] as? [[String: Any]] else { return nil }
        var filters: [Filter] = []
        for item in list {
            guard let name = item["name"] as? String, Self.appliedFilterNames.contains(name),
                  let raw = item["parameters"] as? [String: [String: Any]] else { return nil }
            var parameters: [String: Parameter] = [:]
            for (key, value) in raw {
                guard let isVector = value["vector"] as? Bool, let values = value["values"] as? [Double] else { return nil }
                parameters[key] = Parameter(isVector: isVector, values: values)
            }
            filters.append(Filter(name: name, parameters: parameters))
        }
        self.init(filters: filters, omitted: o["omitted"] as? [String] ?? [])
        notes = o["notes"] as? [String] ?? []
    }
}

/// The iOS Auto enhancer: Core Image auto enhancement on the analysis proxy.
struct CoreImageAutoEnhancer: AutoEnhancing {
    private static let log = Logger(subsystem: "com.lightlylabs.lightly", category: "Auto")

    func autoLUT(forAnalysisProxy proxy: CGImage) async -> AutoResult {
        await Task.detached(priority: .userInitiated) {
            let correction = CoreImageAutoCorrection.analyse(proxy)
            Self.log.notice("Core Image auto: applied \(correction.filters.map(\.name), privacy: .public), omitted \(correction.omitted, privacy: .public)")
            guard let lut = correction.lut() else { return .unavailable(.analysisFailed) }
            return .coreImage(correction, lut)
        }.value
    }
}
