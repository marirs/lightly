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
        /// Owner amendment 2026-10-11: the Text tool (rendering-v2 §7.4, stage 11). Optional on read (missing = no
        /// layers), always written.
        var text: TextTool = .none
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
        /// Owner amendment 2026-10-11 (rendering-v2 §7.3 `portrait.smile`): −100…100, 0 = the photo as taken.
        struct Smile: Equatable, Sendable {
            var amount: Double
            static let neutral = Smile(amount: 0)
        }
        /// Portrait › Sunglasses (rendering-v2 §7.5, owner-approved design portrait-sunglasses-v2, 2026-10-13).
        struct Sunglasses: Equatable, Sendable {
            enum Lens: String, Sendable, CaseIterable { case dark, brown, green, gradient, mirror }
            /// The face's own glasses painted out (a LaMa patch, stored like a Remove stroke's). Kept when the person
            /// picks None so choosing a pair again does not recompute it; rendered only while a pair is chosen.
            struct Removed: Equatable, Sendable { var rect: Rect; var patch: DerivedRef }
            /// A sunglasses-pack id ("sun-" + 12 hex); nil is None.
            var pair: String?
            var lens: Lens
            var darkness: Double
            /// −50…50: fine-tunes the automatic fit.
            var size: Double
            var removed: Removed?
            static let none = Sunglasses(pair: nil, lens: .dark, darkness: 75, size: 0, removed: nil)
        }
        var face: Identity
        var skin: Skin
        var underEye: UnderEye
        var eyes: Eyes
        var teeth: Teeth
        var hair: Hair
        /// Optional on read (missing = amount 0), always written; declared last so existing call sites that build a
        /// face edit without it keep compiling and mean "no smile change".
        var smile: Smile = .neutral
        /// Optional on read and on write (missing = no sunglasses): written once the face has had a pair, so faces
        /// that never used Sunglasses keep their earlier bytes.
        var sunglasses: Sunglasses? = nil
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
            /// `effects.lightLeak.style` (edit-recipe-v1, rendering-v2 revision 8): one of the four drawn styles, kept so
            /// earlier edits still render though the panel no longer offers them, or `leak-<12 hex>`, an image of the
            /// light-leak pack (owner, 2026-10-11). A struct, not an enum, because leak ids are open-ended: the pack can
            /// grow without a recipe change, and a recipe naming a leak this build lacks must still decode.
            struct Style: RawRepresentable, Hashable, Sendable {
                enum Drawn: String, Sendable, CaseIterable { case warm, amber, rose, prism }

                let rawValue: String

                init?(rawValue: String) {
                    guard Drawn(rawValue: rawValue) != nil || Self.isLeakImageID(rawValue) else { return nil }
                    self.rawValue = rawValue
                }

                init(drawn: Drawn) { rawValue = drawn.rawValue }

                static let warm = Style(drawn: .warm), amber = Style(drawn: .amber)
                static let rose = Style(drawn: .rose), prism = Style(drawn: .prism)

                /// A leak-pack image, by its id; nil for a malformed id.
                static func leakImage(_ id: String) -> Style? { isLeakImageID(id) ? Style(rawValue: id) : nil }

                /// The drawn style, or nil when the style names a leak image.
                var drawn: Drawn? { Drawn(rawValue: rawValue) }
                /// The leak-pack image id, or nil for a drawn style.
                var leakImageID: String? { drawn == nil ? rawValue : nil }

                /// The schema's pattern `^leak-[0-9a-f]{12}$`.
                static func isLeakImageID(_ value: String) -> Bool {
                    guard value.hasPrefix("leak-") else { return false }
                    let hex = value.dropFirst(5)
                    return hex.count == 12 && hex.allSatisfy { "0123456789abcdef".contains($0) }
                }
            }
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
            case allura = "Allura", cormorantGaramond = "Cormorant Garamond", inter = "Inter", caveat = "Caveat", dancingScript = "Dancing Script", lora = "Lora"
            // Owner amendment 2026-10-11 (second): seven signature scripts after Lora, in the mockup's `WM_FONTS` order.
            case carpenters = "Carpenters", sourdoughScript = "Sourdough Script", jaybird = "Jaybird", astoria = "Astoria"
            case bonskin = "Bonskin", shareit = "Shareit", monttee = "Monttee"
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

    /// The Text tool (owner amendment 2026-10-11): any number of text layers drawn in order, the last on top.
    struct TextTool: Equatable, Sendable {
        /// `edit-recipe-v1.json` `text.layers.maxItems`.
        static let maximumLayers = 20
        var layers: [TextLayer]
        static let none = TextTool(layers: [])
    }

    /// One text layer (`textLayer`): every quantity is a fraction of the photo frame, so preview and export agree.
    struct TextLayer: Equatable, Sendable, Identifiable {
        /// The eleven approved fonts (shared/fonts), by the family name the recipe stores. The last three were added by the
        /// owner on 2026-10-11 (second amendment), after Space Mono.
        enum Font: String, Sendable, CaseIterable {
            case inter = "Inter", playfairDisplay = "Playfair Display", bebasNeue = "Bebas Neue", caveat = "Caveat"
            case cormorantGaramond = "Cormorant Garamond", montserrat = "Montserrat", dancingScript = "Dancing Script"
            case spaceMono = "Space Mono"
            case retroRomance = "Retro Romance", velomino = "Velomino", vectipedeThin = "Vectipede Thin"

            /// Fonts drawn in one weight only (`textLayer.weight`: they only take regular); the panel greys Thin and Bold.
            var hasSingleWeight: Bool {
                switch self {
                case .bebasNeue, .spaceMono, .retroRomance, .velomino, .vectipedeThin: true
                case .inter, .playfairDisplay, .caveat, .cormorantGaramond, .montserrat, .dancingScript: false
                }
            }
        }
        /// `textLayer.weight` (owner amendment 2026-10-11, second): Thin 200, Regular 400, Bold 700 on the font's weight axis.
        enum Weight: String, Sendable, CaseIterable {
            case thin, regular, bold
            /// The OpenType `wght` value (rendering-v2 §7.4).
            var axisValue: Double {
                switch self {
                case .thin: 200
                case .regular: 400
                case .bold: 700
                }
            }
        }
        static let sizeRange: ClosedRange<Double> = 10...100
        static let maximumTextLength = 120
        /// Eight lowercase hex digits, stable for the layer's life, so its selection survives Undo.
        var id: String
        /// One or more lines separated by "\n"; never blank.
        var text: String
        var font: Font
        /// Optional in the recipe (missing reads as regular); always written.
        var weight: Weight = .regular
        /// 10…100: font size = size / 100 × 0.25 × the frame's short edge.
        var size: Double
        var colour: String
        var opacity: Double
        /// Centre of the text block, as fractions of the frame (after crop, before border).
        var centre: Point
        /// Degrees clockwise about the centre, −180…180.
        var rotation: Double
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
