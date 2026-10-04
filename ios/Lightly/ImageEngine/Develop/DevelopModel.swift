import CryptoKit
import Foundation

/// The calibrated Develop model of rendering contract v2 (`shared/contracts/rendering-v2.json`,
/// `developModel`): its identity and every constant the global, spatial and finishing operators
/// use.
///
/// The constants are read from the contract file itself, which the build bundles verbatim, so the
/// app can never drift from the numbers the pack's `lookVersion`s were computed with. On load the
/// published `constantsSha256` is checked against the constants actually read (the generator's
/// definition: sha256 of `{constants, curveMethod, spatialConstants, experimentalConstants,
/// provisionalConstants}` in Python's canonical JSON), and the pack loader refuses a pack built against other constants.
struct DevelopModel: Sendable, Equatable {

    let id: String
    let version: Int
    let constantsSha256: String

    // Global stage (developModel.constants).
    let kTemp, kTint, kContrast, kHighlights, kShadows, kWhites, kBlacks: Double
    let centreHighlights, centreShadows, widthHighlights, widthShadows: Double
    let kDehaze, dehazeAir, kParametric: Double
    let kHue, kHSLSaturation, kHSLLuminance, kSaturation, kVibrance: Double
    let kCalibrationHue, kCalibrationSaturation, kShadowTint, kGrade, kGradeLuminance: Double
    let calibrationHue: [Double]          // 3
    let calibrationSaturation: [Double]   // 3
    let hueBand, saturationBand, luminanceBand: [Double]  // 8 each
    let gradeZone: [Double]               // 4
    /// Learned tone response tables, rows contrast, highlights, shadows, whites, blacks, dehaze.
    let toneA, toneB: [[Double]]          // 6 × 12

    // Spatial stage (developModel.spatialConstants): calibrated, not validated.
    let kClarity, radiusClarity, kTexture, radiusTexture: Double

    // Finishing (developModel.experimentalConstants): uncalibrated.
    let vignetteK, grainK, grainReferenceLongEdge: Double

    // Provisional Lightly operators (developModel.provisionalConstants).
    let referenceLongEdgePx, kSharpen, sharpenDetailThreshold, sharpenEdgeScale: Double
    let noiseLumaRadiusPx, noiseDetailScale, noiseColourRadiusPx: Double

    enum LoadError: Error, Equatable {
        case missingContract
        case unreadable(String)
        case constantsDigestMismatch(published: String, computed: String)
        /// The bundled contract is not the revision this build was ported to.
        case unsupportedRevision(found: Int64?)
        /// background.focus constants differ from the ones RefocusRenderer implements.
        case focusConstantsMismatch(String)
    }

    /// Rendering contract v2 revision this build implements (contract fixes 2).
    static let requiredContractRevision: Int64 = 2

    /// The contract bundled with the app (`rendering-v2.json`, copied verbatim by project.yml).
    static func loadBundled(from bundle: Bundle = .main) throws -> DevelopModel {
        guard let url = bundle.url(forResource: "rendering-v2", withExtension: "json") else { throw LoadError.missingContract }
        return try load(contractData: Data(contentsOf: url))
    }

    static func load(contractData: Data) throws -> DevelopModel {
        let contract: CanonicalJSON
        do { contract = try CanonicalJSON.parse(contractData) } catch { throw LoadError.unreadable("\(error)") }
        guard let model = contract["developModel"] else { throw LoadError.unreadable("no developModel") }
        try checkRevisionAndFocusConstants(contract)
        return try DevelopModel(json: model)
    }

    // swiftlint:disable:next function_body_length
    init(json model: CanonicalJSON) throws {
        func fail(_ what: String) -> LoadError { .unreadable(what) }
        guard let id = model["id"]?.stringValue, let version = model["version"]?.integerLiteralValue,
              let published = model["constantsSha256"]?.stringValue,
              let constants = model["constants"], let curveMethod = model["curveMethod"],
              let spatial = model["spatialConstants"], let experimental = model["experimentalConstants"],
              let provisional = model["provisionalConstants"] else { throw fail("developModel fields") }

        // build_rendering_v2.develop_model(): sha256 of the sorted, compact JSON of these five members.
        let body = CanonicalJSON.object([
            ("constants", constants), ("curveMethod", curveMethod), ("spatialConstants", spatial),
            ("experimentalConstants", experimental), ("provisionalConstants", provisional)
        ])
        let computed = SHA256.hash(data: body.serialized(keys: .sorted)).map { String(format: "%02x", $0) }.joined()
        guard computed == published else { throw LoadError.constantsDigestMismatch(published: published, computed: computed) }

        func scalar(_ object: CanonicalJSON, _ key: String) throws -> Double {
            guard let value = object[key]?.doubleValue else { throw fail(key) }
            return value
        }
        func vector(_ key: String, count: Int) throws -> [Double] {
            guard let items = constants[key]?.arrayValue, items.count == count else { throw fail(key) }
            return try items.map { guard let v = $0.doubleValue else { throw fail(key) }; return v }
        }
        func table(_ key: String) throws -> [[Double]] {
            guard let rows = constants[key]?.arrayValue, rows.count == 6 else { throw fail(key) }
            return try rows.map { row in
                guard let items = row.arrayValue, items.count == 12 else { throw fail(key) }
                return try items.map { guard let v = $0.doubleValue else { throw fail(key) }; return v }
            }
        }

        self.id = id
        self.version = Int(version)
        self.constantsSha256 = published
        kTemp = try scalar(constants, "k_temp"); kTint = try scalar(constants, "k_tint")
        kContrast = try scalar(constants, "k_contrast"); kHighlights = try scalar(constants, "k_hi")
        kShadows = try scalar(constants, "k_sh"); kWhites = try scalar(constants, "k_wh"); kBlacks = try scalar(constants, "k_bl")
        centreHighlights = try scalar(constants, "c_hi"); centreShadows = try scalar(constants, "c_sh")
        widthHighlights = try scalar(constants, "w_hi"); widthShadows = try scalar(constants, "w_sh")
        kDehaze = try scalar(constants, "k_dehaze"); dehazeAir = try scalar(constants, "dehaze_air")
        kParametric = try scalar(constants, "k_param")
        kHue = try scalar(constants, "k_hue"); kHSLSaturation = try scalar(constants, "k_hsl_sat")
        kHSLLuminance = try scalar(constants, "k_hsl_lum"); kSaturation = try scalar(constants, "k_sat")
        kVibrance = try scalar(constants, "k_vib")
        kCalibrationHue = try scalar(constants, "k_cal_hue"); kCalibrationSaturation = try scalar(constants, "k_cal_sat")
        kShadowTint = try scalar(constants, "k_shadow_tint")
        kGrade = try scalar(constants, "k_grade"); kGradeLuminance = try scalar(constants, "k_grade_lum")
        calibrationHue = try vector("cal_hue", count: 3); calibrationSaturation = try vector("cal_sat", count: 3)
        hueBand = try vector("hue_band", count: 8); saturationBand = try vector("sat_band", count: 8)
        luminanceBand = try vector("lum_band", count: 8)
        gradeZone = try vector("grade_zone", count: 4)
        toneA = try table("tone_A"); toneB = try table("tone_B")

        kClarity = try scalar(spatial, "k_clarity"); radiusClarity = try scalar(spatial, "r_clarity")
        kTexture = try scalar(spatial, "k_texture"); radiusTexture = try scalar(spatial, "r_texture")

        vignetteK = try scalar(experimental, "VIGNETTE_K"); grainK = try scalar(experimental, "GRAIN_K")
        grainReferenceLongEdge = try scalar(experimental, "GRAIN_REF_LONG")

        referenceLongEdgePx = try scalar(provisional, "referenceLongEdgePx"); kSharpen = try scalar(provisional, "k_sharpen")
        sharpenDetailThreshold = try scalar(provisional, "sharpenDetailThreshold")
        sharpenEdgeScale = try scalar(provisional, "sharpenEdgeScale")
        noiseLumaRadiusPx = try scalar(provisional, "nrLumaRadiusPx"); noiseDetailScale = try scalar(provisional, "nrDetailScale")
        noiseColourRadiusPx = try scalar(provisional, "nrColourRadiusPx")
    }
}

extension DevelopModel {
    /// Revision 1 moved `maxBlurRadius` from the focus operator's params to its constants and
    /// changed the focus constants; RefocusRenderer hard-codes them, so a contract that disagrees
    /// is refused rather than rendered with stale numbers.
    static func checkRevisionAndFocusConstants(_ contract: CanonicalJSON) throws {
        let revision = contract["revision"]?.integerLiteralValue
        guard revision == requiredContractRevision else { throw LoadError.unsupportedRevision(found: revision) }
        guard let stage = contract["stages"]?.arrayValue?.first(where: { $0["id"]?.stringValue == "background.focus" }),
              let constants = stage["operators"]?.arrayValue?.first?["constants"] else {
            throw LoadError.focusConstantsMismatch("background.focus constants missing")
        }
        let expected: [(String, Double)] = [
            ("maxBlurRadius", Double(RefocusRenderer.maxCoCFractionOfLongSide)),
            ("focusHalfWidthPerUnit", Double(RefocusRenderer.focusHalfWidthPerUnit))
        ]
        for (key, value) in expected {
            guard let found = constants[key]?["value"]?.doubleValue, abs(found - value) < 1e-6 else {
                throw LoadError.focusConstantsMismatch(key)
            }
        }
    }
}
