import Foundation

/// One committed edit covering every tool: EditState schema 3, edit recipe v1
/// (`shared/contracts/edit-recipe-v1.json`).
///
/// Preview and export evaluate the same committed recipe in rendering-v2 stage order, and the
/// editor's undo/redo store whole recipes. `source`, `auto`, `look` and `revision` are EditState
/// schema 2's keys with unchanged meaning; `tools` holds every other tool's state. Values are kept
/// in the contract's units (Lightroom-like sliders −100…100, percents 0…100, unit fractions).
struct EditRecipe: Equatable, Sendable {
    static let schema = 3
    static let recipeVersion = 1

    var source: Source
    var auto: Auto
    /// The Develop Look and its Amount (`strength` = Amount / 100). nil = no Look.
    var look: LookRef?
    var revision: Int64
    var tools: Tools

    // MARK: - Schema 2 parts (unchanged)

    struct Fingerprint: Equatable, Sendable {
        var headSha256: String
        var byteSize: Int64
        var pixelWidth: Int
        var pixelHeight: Int
    }

    struct Source: Equatable, Sendable {
        var assetId: String
        var fingerprint: Fingerprint
        /// EXIF orientation (1–8) of the Original as decoded.
        var orientation: Int
    }

    struct Auto: Equatable, Sendable {
        static let ia3dlutModelID = "ia3dlut"
        /// Auto was never applied because this build ships no model: a reason, not a version.
        static let noModelInBuildVersion = "no-model-in-build"

        var modelId: String
        var modelVersion: String
        var weights: [Double]
        /// nil or "endpoint-v1".
        var guardrail: String?
        var strength: Double

        /// The Auto block while no Auto model ships (dependency D1): zero weights, strength 0.
        static let noModelInBuild = Auto(modelId: ia3dlutModelID, modelVersion: noModelInBuildVersion,
                                         weights: [0, 0, 0], guardrail: nil, strength: 0)
    }

    struct LookRef: Equatable, Sendable {
        var lookId: String
        var lookVersion: String
        /// Amount / 100, in 0…1.
        var strength: Double
    }

    // MARK: - Shared references

    struct ModelRef: Equatable, Sendable { var id: String; var version: String }

    /// A cached on-device model result (matte, depth map, inpainted patch), stored by digest.
    struct DerivedRef: Equatable, Sendable {
        var sha256: String
        var model: ModelRef
        var width: Int
        var height: Int
    }

    enum AssetRef: Equatable, Sendable {
        case bundled(id: String)
        case photo(assetId: String, fingerprint: Fingerprint)
        case file(sha256: String)
    }

    /// [x, y] normalised, origin top-left.
    struct Point: Equatable, Sendable { var x: Double; var y: Double }

    /// [x, y, w, h] normalised.
    struct Rect: Equatable, Sendable { var x: Double; var y: Double; var width: Double; var height: Double }

    // MARK: - Tools

    struct Tools: Equatable, Sendable {
        var background: Background
        var portrait: Portrait
        var edit: Edit
        var effects: Effects
        var watermark: Watermark
        var border: Border
    }

    struct Background: Equatable, Sendable {
        var subject: Subject
        var replacement: Replacement?
        var focus: Focus
    }

    struct Subject: Equatable, Sendable {
        var matte: DerivedRef?
        var refinements: [RefineStroke]
    }

    struct RefineStroke: Equatable, Sendable {
        enum Mode: String, Sendable, CaseIterable { case add, erase }
        var mode: Mode
        var radius: Double
        var points: [Point]
    }

    enum Replacement: Equatable, Sendable {
        case image(AssetRef, x: Double, y: Double, scale: Double)
        case colour(String)
        case gradient(angle: Double, stops: [GradientStop])
    }

    struct GradientStop: Equatable, Sendable { var colour: String; var position: Double }

    struct Focus: Equatable, Sendable {
        enum Style: String, Sendable, CaseIterable { case lens, soft, swirl, motion }
        enum Bokeh: String, Sendable, CaseIterable { case round, hex, heart, star }
        var blur: Double
        var depthOfField: Double
        var style: Style
        var bokeh: Bokeh
        var styleAmount: Double
        var target: Point?
        var depth: Depth
    }

    struct Depth: Equatable, Sendable {
        enum Source: String, Sendable, CaseIterable {
            case embedded, estimated
            case subjectMatte = "subject-matte"
        }
        var source: Source
        var map: DerivedRef?
        var focusDepth: Double?
        var replacementDepth: Double
    }

    struct Portrait: Equatable, Sendable { var faces: [FaceEdit] }

    struct FaceEdit: Equatable, Sendable {
        struct Identity: Equatable, Sendable { var box: Rect; var detector: ModelRef }
        struct Skin: Equatable, Sendable { var smoothing, blemishes, evenTone, keepTexture: Double }
        struct UnderEye: Equatable, Sendable { var brighten, softenLines: Double }
        struct Eyes: Equatable, Sendable { var brighten, clarity: Double }
        struct Teeth: Equatable, Sendable { var brighten: Double }
        struct Hair: Equatable, Sendable { var definition, flyaways, shine: Double }
        var face: Identity
        var skin: Skin
        var underEye: UnderEye
        var eyes: Eyes
        var teeth: Teeth
        var hair: Hair
    }

    struct Edit: Equatable, Sendable {
        var geometry: Geometry
        var adjust: Adjust
        var remove: Remove
    }

    struct Geometry: Equatable, Sendable {
        enum Aspect: String, Sendable, CaseIterable {
            case original, free
            case square = "1:1", fourFive = "4:5", threeTwo = "3:2", sixteenNine = "16:9", nineSixteen = "9:16"
        }
        var quarterTurns: Int
        var flipHorizontal: Bool
        var flipVertical: Bool
        var perspectiveVertical: Double
        var perspectiveHorizontal: Double
        var straighten: Double
        var cropAspect: Aspect
        var cropRect: Rect
    }

    struct Adjust: Equatable, Sendable {
        var exposure, contrast, highlights, shadows, temp, tint, saturation, vibrance: Double
        var sharpness, clarity, noise: Double
    }

    struct Remove: Equatable, Sendable { var strokes: [RemoveStroke] }

    struct RemoveStroke: Equatable, Sendable {
        enum Status: String, Sendable, CaseIterable { case applied, failed, unavailable }
        var radius: Double
        var points: [Point]
        var status: Status
        var patch: DerivedRef?
    }

    struct Effects: Equatable, Sendable {
        struct LightLeak: Equatable, Sendable {
            enum Style: String, Sendable, CaseIterable { case warm, amber, rose, prism }
            var enabled: Bool
            var style: Style
            var intensity, x, y, rotation: Double
        }
        struct Grain: Equatable, Sendable {
            enum Style: String, Sendable, CaseIterable { case fine, film, coarse }
            var enabled: Bool
            var style: Style
            var amount, size, roughness: Double
            var seed: UInt32
        }
        struct Vignette: Equatable, Sendable {
            var enabled: Bool
            var amount, size, softness: Double
        }
        /// Effects › Selective Colour (rendering-v2 revision 4). No colours: no effect (there is no On switch).
        struct SelectiveColour: Equatable, Sendable {
            /// A kept colour: OKLab sampled from the effects stage input when it was picked, and where it was
            /// picked, as fractions of the source photo (for the interface; the render reads only `oklab`).
            struct Kept: Equatable, Sendable {
                var oklab: SIMD3<Double>
                var x, y: Double
            }
            var colours: [Kept]
            var range: Double
            var strength: Double
            static let none = SelectiveColour(colours: [], range: 40, strength: 100)
        }
        var lightLeak: LightLeak
        var grain: Grain
        var vignette: Vignette
        var selectiveColour: SelectiveColour = .none
    }

    struct Watermark: Equatable, Sendable {
        enum Kind: String, Sendable, CaseIterable { case none, signature, text, logo }
        enum Placement: String, Sendable, CaseIterable { case photo, border, canvas }
        enum Font: String, Sendable, CaseIterable {
            case allura = "Allura", cormorantGaramond = "Cormorant Garamond", inter = "Inter", caveat = "Caveat"
        }
        struct SignatureRef: Equatable, Sendable {
            enum Kind: String, Sendable, CaseIterable { case drawn, imported }
            var signatureId: String
            var signatureVersion: String
            var kind: Kind
        }
        struct Text: Equatable, Sendable { var text: String; var font: Font }
        var type: Kind
        var signature: SignatureRef?
        var text: Text?
        var logo: AssetRef?
        var placement: Placement
        var position: Int
        var offset: Point?
        var size: Double
        var opacity: Double
        var colour: String
    }

    struct Border: Equatable, Sendable {
        enum Kind: String, Sendable, CaseIterable { case none, solid, frame, polaroid, paper }
        var type: Kind
        var colour: String
        var width: Double
        var spacing: Double
        var mat: String
        enum PaperFinish: String, Sendable, CaseIterable { case clean, deckled, torn }
        var paperFinish: PaperFinish = .deckled
        var texture: Double = 25
    }
}

// MARK: - Neutral recipe

extension EditRecipe {

    /// The neutral recipe for a newly opened photo: no Auto (none ships), no Look, every tool at
    /// the approved prototype's `newSession` defaults. `grainSeed` is fixed here, when the edit is
    /// created, so every render of this edit has the same grain.
    static func neutral(source: Source, auto: Auto = .noModelInBuild, grainSeed: UInt32) -> EditRecipe {
        EditRecipe(source: source, auto: auto, look: nil, revision: 0, tools: .neutral(grainSeed: grainSeed))
    }

    /// The neutral grain seed for a migrated edit: the first 32 bits of `headSha256`.
    static func grainSeed(fromHeadSha256 digest: String) -> UInt32 {
        UInt32(digest.prefix(8), radix: 16) ?? 0
    }
}

extension EditRecipe.Tools {
    static func neutral(grainSeed: UInt32) -> EditRecipe.Tools {
        EditRecipe.Tools(
            background: .init(
                subject: .init(matte: nil, refinements: []),
                replacement: nil,
                focus: .init(blur: 0, depthOfField: 40, style: .lens, bokeh: .round, styleAmount: 50, target: nil,
                             depth: .init(source: .subjectMatte, map: nil, focusDepth: nil, replacementDepth: 1))),
            portrait: .init(faces: []),
            edit: .init(
                geometry: .init(quarterTurns: 0, flipHorizontal: false, flipVertical: false, perspectiveVertical: 0,
                                perspectiveHorizontal: 0, straighten: 0, cropAspect: .original,
                                cropRect: .init(x: 0, y: 0, width: 1, height: 1)),
                adjust: .init(exposure: 0, contrast: 0, highlights: 0, shadows: 0, temp: 0, tint: 0, saturation: 0,
                              vibrance: 0, sharpness: 0, clarity: 0, noise: 0),
                remove: .init(strokes: [])),
            effects: .init(
                lightLeak: .init(enabled: false, style: .warm, intensity: 55, x: 18, y: 14, rotation: 0),
                grain: .init(enabled: false, style: .film, amount: 30, size: 40, roughness: 50, seed: grainSeed),
                vignette: .init(enabled: false, amount: 35, size: 60, softness: 60)),
            watermark: .init(type: .none, signature: nil, text: nil, logo: nil, placement: .photo, position: 8,
                             offset: nil, size: 34, opacity: 85, colour: "#FFFFFF"),
            border: .init(type: .none, colour: "#FFFFFF", width: 4, spacing: 3, mat: "#F4F1EC"))
    }
}
