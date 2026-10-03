import Foundation

/// Why an edit recipe was refused. A refused document is never half-read.
struct EditRecipeDecodingError: Error, Equatable, CustomStringConvertible {
    let path: String
    let problem: String
    var description: String { "\(path.isEmpty ? "(root)" : path): \(problem)" }
}

/// Reads and writes EditState schema 3 (edit recipe v1).
///
/// Reading is strict: every key present, no unknown key, nothing outside its range clamped, plus
/// the reader rules beyond the schema (`shared/contracts/schema_check.py`). Schema 1 and 2 are
/// migrated (1 → 2 → 3); any other schema is rejected. Writing is canonical — keys in schema
/// order, no whitespace, integers without a decimal point — so encoding a decoded value
/// reproduces the shared fixtures byte for byte.
enum EditRecipeCodec {

    // MARK: - Decode

    static func decode(_ data: Data) throws -> EditRecipe {
        let root: CanonicalJSON
        do { root = try CanonicalJSON.parse(data) } catch {
            throw EditRecipeDecodingError(path: "", problem: "malformed JSON (\(error))")
        }
        let object = try Reader(root, path: "")
        guard let schemaValue = object.raw("schema")?.integerLiteralValue else {
            throw EditRecipeDecodingError(path: "schema", problem: "missing or not an integer")
        }
        switch schemaValue {
        case 3: return try readSchema3(object)
        case 2: return try migrate(readSchema2(object, legacyNumericLookVersion: false))
        case 1: return try migrate(readSchema2(object, legacyNumericLookVersion: true))
        default: throw EditRecipeDecodingError(path: "schema", problem: "unsupported schema \(schemaValue)")
        }
    }

    private struct Schema2State {
        var source: EditRecipe.Source
        var auto: EditRecipe.Auto
        var look: EditRecipe.LookRef?
        var revision: Int64
    }

    private static func readSchema3(_ r: Reader) throws -> EditRecipe {
        try r.requireExactly(["schema", "recipeVersion", "source", "auto", "look", "revision", "tools"])
        guard try r.integer("recipeVersion") == Int64(EditRecipe.recipeVersion) else {
            throw r.error("recipeVersion", "must be \(EditRecipe.recipeVersion)")
        }
        return EditRecipe(
            source: try readSource(r.object("source")),
            auto: try readAuto(r.object("auto")),
            look: try r.optionalObject("look").map(readLook),
            revision: try r.integer("revision", minimum: 0),
            tools: try readTools(r.object("tools")))
    }

    /// Schema 2 (and schema 1, whose `lookVersion` is an integer `n` → `"legacy-v1-<n>"`).
    private static func readSchema2(_ r: Reader, legacyNumericLookVersion: Bool) throws -> Schema2State {
        try r.requireExactly(["schema", "source", "auto", "look", "revision"])
        var look: EditRecipe.LookRef?
        if let lookReader = try r.optionalObject("look") {
            if legacyNumericLookVersion {
                try lookReader.requireExactly(["lookId", "lookVersion", "strength"])
                look = EditRecipe.LookRef(
                    lookId: try lookReader.string("lookId", nonEmpty: true),
                    lookVersion: "legacy-v1-\(try lookReader.integer("lookVersion", minimum: 0))",
                    strength: try lookReader.number("strength", 0...1))
            } else {
                look = try readLook(lookReader)
            }
        }
        return Schema2State(source: try readSource(r.object("source")), auto: try readAuto(r.object("auto")),
                            look: look, revision: try r.integer("revision", minimum: 0))
    }

    /// Schema 2 → 3: add `recipeVersion` and the neutral tools; the grain seed is the first 32 bits
    /// of `source.fingerprint.headSha256`. Nothing else is reinterpreted.
    private static func migrate(_ state: Schema2State) -> EditRecipe {
        EditRecipe(source: state.source, auto: state.auto, look: state.look, revision: state.revision,
                   tools: .neutral(grainSeed: EditRecipe.grainSeed(fromHeadSha256: state.source.fingerprint.headSha256)))
    }

    // MARK: Schema 2 parts

    private static func readFingerprint(_ r: Reader) throws -> EditRecipe.Fingerprint {
        try r.requireExactly(["headSha256", "byteSize", "pixelWidth", "pixelHeight"])
        return EditRecipe.Fingerprint(
            headSha256: try r.sha256("headSha256"), byteSize: try r.integer("byteSize", minimum: 0),
            pixelWidth: Int(try r.integer("pixelWidth", minimum: 1)), pixelHeight: Int(try r.integer("pixelHeight", minimum: 1)))
    }

    private static func readSource(_ r: Reader) throws -> EditRecipe.Source {
        try r.requireExactly(["assetId", "fingerprint", "orientation"])
        let orientation = try r.integer("orientation", minimum: 1)
        guard orientation <= 8 else { throw r.error("orientation", "must be 1…8") }
        return EditRecipe.Source(assetId: try r.string("assetId", nonEmpty: true),
                                 fingerprint: try readFingerprint(r.object("fingerprint")), orientation: Int(orientation))
    }

    private static func readAuto(_ r: Reader) throws -> EditRecipe.Auto {
        try r.requireExactly(["modelId", "modelVersion", "weights", "guardrail", "strength"])
        let weights = try r.array("weights").enumerated().map { index, item -> Double in
            guard let value = item.doubleValue, value.isFinite else { throw r.error("weights[\(index)]", "not a number") }
            return value
        }
        guard weights.count == 3 else { throw r.error("weights", "needs 3 numbers") }
        var guardrail: String?
        if let value = r.raw("guardrail"), !value.isNull {
            guard value.stringValue == "endpoint-v1" else { throw r.error("guardrail", "must be null or endpoint-v1") }
            guardrail = "endpoint-v1"
        }
        return EditRecipe.Auto(modelId: try r.string("modelId", nonEmpty: true), modelVersion: try r.string("modelVersion", nonEmpty: true),
                               weights: weights, guardrail: guardrail, strength: try r.number("strength", 0...1))
    }

    private static func readLook(_ r: Reader) throws -> EditRecipe.LookRef {
        try r.requireExactly(["lookId", "lookVersion", "strength"])
        return EditRecipe.LookRef(lookId: try r.string("lookId", nonEmpty: true),
                                  lookVersion: try r.string("lookVersion", nonEmpty: true),
                                  strength: try r.number("strength", 0...1))
    }

    // MARK: Shared parts

    private static func readModelRef(_ r: Reader) throws -> EditRecipe.ModelRef {
        try r.requireExactly(["id", "version"])
        return EditRecipe.ModelRef(id: try r.string("id", nonEmpty: true), version: try r.string("version", nonEmpty: true))
    }

    private static func readDerived(_ r: Reader) throws -> EditRecipe.DerivedRef {
        try r.requireExactly(["sha256", "model", "width", "height"])
        return EditRecipe.DerivedRef(sha256: try r.sha256("sha256"), model: try readModelRef(r.object("model")),
                                     width: Int(try r.integer("width", minimum: 1)), height: Int(try r.integer("height", minimum: 1)))
    }

    private static func readAsset(_ r: Reader) throws -> EditRecipe.AssetRef {
        switch try r.string("kind") {
        case "bundled":
            try r.requireExactly(["kind", "id"])
            return .bundled(id: try r.string("id", nonEmpty: true))
        case "photo":
            try r.requireExactly(["kind", "assetId", "fingerprint"])
            return .photo(assetId: try r.string("assetId", nonEmpty: true), fingerprint: try readFingerprint(r.object("fingerprint")))
        case "file":
            try r.requireExactly(["kind", "sha256"])
            return .file(sha256: try r.sha256("sha256"))
        default:
            throw r.error("kind", "unknown asset kind")
        }
    }

    private static func readPoint(_ value: CanonicalJSON, _ path: String) throws -> EditRecipe.Point {
        let numbers = try unitNumbers(value, count: 2, path)
        return EditRecipe.Point(x: numbers[0], y: numbers[1])
    }

    /// x + w ≤ 1 and y + h ≤ 1: the rectangle lies inside the frame (reader rule).
    private static func readRect(_ value: CanonicalJSON, _ path: String) throws -> EditRecipe.Rect {
        let n = try unitNumbers(value, count: 4, path)
        guard n[0] + n[2] <= 1 + 1e-9, n[1] + n[3] <= 1 + 1e-9 else {
            throw EditRecipeDecodingError(path: path, problem: "rectangle leaves the frame")
        }
        return EditRecipe.Rect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    private static func unitNumbers(_ value: CanonicalJSON, count: Int, _ path: String) throws -> [Double] {
        guard let items = value.arrayValue, items.count == count else {
            throw EditRecipeDecodingError(path: path, problem: "needs \(count) numbers")
        }
        return try items.map { item in
            guard let number = item.doubleValue, (0...1).contains(number) else {
                throw EditRecipeDecodingError(path: path, problem: "values must be within 0…1")
            }
            return number
        }
    }

    // MARK: Tools

    private static func readTools(_ r: Reader) throws -> EditRecipe.Tools {
        try r.requireExactly(["background", "portrait", "edit", "effects", "watermark", "border"])
        return EditRecipe.Tools(
            background: try readBackground(r.object("background")), portrait: try readPortrait(r.object("portrait")),
            edit: try readEdit(r.object("edit")), effects: try readEffects(r.object("effects")),
            watermark: try readWatermark(r.object("watermark")), border: try readBorder(r.object("border")))
    }

    private static func readBackground(_ r: Reader) throws -> EditRecipe.Background {
        try r.requireExactly(["subject", "replacement", "focus"])
        let subject = try r.object("subject")
        try subject.requireExactly(["matte", "refinements"])
        let refinements = try subject.array("refinements").enumerated().map { index, item -> EditRecipe.RefineStroke in
            let s = try Reader(item, path: subject.path + ".refinements[\(index)]")
            try s.requireExactly(["mode", "radius", "points"])
            return EditRecipe.RefineStroke(mode: try s.enumeration("mode"), radius: try s.number("radius", 0...0.5, excludingMinimum: true),
                                           points: try s.points("points"))
        }
        var replacement: EditRecipe.Replacement?
        if let rr = try r.optionalObject("replacement") {
            switch try rr.string("kind") {
            case "image":
                try rr.requireExactly(["kind", "image", "x", "y", "scale"])
                replacement = .image(try readAsset(rr.object("image")), x: try rr.number("x", 0...100),
                                     y: try rr.number("y", 0...100), scale: try rr.number("scale", 100...200))
            case "colour":
                try rr.requireExactly(["kind", "colour"])
                replacement = .colour(try rr.colour("colour"))
            case "gradient":
                try rr.requireExactly(["kind", "angle", "stops"])
                let stops = try rr.array("stops").enumerated().map { index, item -> EditRecipe.GradientStop in
                    let s = try Reader(item, path: rr.path + ".stops[\(index)]")
                    try s.requireExactly(["colour", "position"])
                    return EditRecipe.GradientStop(colour: try s.colour("colour"), position: try s.number("position", 0...1))
                }
                guard (2...8).contains(stops.count) else { throw rr.error("stops", "needs 2…8 stops") }
                guard zip(stops, stops.dropFirst()).allSatisfy({ $0.position <= $1.position }) else {
                    throw rr.error("stops", "positions must not decrease")
                }
                replacement = .gradient(angle: try rr.number("angle", 0...360), stops: stops)
            default:
                throw rr.error("kind", "unknown replacement kind")
            }
        }
        let f = try r.object("focus")
        try f.requireExactly(["blur", "depthOfField", "style", "bokeh", "styleAmount", "target", "depth"])
        let d = try f.object("depth")
        try d.requireExactly(["source", "map", "focusDepth", "replacementDepth"])
        let source: EditRecipe.Depth.Source = try d.enumeration("source")
        let map = try d.optionalObject("map").map(readDerived)
        guard (map == nil) == (source == .subjectMatte) else { throw d.error("map", "must be null exactly for subject-matte") }
        let depth = EditRecipe.Depth(source: source, map: map, focusDepth: try d.optionalNumber("focusDepth", 0...1),
                                     replacementDepth: try d.number("replacementDepth", 0...1))
        let target = try f.raw("target").flatMap { $0.isNull ? nil : try readPoint($0, f.path + ".target") }
        let focus = EditRecipe.Focus(
            blur: try f.number("blur", 0...100), depthOfField: try f.number("depthOfField", 0...100),
            style: try f.enumeration("style"), bokeh: try f.enumeration("bokeh"),
            styleAmount: try f.number("styleAmount", 0...100), target: target, depth: depth)
        return EditRecipe.Background(subject: EditRecipe.Subject(matte: try subject.optionalObject("matte").map(readDerived),
                                                                 refinements: refinements),
                                     replacement: replacement, focus: focus)
    }

    private static func readPortrait(_ r: Reader) throws -> EditRecipe.Portrait {
        try r.requireExactly(["faces"])
        let faces = try r.array("faces").enumerated().map { index, item -> EditRecipe.FaceEdit in
            let f = try Reader(item, path: r.path + ".faces[\(index)]")
            try f.requireExactly(["face", "skin", "underEye", "eyes", "teeth", "hair"])
            let identity = try f.object("face")
            try identity.requireExactly(["box", "detector"])
            let skin = try f.object("skin"); try skin.requireExactly(["smoothing", "blemishes", "evenTone", "keepTexture"])
            let under = try f.object("underEye"); try under.requireExactly(["brighten", "softenLines"])
            let eyes = try f.object("eyes"); try eyes.requireExactly(["brighten", "clarity"])
            let teeth = try f.object("teeth"); try teeth.requireExactly(["brighten"])
            let hair = try f.object("hair"); try hair.requireExactly(["definition", "flyaways", "shine"])
            return EditRecipe.FaceEdit(
                face: .init(box: try readRect(identity.raw("box") ?? .null, identity.path + ".box"),
                            detector: try readModelRef(identity.object("detector"))),
                skin: .init(smoothing: try skin.percent("smoothing"), blemishes: try skin.percent("blemishes"),
                            evenTone: try skin.percent("evenTone"), keepTexture: try skin.percent("keepTexture")),
                underEye: .init(brighten: try under.percent("brighten"), softenLines: try under.percent("softenLines")),
                eyes: .init(brighten: try eyes.percent("brighten"), clarity: try eyes.percent("clarity")),
                teeth: .init(brighten: try teeth.percent("brighten")),
                hair: .init(definition: try hair.percent("definition"), flyaways: try hair.percent("flyaways"), shine: try hair.percent("shine")))
        }
        guard faces.count <= 16 else { throw r.error("faces", "at most 16") }
        return EditRecipe.Portrait(faces: faces)
    }

    private static func readEdit(_ r: Reader) throws -> EditRecipe.Edit {
        try r.requireExactly(["geometry", "adjust", "remove"])
        let g = try r.object("geometry")
        try g.requireExactly(["quarterTurns", "flipHorizontal", "flipVertical", "perspective", "straighten", "crop"])
        let perspective = try g.object("perspective"); try perspective.requireExactly(["vertical", "horizontal"])
        let crop = try g.object("crop"); try crop.requireExactly(["aspect", "rect"])
        let turns = try g.integer("quarterTurns", minimum: 0)
        guard turns <= 3 else { throw g.error("quarterTurns", "must be 0…3") }
        let geometry = EditRecipe.Geometry(
            quarterTurns: Int(turns), flipHorizontal: try g.bool("flipHorizontal"), flipVertical: try g.bool("flipVertical"),
            perspectiveVertical: try perspective.slider("vertical"), perspectiveHorizontal: try perspective.slider("horizontal"),
            straighten: try g.number("straighten", -45...45), cropAspect: try crop.enumeration("aspect"),
            cropRect: try readRect(crop.raw("rect") ?? .null, crop.path + ".rect"))
        let a = try r.object("adjust")
        try a.requireExactly(["exposure", "contrast", "highlights", "shadows", "temp", "tint", "saturation", "vibrance",
                              "sharpness", "clarity", "noise"])
        let adjust = EditRecipe.Adjust(
            exposure: try a.slider("exposure"), contrast: try a.slider("contrast"), highlights: try a.slider("highlights"),
            shadows: try a.slider("shadows"), temp: try a.slider("temp"), tint: try a.slider("tint"),
            saturation: try a.slider("saturation"), vibrance: try a.slider("vibrance"), sharpness: try a.percent("sharpness"),
            clarity: try a.slider("clarity"), noise: try a.percent("noise"))
        let remove = try r.object("remove")
        try remove.requireExactly(["strokes"])
        let strokes = try remove.array("strokes").enumerated().map { index, item -> EditRecipe.RemoveStroke in
            let s = try Reader(item, path: remove.path + ".strokes[\(index)]")
            try s.requireExactly(["radius", "points", "result"])
            let result = try s.object("result"); try result.requireExactly(["status", "patch"])
            let status: EditRecipe.RemoveStroke.Status = try result.enumeration("status")
            let patch = try result.optionalObject("patch").map(readDerived)
            guard (patch != nil) == (status == .applied) else { throw result.error("patch", "present exactly when applied") }
            return EditRecipe.RemoveStroke(radius: try s.number("radius", 0...0.5, excludingMinimum: true),
                                           points: try s.points("points"), status: status, patch: patch)
        }
        return EditRecipe.Edit(geometry: geometry, adjust: adjust, remove: EditRecipe.Remove(strokes: strokes))
    }

    private static func readEffects(_ r: Reader) throws -> EditRecipe.Effects {
        try r.requireExactly(["lightLeak", "grain", "vignette"])
        let l = try r.object("lightLeak"); try l.requireExactly(["enabled", "style", "intensity", "x", "y", "rotation"])
        let g = try r.object("grain"); try g.requireExactly(["enabled", "style", "amount", "size", "roughness", "seed"])
        let v = try r.object("vignette"); try v.requireExactly(["enabled", "amount", "size", "softness"])
        let seed = try g.integer("seed", minimum: 0)
        guard seed <= Int64(UInt32.max) else { throw g.error("seed", "must be a uint32") }
        return EditRecipe.Effects(
            lightLeak: .init(enabled: try l.bool("enabled"), style: try l.enumeration("style"), intensity: try l.percent("intensity"),
                             x: try l.percent("x"), y: try l.percent("y"), rotation: try l.number("rotation", -180...180)),
            grain: .init(enabled: try g.bool("enabled"), style: try g.enumeration("style"), amount: try g.percent("amount"),
                         size: try g.percent("size"), roughness: try g.percent("roughness"), seed: UInt32(seed)),
            vignette: .init(enabled: try v.bool("enabled"), amount: try v.percent("amount"), size: try v.percent("size"),
                            softness: try v.percent("softness")))
    }

    private static func readWatermark(_ r: Reader) throws -> EditRecipe.Watermark {
        try r.requireExactly(["type", "signature", "text", "logo", "placement", "position", "offset", "size", "opacity", "colour"])
        let type: EditRecipe.Watermark.Kind = try r.enumeration("type")
        let signature = try r.optionalObject("signature").map { s -> EditRecipe.Watermark.SignatureRef in
            try s.requireExactly(["signatureId", "signatureVersion", "kind"])
            let version = try s.string("signatureVersion")
            guard version.count == 12, version.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw s.error("signatureVersion", "must be 12 lowercase hex digits")
            }
            return .init(signatureId: try s.string("signatureId", nonEmpty: true), signatureVersion: version, kind: try s.enumeration("kind"))
        }
        let text = try r.optionalObject("text").map { t -> EditRecipe.Watermark.Text in
            try t.requireExactly(["text", "font"])
            let value = try t.string("text", nonEmpty: true)
            guard value.count <= 80 else { throw t.error("text", "at most 80 characters") }
            return .init(text: value, font: try t.enumeration("font"))
        }
        let logo = try r.optionalObject("logo").map { l -> EditRecipe.AssetRef in
            try l.requireExactly(["image"])
            return try readAsset(l.object("image"))
        }
        // Exactly the part matching `type` is set (reader rule).
        guard (signature != nil) == (type == .signature), (text != nil) == (type == .text), (logo != nil) == (type == .logo) else {
            throw r.error("type", "exactly the part matching type must be set")
        }
        let position = try r.integer("position", minimum: 0)
        guard position <= 8 else { throw r.error("position", "must be 0…8") }
        let offset = try r.raw("offset").flatMap { $0.isNull ? nil : try readPoint($0, r.path + ".offset") }
        return EditRecipe.Watermark(type: type, signature: signature, text: text, logo: logo, placement: try r.enumeration("placement"),
                                    position: Int(position), offset: offset, size: try r.number("size", 10...80),
                                    opacity: try r.percent("opacity"), colour: try r.colour("colour"))
    }

    private static func readBorder(_ r: Reader) throws -> EditRecipe.Border {
        try r.requireExactly(["type", "colour", "width", "spacing", "mat"])
        return EditRecipe.Border(type: try r.enumeration("type"), colour: try r.colour("colour"), width: try r.number("width", 1...15),
                                 spacing: try r.number("spacing", 0...12), mat: try r.colour("mat"))
    }

    // MARK: - Encode

    /// Canonical bytes: schema key order, no whitespace, integers without a decimal point.
    static func encode(_ recipe: EditRecipe) -> Data {
        CanonicalJSON.object([
            ("schema", .number(String(EditRecipe.schema))),
            ("recipeVersion", .number(String(EditRecipe.recipeVersion))),
            ("source", source(recipe.source)),
            ("auto", .object([
                ("modelId", .string(recipe.auto.modelId)), ("modelVersion", .string(recipe.auto.modelVersion)),
                ("weights", .array(recipe.auto.weights.map(number))),
                ("guardrail", recipe.auto.guardrail.map(CanonicalJSON.string) ?? .null),
                ("strength", number(recipe.auto.strength))
            ])),
            ("look", recipe.look.map { .object([("lookId", .string($0.lookId)), ("lookVersion", .string($0.lookVersion)),
                                                 ("strength", number($0.strength))]) } ?? .null),
            ("revision", .number(String(recipe.revision))),
            ("tools", tools(recipe.tools))
        ]).serialized()
    }

    /// Integral values without a decimal point; others in the shortest round-trip form (Python's
    /// `repr`, which is what the fixtures were written with).
    static func number(_ value: Double) -> CanonicalJSON {
        if value == value.rounded(), abs(value) < 1e15 { return .number(String(Int64(value))) }
        return .number("\(value)")
    }

    private static func fingerprint(_ f: EditRecipe.Fingerprint) -> CanonicalJSON {
        .object([("headSha256", .string(f.headSha256)), ("byteSize", .number(String(f.byteSize))),
                 ("pixelWidth", .number(String(f.pixelWidth))), ("pixelHeight", .number(String(f.pixelHeight)))])
    }

    private static func source(_ s: EditRecipe.Source) -> CanonicalJSON {
        .object([("assetId", .string(s.assetId)), ("fingerprint", fingerprint(s.fingerprint)),
                 ("orientation", .number(String(s.orientation)))])
    }

    private static func model(_ m: EditRecipe.ModelRef) -> CanonicalJSON {
        .object([("id", .string(m.id)), ("version", .string(m.version))])
    }

    private static func derived(_ d: EditRecipe.DerivedRef?) -> CanonicalJSON {
        guard let d else { return .null }
        return .object([("sha256", .string(d.sha256)), ("model", model(d.model)),
                        ("width", .number(String(d.width))), ("height", .number(String(d.height)))])
    }

    private static func asset(_ a: EditRecipe.AssetRef) -> CanonicalJSON {
        switch a {
        case .bundled(let id): return .object([("kind", .string("bundled")), ("id", .string(id))])
        case .photo(let assetId, let f):
            return .object([("kind", .string("photo")), ("assetId", .string(assetId)), ("fingerprint", fingerprint(f))])
        case .file(let sha): return .object([("kind", .string("file")), ("sha256", .string(sha))])
        }
    }

    private static func point(_ p: EditRecipe.Point?) -> CanonicalJSON {
        guard let p else { return .null }
        return .array([number(p.x), number(p.y)])
    }

    private static func rect(_ r: EditRecipe.Rect) -> CanonicalJSON {
        .array([number(r.x), number(r.y), number(r.width), number(r.height)])
    }

    // swiftlint:disable:next function_body_length
    private static func tools(_ t: EditRecipe.Tools) -> CanonicalJSON {
        let bg = t.background
        let replacement: CanonicalJSON
        switch bg.replacement {
        case nil: replacement = .null
        case .image(let image, let x, let y, let scale)?:
            replacement = .object([("kind", .string("image")), ("image", asset(image)), ("x", number(x)), ("y", number(y)),
                                   ("scale", number(scale))])
        case .colour(let colour)?: replacement = .object([("kind", .string("colour")), ("colour", .string(colour))])
        case .gradient(let angle, let stops)?:
            replacement = .object([("kind", .string("gradient")), ("angle", number(angle)),
                                   ("stops", .array(stops.map { .object([("colour", .string($0.colour)), ("position", number($0.position))]) }))])
        }
        let focus = bg.focus
        let background = CanonicalJSON.object([
            ("subject", .object([("matte", derived(bg.subject.matte)),
                                 ("refinements", .array(bg.subject.refinements.map {
                                     .object([("mode", .string($0.mode.rawValue)), ("radius", number($0.radius)),
                                              ("points", .array($0.points.map { point($0) }))])
                                 }))])),
            ("replacement", replacement),
            ("focus", .object([
                ("blur", number(focus.blur)), ("depthOfField", number(focus.depthOfField)), ("style", .string(focus.style.rawValue)),
                ("bokeh", .string(focus.bokeh.rawValue)), ("styleAmount", number(focus.styleAmount)), ("target", point(focus.target)),
                ("depth", .object([("source", .string(focus.depth.source.rawValue)), ("map", derived(focus.depth.map)),
                                   ("focusDepth", focus.depth.focusDepth.map(number) ?? .null),
                                   ("replacementDepth", number(focus.depth.replacementDepth))]))
            ]))
        ])
        let portrait = CanonicalJSON.object([("faces", .array(t.portrait.faces.map { f in
            .object([
                ("face", .object([("box", rect(f.face.box)), ("detector", model(f.face.detector))])),
                ("skin", .object([("smoothing", number(f.skin.smoothing)), ("blemishes", number(f.skin.blemishes)),
                                  ("evenTone", number(f.skin.evenTone)), ("keepTexture", number(f.skin.keepTexture))])),
                ("underEye", .object([("brighten", number(f.underEye.brighten)), ("softenLines", number(f.underEye.softenLines))])),
                ("eyes", .object([("brighten", number(f.eyes.brighten)), ("clarity", number(f.eyes.clarity))])),
                ("teeth", .object([("brighten", number(f.teeth.brighten))])),
                ("hair", .object([("definition", number(f.hair.definition)), ("flyaways", number(f.hair.flyaways)),
                                  ("shine", number(f.hair.shine))]))
            ])
        }))])
        let g = t.edit.geometry, a = t.edit.adjust
        let edit = CanonicalJSON.object([
            ("geometry", .object([
                ("quarterTurns", .number(String(g.quarterTurns))), ("flipHorizontal", .bool(g.flipHorizontal)),
                ("flipVertical", .bool(g.flipVertical)),
                ("perspective", .object([("vertical", number(g.perspectiveVertical)), ("horizontal", number(g.perspectiveHorizontal))])),
                ("straighten", number(g.straighten)),
                ("crop", .object([("aspect", .string(g.cropAspect.rawValue)), ("rect", rect(g.cropRect))]))
            ])),
            ("adjust", .object([
                ("exposure", number(a.exposure)), ("contrast", number(a.contrast)), ("highlights", number(a.highlights)),
                ("shadows", number(a.shadows)), ("temp", number(a.temp)), ("tint", number(a.tint)),
                ("saturation", number(a.saturation)), ("vibrance", number(a.vibrance)), ("sharpness", number(a.sharpness)),
                ("clarity", number(a.clarity)), ("noise", number(a.noise))
            ])),
            ("remove", .object([("strokes", .array(t.edit.remove.strokes.map {
                .object([("radius", number($0.radius)), ("points", .array($0.points.map { point($0) })),
                         ("result", .object([("status", .string($0.status.rawValue)), ("patch", derived($0.patch))]))])
            }))]))
        ])
        let fx = t.effects
        let effects = CanonicalJSON.object([
            ("lightLeak", .object([("enabled", .bool(fx.lightLeak.enabled)), ("style", .string(fx.lightLeak.style.rawValue)),
                                   ("intensity", number(fx.lightLeak.intensity)), ("x", number(fx.lightLeak.x)),
                                   ("y", number(fx.lightLeak.y)), ("rotation", number(fx.lightLeak.rotation))])),
            ("grain", .object([("enabled", .bool(fx.grain.enabled)), ("style", .string(fx.grain.style.rawValue)),
                               ("amount", number(fx.grain.amount)), ("size", number(fx.grain.size)),
                               ("roughness", number(fx.grain.roughness)), ("seed", .number(String(fx.grain.seed)))])),
            ("vignette", .object([("enabled", .bool(fx.vignette.enabled)), ("amount", number(fx.vignette.amount)),
                                  ("size", number(fx.vignette.size)), ("softness", number(fx.vignette.softness))]))
        ])
        let w = t.watermark
        let watermark = CanonicalJSON.object([
            ("type", .string(w.type.rawValue)),
            ("signature", w.signature.map { .object([("signatureId", .string($0.signatureId)),
                                                      ("signatureVersion", .string($0.signatureVersion)),
                                                      ("kind", .string($0.kind.rawValue))]) } ?? .null),
            ("text", w.text.map { .object([("text", .string($0.text)), ("font", .string($0.font.rawValue))]) } ?? .null),
            ("logo", w.logo.map { .object([("image", asset($0))]) } ?? .null),
            ("placement", .string(w.placement.rawValue)), ("position", .number(String(w.position))), ("offset", point(w.offset)),
            ("size", number(w.size)), ("opacity", number(w.opacity)), ("colour", .string(w.colour))
        ])
        let b = t.border
        let border = CanonicalJSON.object([("type", .string(b.type.rawValue)), ("colour", .string(b.colour)),
                                           ("width", number(b.width)), ("spacing", number(b.spacing)), ("mat", .string(b.mat))])
        return .object([("background", background), ("portrait", portrait), ("edit", edit), ("effects", effects),
                        ("watermark", watermark), ("border", border)])
    }
}

// MARK: - Reader

/// A strict view of one JSON object at `path`.
private struct Reader {
    let members: [(key: String, value: CanonicalJSON)]
    let path: String

    init(_ value: CanonicalJSON, path: String) throws {
        guard let members = value.objectMembers else { throw EditRecipeDecodingError(path: path, problem: "not an object") }
        self.members = members
        self.path = path
    }

    func error(_ key: String, _ problem: String) -> EditRecipeDecodingError {
        EditRecipeDecodingError(path: path.isEmpty ? key : "\(path).\(key)", problem: problem)
    }

    func raw(_ key: String) -> CanonicalJSON? { members.first { $0.key == key }?.value }

    /// Every listed key present, no other key.
    func requireExactly(_ keys: [String]) throws {
        let present = Set(members.map(\.key))
        if let unknown = present.subtracting(keys).sorted().first { throw error(unknown, "unknown key") }
        if let missing = keys.first(where: { !present.contains($0) }) { throw error(missing, "missing key") }
    }

    func value(_ key: String) throws -> CanonicalJSON {
        guard let value = raw(key) else { throw error(key, "missing key") }
        return value
    }

    func object(_ key: String) throws -> Reader { try Reader(value(key), path: path.isEmpty ? key : "\(path).\(key)") }

    func optionalObject(_ key: String) throws -> Reader? {
        let v = try value(key)
        return v.isNull ? nil : try Reader(v, path: path.isEmpty ? key : "\(path).\(key)")
    }

    func array(_ key: String) throws -> [CanonicalJSON] {
        guard let items = try value(key).arrayValue else { throw error(key, "not an array") }
        return items
    }

    func string(_ key: String, nonEmpty: Bool = false) throws -> String {
        guard let s = try value(key).stringValue else { throw error(key, "not a string") }
        if nonEmpty, s.isEmpty { throw error(key, "must not be empty") }
        return s
    }

    func bool(_ key: String) throws -> Bool {
        guard let b = try value(key).boolValue else { throw error(key, "not a boolean") }
        return b
    }

    func integer(_ key: String, minimum: Int64? = nil) throws -> Int64 {
        guard let i = try value(key).integerLiteralValue else { throw error(key, "not an integer") }
        if let minimum, i < minimum { throw error(key, "must be ≥ \(minimum)") }
        return i
    }

    func number(_ key: String, _ range: ClosedRange<Double>, excludingMinimum: Bool = false) throws -> Double {
        guard let n = try value(key).doubleValue, n.isFinite else { throw error(key, "not a number") }
        guard range.contains(n), !(excludingMinimum && n == range.lowerBound) else { throw error(key, "out of range \(range)") }
        return n
    }

    func optionalNumber(_ key: String, _ range: ClosedRange<Double>) throws -> Double? {
        try value(key).isNull ? nil : try number(key, range)
    }

    func percent(_ key: String) throws -> Double { try number(key, 0...100) }
    func slider(_ key: String) throws -> Double { try number(key, -100...100) }

    func colour(_ key: String) throws -> String {
        let c = try string(key)
        guard c.count == 7, c.first == "#", c.dropFirst().allSatisfy({ "0123456789ABCDEF".contains($0) }) else {
            throw error(key, "must be #RRGGBB in upper case")
        }
        return c
    }

    func sha256(_ key: String) throws -> String {
        let s = try string(key)
        guard s.count == 64, s.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw error(key, "not a sha256") }
        return s
    }

    func enumeration<E: RawRepresentable>(_ key: String) throws -> E where E.RawValue == String {
        guard let e = E(rawValue: try string(key)) else { throw error(key, "unknown value") }
        return e
    }

    func points(_ key: String) throws -> [EditRecipe.Point] {
        let items = try array(key)
        guard !items.isEmpty else { throw error(key, "needs at least one point") }
        return try items.enumerated().map { index, item in
            guard let pair = item.arrayValue, pair.count == 2,
                  let x = pair[0].doubleValue, let y = pair[1].doubleValue, (0...1).contains(x), (0...1).contains(y) else {
                throw error("\(key)[\(index)]", "not a unit point")
            }
            return EditRecipe.Point(x: x, y: y)
        }
    }
}
