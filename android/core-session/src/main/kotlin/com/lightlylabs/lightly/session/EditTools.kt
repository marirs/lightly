@file:UseSerializers(CanonicalDoubleSerializer::class)
@file:OptIn(ExperimentalSerializationApi::class)

package com.lightlylabs.lightly.session

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonClassDiscriminator

/*
 * EditState schema 3 `tools` (shared/contracts/edit-recipe-v1.json, recipeVersion 1): every tool of
 * the approved prototype except Develop, whose state stays in `auto` + `look` exactly as in schema 2.
 *
 * Property order IS the canonical key order (kotlinx writes declaration order), so do not reorder.
 * Ranges and the reader rules of schema_check.py are enforced in `init`, so an out-of-range or
 * inconsistent document fails to decode as a whole instead of being clamped or half-read.
 *
 * Slice 2 renders none of these tools yet: they are carried, saved, undone and redone with the
 * recipe so that slices 3–5 extend the renderer, not the format.
 */

@Serializable
data class EditTools(
    val background: BackgroundTool,
    val portrait: PortraitTool,
    val edit: EditTool,
    val effects: EffectsTool,
    val watermark: WatermarkTool,
    val border: BorderTool,
    /**
     * The Text tool (owner amendment 2026-10-11; rendering-v2 revision 7 stage 11). The one optional key in `tools`: a
     * recipe saved before it reads as no layers (the default), and it is always written (encodeDefaults), after border
     * as edit-recipe-v1.json lists it.
     */
    val text: TextTool = TextTool(emptyList()),
) {
    companion object {
        /** The prototype's `newSession` defaults; [grainSeed] is fixed when the edit is created. */
        fun neutral(grainSeed: Long) = EditTools(
            background = BackgroundTool(
                subject = Subject(matte = null, refinements = emptyList()),
                replacement = null,
                focus = Focus(blur = 0.0, depthOfField = 40.0, style = FocusStyle.LENS, bokeh = Bokeh.ROUND, styleAmount = 50.0, target = null,
                    depth = Depth(source = DepthSource.SUBJECT_MATTE, map = null, focusDepth = null, replacementDepth = 1.0)),
            ),
            portrait = PortraitTool(faces = emptyList()),
            edit = EditTool(
                geometry = Geometry(0, flipHorizontal = false, flipVertical = false, perspective = Perspective(0.0, 0.0), straighten = 0.0,
                    crop = Crop(CropAspect.ORIGINAL, NormalisedRect(0.0, 0.0, 1.0, 1.0))),
                adjust = Adjust(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0),
                remove = RemoveTool(strokes = emptyList()),
            ),
            effects = EffectsTool(
                lightLeak = LightLeak(enabled = false, style = LeakStyle.WARM, intensity = 55.0, x = 18.0, y = 14.0, rotation = 0.0),
                grain = UserGrain(enabled = false, style = GrainStyle.FILM, amount = 30.0, size = 40.0, roughness = 50.0, seed = grainSeed),
                vignette = UserVignette(enabled = false, amount = 35.0, size = 60.0, softness = 60.0),
            ),
            watermark = WatermarkTool(WatermarkType.NONE, null, null, null, WatermarkPlacement.PHOTO, position = 8, offset = null, size = 34.0, opacity = 85.0, colour = "#FFFFFF"),
            border = BorderTool(BorderType.NONE, colour = "#FFFFFF", width = 4.0, spacing = 3.0, mat = "#F4F1EC"),
            text = TextTool(emptyList()),
        )

        /** Migration rule: the first 32 bits of the source's headSha256. */
        fun grainSeedFor(fingerprint: SourceFingerprint): Long = fingerprint.headSha256.substring(0, 8).toLong(16)
    }
}

// --- shared value types ----------------------------------------------------------------------------

@Serializable(with = NormalisedPointSerializer::class)
data class NormalisedPoint(val x: Double, val y: Double) {
    init { requireUnit(x, "point x"); requireUnit(y, "point y") }
}

@Serializable(with = NormalisedRectSerializer::class)
data class NormalisedRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    init {
        listOf(x, y, width, height).forEach { requireUnit(it, "rect value") }
        require(x + width <= 1.0 + EPSILON && y + height <= 1.0 + EPSILON) { "rect must lie inside the frame" }
    }
}

@Serializable
data class ModelRef(val id: String, val version: String) {
    init { require(id.isNotEmpty() && version.isNotEmpty()) { "model id and version must not be empty" } }
}

@Serializable
data class DerivedRef(val sha256: String, val model: ModelRef, val width: Int, val height: Int) {
    init {
        requireSha256(sha256)
        require(width >= 1 && height >= 1) { "derived result size must be positive" }
    }
}

@Serializable
@JsonClassDiscriminator("kind")
sealed interface AssetRef {
    @Serializable @SerialName("bundled")
    data class Bundled(val id: String) : AssetRef { init { require(id.isNotEmpty()) { "bundled asset id must not be empty" } } }

    @Serializable @SerialName("photo")
    data class Photo(val assetId: String, val fingerprint: SourceFingerprint) : AssetRef { init { require(assetId.isNotEmpty()) { "photo assetId must not be empty" } } }

    @Serializable @SerialName("file")
    data class File(val sha256: String) : AssetRef { init { requireSha256(sha256) } }
}

// --- background -------------------------------------------------------------------------------------

@Serializable
data class BackgroundTool(val subject: Subject, val replacement: Replacement?, val focus: Focus)

@Serializable
data class Subject(val matte: DerivedRef?, val refinements: List<RefineStroke>)

@Serializable
enum class RefineMode { @SerialName("add") ADD, @SerialName("erase") ERASE }

@Serializable
data class RefineStroke(val mode: RefineMode, val radius: Double, val points: List<NormalisedPoint>) {
    init {
        require(radius > 0 && radius <= 0.5) { "refine radius must be in (0, 0.5]" }
        require(points.isNotEmpty()) { "a refine stroke needs at least one point" }
    }
}

@Serializable
@JsonClassDiscriminator("kind")
sealed interface Replacement {
    @Serializable @SerialName("image")
    data class Image(val image: AssetRef, val x: Double, val y: Double, val scale: Double) : Replacement {
        init {
            requirePercent(x, "replacement x"); requirePercent(y, "replacement y")
            require(scale in 100.0..200.0) { "replacement scale must be in 100..200" }
        }
    }

    @Serializable @SerialName("colour")
    data class Colour(val colour: String) : Replacement { init { requireColour(colour) } }

    @Serializable @SerialName("gradient")
    data class Gradient(val angle: Double, val stops: List<GradientStop>) : Replacement {
        init {
            require(angle in 0.0..360.0) { "gradient angle must be in 0..360" }
            require(stops.size in 2..8) { "a gradient has 2 to 8 stops" }
            require(stops.zipWithNext().all { (a, b) -> b.position >= a.position }) { "gradient stop positions must not decrease" }
        }
    }
}

@Serializable
data class GradientStop(val colour: String, val position: Double) {
    init { requireColour(colour); requireUnit(position, "gradient position") }
}

@Serializable enum class FocusStyle { @SerialName("lens") LENS, @SerialName("soft") SOFT, @SerialName("swirl") SWIRL, @SerialName("motion") MOTION }
@Serializable enum class Bokeh { @SerialName("round") ROUND, @SerialName("hex") HEX, @SerialName("heart") HEART, @SerialName("star") STAR }

@Serializable
data class Focus(
    val blur: Double,
    val depthOfField: Double,
    val style: FocusStyle,
    val bokeh: Bokeh,
    val styleAmount: Double,
    val target: NormalisedPoint?,
    val depth: Depth,
) {
    init {
        requirePercent(blur, "blur"); requirePercent(depthOfField, "depthOfField"); requirePercent(styleAmount, "styleAmount")
        // rendering-v2 revision 1 (contract fixes 1, G3): subject-matte means "no depth", and blur needs
        // depth; a mask-only blur is never rendered (depth-evaluation §R8). The reader rejects the pair.
        require(!(blur > 0 && depth.source == DepthSource.SUBJECT_MATTE)) { "blur > 0 needs a depth map (source subject-matte has none)" }
    }
}

@Serializable enum class DepthSource { @SerialName("embedded") EMBEDDED, @SerialName("estimated") ESTIMATED, @SerialName("subject-matte") SUBJECT_MATTE }

@Serializable
data class Depth(val source: DepthSource, val map: DerivedRef?, val focusDepth: Double?, val replacementDepth: Double) {
    init {
        require((map == null) == (source == DepthSource.SUBJECT_MATTE)) { "the depth map is null exactly when the source is subject-matte" }
        focusDepth?.let { requireUnit(it, "focusDepth") }
        requireUnit(replacementDepth, "replacementDepth")
    }
}

// --- portrait ---------------------------------------------------------------------------------------

@Serializable
data class PortraitTool(val faces: List<FaceEdit>) {
    init { require(faces.size <= 16) { "at most 16 faces" } }
}

@Serializable
data class FaceIdentity(val box: NormalisedRect, val detector: ModelRef)

@Serializable
data class Skin(val smoothing: Double, val blemishes: Double, val evenTone: Double, val keepTexture: Double) {
    init { listOf(smoothing, blemishes, evenTone, keepTexture).forEach { requirePercent(it, "skin") } }
}

@Serializable
data class UnderEye(val brighten: Double, val softenLines: Double) { init { requirePercent(brighten, "underEye"); requirePercent(softenLines, "underEye") } }

@Serializable
data class Eyes(val brighten: Double, val clarity: Double) { init { requirePercent(brighten, "eyes"); requirePercent(clarity, "eyes") } }

@Serializable
data class Teeth(val brighten: Double) { init { requirePercent(brighten, "teeth") } }

/** Portrait › Smile (owner amendment 2026-10-11): −100 lowers the mouth corners, +100 lifts them, 0 is the photo as taken. */
@Serializable
data class Smile(val amount: Double) { init { requireSlider(amount, "smile") } }

/** Portrait › Sunglasses lens colours (rendering-v2 §7.5). */
@Serializable enum class SunglassesLens {
    @SerialName("dark") DARK, @SerialName("brown") BROWN, @SerialName("green") GREEN, @SerialName("gradient") GRADIENT, @SerialName("mirror") MIRROR
}

/** The face's own glasses painted out: a LaMa patch over [rect], stored like a Remove stroke's. */
@Serializable
data class SunglassesRemoved(val rect: NormalisedRect, val patch: DerivedRef)

/**
 * Portrait › Sunglasses (rendering-v2 revision 9 §7.5; owner-approved design portrait-sunglasses-v2, 2026-10-13).
 * [pair] is a sunglasses-pack id ("sun-" + 12 hex), null for None. [removed] is kept when None is chosen, so picking a pair
 * again does not recompute it; the renderer composites it only while a pair is chosen.
 */
@Serializable
data class Sunglasses(val pair: String?, val lens: SunglassesLens, val darkness: Double, val size: Double, val removed: SunglassesRemoved?) {
    init {
        require(pair == null || PAIR_ID.matches(pair)) { "sunglasses pair must be a sunglasses-pack id" }
        requirePercent(darkness, "sunglasses.darkness")
        require(size in -50.0..50.0) { "sunglasses.size must be -50..50" }
    }
    companion object {
        val PAIR_ID = Regex("sun-[0-9a-f]{12}")
        val NONE = Sunglasses(pair = null, lens = SunglassesLens.DARK, darkness = 75.0, size = 0.0, removed = null)
    }
}

@Serializable
data class Hair(val definition: Double, val flyaways: Double, val shine: Double) {
    init { listOf(definition, flyaways, shine).forEach { requirePercent(it, "hair") } }
}

@Serializable
data class FaceEdit(
    val face: FaceIdentity,
    val skin: Skin,
    val underEye: UnderEye,
    val eyes: Eyes,
    val teeth: Teeth,
    /**
     * The one optional key in faceEdit (rendering-v2 revision 7 `portrait.smile`): a face saved before it reads as amount 0,
     * and it is always written, between teeth and hair as edit-recipe-v1.json lists it.
     */
    val smile: Smile = Smile(0.0),
    /**
     * Optional (rendering-v2 revision 9 `portrait.sunglasses`): missing = no sunglasses, and it is written only once the
     * face has had a pair (NEVER-encoded default), between smile and hair as edit-recipe-v1.json lists it.
     */
    @EncodeDefault(EncodeDefault.Mode.NEVER) val sunglasses: Sunglasses? = null,
    val hair: Hair,
)

// --- edit -------------------------------------------------------------------------------------------

@Serializable
data class EditTool(val geometry: Geometry, val adjust: Adjust, val remove: RemoveTool)

@Serializable
data class Perspective(val vertical: Double, val horizontal: Double) { init { requireSlider(vertical, "perspective"); requireSlider(horizontal, "perspective") } }

@Serializable
enum class CropAspect {
    @SerialName("original") ORIGINAL, @SerialName("free") FREE, @SerialName("1:1") SQUARE, @SerialName("4:5") FOUR_FIVE,
    @SerialName("3:2") THREE_TWO, @SerialName("16:9") SIXTEEN_NINE, @SerialName("9:16") NINE_SIXTEEN,
}

@Serializable
data class Crop(val aspect: CropAspect, val rect: NormalisedRect)

@Serializable
data class Geometry(
    val quarterTurns: Int,
    val flipHorizontal: Boolean,
    val flipVertical: Boolean,
    val perspective: Perspective,
    val straighten: Double,
    val crop: Crop,
) {
    init {
        require(quarterTurns in 0..3) { "quarterTurns must be 0..3" }
        require(straighten in -45.0..45.0) { "straighten must be in -45..45" }
    }
}

@Serializable
data class Adjust(
    val exposure: Double, val contrast: Double, val highlights: Double, val shadows: Double,
    val temp: Double, val tint: Double, val saturation: Double, val vibrance: Double,
    val sharpness: Double, val clarity: Double, val noise: Double,
) {
    init {
        listOf(exposure, contrast, highlights, shadows, temp, tint, saturation, vibrance, clarity).forEach { requireSlider(it, "adjust") }
        requirePercent(sharpness, "sharpness"); requirePercent(noise, "noise")
    }
}

@Serializable
data class RemoveTool(val strokes: List<RemoveStroke>)

@Serializable enum class RemoveStatus { @SerialName("applied") APPLIED, @SerialName("failed") FAILED, @SerialName("unavailable") UNAVAILABLE }

@Serializable
data class RemoveResult(val status: RemoveStatus, val patch: DerivedRef?) {
    init { require((patch != null) == (status == RemoveStatus.APPLIED)) { "a Remove patch is present exactly when the stroke was applied" } }
}

@Serializable
data class RemoveStroke(val radius: Double, val points: List<NormalisedPoint>, val result: RemoveResult) {
    init {
        require(radius > 0 && radius <= 0.5) { "remove radius must be in (0, 0.5]" }
        require(points.isNotEmpty()) { "a remove stroke needs at least one point" }
    }
}

// --- effects ----------------------------------------------------------------------------------------

/**
 * `effects.lightLeak.style` (edit-recipe-v1, rendering-v2 revision 8): one of the four drawn styles, or a leak-pack image
 * `leak-<12 hex>` (owner 2026-10-11). The drawn styles are no longer offered but still decode and render, so edits saved
 * before revision 8 look as they did. Written as the bare string either way, so both forms share one JSON shape.
 */
@Serializable(with = LeakStyleSerializer::class)
sealed interface LeakStyle {
    /** The recipe's string: `warm` … `prism`, or the leak id. */
    val wireName: String

    /** The drawn radial styles of revisions 2–7 (rendering-v2 §Light leak, unchanged). */
    enum class Drawn(override val wireName: String) : LeakStyle { WARM("warm"), AMBER("amber"), ROSE("rose"), PRISM("prism") }

    /** A leak-pack image, by its stable id (shared/leaks/build_leaks.py: "leak-" + 12 hex digits of the source's SHA-256). */
    data class Image(val leakId: String) : LeakStyle {
        init { require(LEAK_ID_PATTERN.matches(leakId)) { "a leak image id is leak-<12 lowercase hex>, was $leakId" } }
        override val wireName: String get() = leakId
    }

    companion object {
        val WARM: LeakStyle = Drawn.WARM
        val AMBER: LeakStyle = Drawn.AMBER
        val ROSE: LeakStyle = Drawn.ROSE
        val PRISM: LeakStyle = Drawn.PRISM

        val LEAK_ID_PATTERN = Regex("^leak-[0-9a-f]{12}$")

        /** The recipe string to a style; anything that is neither a drawn style nor a leak id fails, as the schema does. */
        fun fromWireName(value: String): LeakStyle =
            Drawn.entries.firstOrNull { it.wireName == value } ?: Image(value)
    }
}

object LeakStyleSerializer : KSerializer<LeakStyle> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("lightly.LeakStyle", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: LeakStyle) = encoder.encodeString(value.wireName)
    override fun deserialize(decoder: Decoder): LeakStyle = LeakStyle.fromWireName(decoder.decodeString())
}

@Serializable enum class GrainStyle { @SerialName("fine") FINE, @SerialName("film") FILM, @SerialName("coarse") COARSE }

@Serializable
data class EffectsTool(
    val lightLeak: LightLeak,
    val grain: UserGrain,
    val vignette: UserVignette,
    /** Effects › Selective Colour (rendering-v2 revision 4). Optional in edit-recipe-v1: null (not written) means no
     *  kept colours, so recipes written before it stay valid and byte-identical. */
    @EncodeDefault(EncodeDefault.Mode.NEVER) val selectiveColour: SelectiveColourTool? = null,
)

/** Kept colours (never empty: no colours is `selectiveColour = null`), Range and Strength. */
@Serializable
data class SelectiveColourTool(val colours: List<KeptColourRecipe>, val range: Double, val strength: Double) {
    init {
        require(colours.size in 1..8) { "selective colour keeps 1..8 colours, was ${colours.size}" }
        requirePercent(range, "range"); requirePercent(strength, "strength")
    }
}

/** OKLab sampled from the effects stage input when picked; x, y where it was picked, as fractions of the source photo. */
@Serializable
data class KeptColourRecipe(val oklab: List<Double>, val x: Double, val y: Double) {
    init {
        require(oklab.size == 3 && oklab.all { it.isFinite() }) { "oklab must be three numbers" }
        require(x in 0.0..1.0 && y in 0.0..1.0) { "pick point must be a fraction of the photo" }
    }
}

@Serializable
data class LightLeak(val enabled: Boolean, val style: LeakStyle, val intensity: Double, val x: Double, val y: Double, val rotation: Double) {
    init {
        requirePercent(intensity, "intensity"); requirePercent(x, "leak x"); requirePercent(y, "leak y")
        require(rotation in -180.0..180.0) { "rotation must be in -180..180" }
    }
}

@Serializable
data class UserGrain(val enabled: Boolean, val style: GrainStyle, val amount: Double, val size: Double, val roughness: Double, val seed: Long) {
    init {
        listOf(amount, size, roughness).forEach { requirePercent(it, "grain") }
        require(seed in 0..4294967295L) { "grain seed must be a uint32" }
    }
}

@Serializable
data class UserVignette(val enabled: Boolean, val amount: Double, val size: Double, val softness: Double) {
    init { listOf(amount, size, softness).forEach { requirePercent(it, "vignette") } }
}

// --- watermark --------------------------------------------------------------------------------------

@Serializable enum class WatermarkType { @SerialName("none") NONE, @SerialName("signature") SIGNATURE, @SerialName("text") TEXT, @SerialName("logo") LOGO }
@Serializable enum class WatermarkPlacement { @SerialName("photo") PHOTO, @SerialName("border") BORDER, @SerialName("canvas") CANVAS }
@Serializable enum class SignatureKind { @SerialName("drawn") DRAWN, @SerialName("imported") IMPORTED }
/**
 * Watermark › Text fonts, in the mockup's `WM_FONTS` order: the six approved, then the seven signature scripts the owner
 * added on 2026-10-11 (second amendment; shared/fonts, each with its licence file).
 */
@Serializable enum class WatermarkFont {
    @SerialName("Allura") ALLURA, @SerialName("Cormorant Garamond") CORMORANT_GARAMOND, @SerialName("Inter") INTER, @SerialName("Caveat") CAVEAT,
    @SerialName("Dancing Script") DANCING_SCRIPT, @SerialName("Lora") LORA,
    @SerialName("Carpenters") CARPENTERS, @SerialName("Sourdough Script") SOURDOUGH_SCRIPT, @SerialName("Jaybird") JAYBIRD,
    @SerialName("Astoria") ASTORIA, @SerialName("Bonskin") BONSKIN, @SerialName("Shareit") SHAREIT, @SerialName("Monttee") MONTTEE,
}

@Serializable
data class SignatureRef(val signatureId: String, val signatureVersion: String, val kind: SignatureKind) {
    init {
        require(signatureId.isNotEmpty()) { "signatureId must not be empty" }
        require(signatureVersion.length == 12 && signatureVersion.all { it in '0'..'9' || it in 'a'..'f' }) { "signatureVersion must be 12 hex digits" }
    }
}

@Serializable
data class WatermarkText(val text: String, val font: WatermarkFont) { init { require(text.length in 1..80) { "watermark text must be 1..80 characters" } } }

@Serializable
data class WatermarkLogo(val image: AssetRef)

@Serializable
data class WatermarkTool(
    val type: WatermarkType,
    val signature: SignatureRef?,
    val text: WatermarkText?,
    val logo: WatermarkLogo?,
    val placement: WatermarkPlacement,
    val position: Int,
    val offset: NormalisedPoint?,
    val size: Double,
    val opacity: Double,
    val colour: String,
) {
    init {
        require((signature != null) == (type == WatermarkType.SIGNATURE) && (text != null) == (type == WatermarkType.TEXT) && (logo != null) == (type == WatermarkType.LOGO)) {
            "exactly the watermark part that matches type is set"
        }
        require(position in 0..8) { "watermark position must be 0..8" }
        require(size in 10.0..80.0) { "watermark size must be in 10..80" }
        requirePercent(opacity, "opacity")
        requireColour(colour)
    }
}

// --- text -------------------------------------------------------------------------------------------

/** The Text tool's layers, drawn in order (the last on top); at most [MAX_LAYERS]. */
@Serializable
data class TextTool(val layers: List<TextLayer>) {
    init {
        require(layers.size <= MAX_LAYERS) { "at most $MAX_LAYERS text layers" }
        require(layers.map { it.id }.toSet().size == layers.size) { "text layer ids must be unique" }
    }

    companion object {
        const val MAX_LAYERS = 20
    }
}

/**
 * The eleven Text fonts (shared/fonts), by the family names the recipe stores. Retro Romance, Velomino and Vectipede Thin
 * were added by the owner on 2026-10-11 (second amendment), after Space Mono. [hasSingleWeight] fonts are drawn in their
 * one weight only, so `textLayer.weight` only takes regular for them (the panel greys Thin and Bold).
 */
@Serializable
enum class TextFont(val family: String, val hasSingleWeight: Boolean = false) {
    @SerialName("Inter") INTER("Inter"),
    @SerialName("Playfair Display") PLAYFAIR_DISPLAY("Playfair Display"),
    @SerialName("Bebas Neue") BEBAS_NEUE("Bebas Neue", hasSingleWeight = true),
    @SerialName("Caveat") CAVEAT("Caveat"),
    @SerialName("Cormorant Garamond") CORMORANT_GARAMOND("Cormorant Garamond"),
    @SerialName("Montserrat") MONTSERRAT("Montserrat"),
    @SerialName("Dancing Script") DANCING_SCRIPT("Dancing Script"),
    @SerialName("Space Mono") SPACE_MONO("Space Mono", hasSingleWeight = true),
    @SerialName("Retro Romance") RETRO_ROMANCE("Retro Romance", hasSingleWeight = true),
    @SerialName("Velomino") VELOMINO("Velomino", hasSingleWeight = true),
    @SerialName("Vectipede Thin") VECTIPEDE_THIN("Vectipede Thin", hasSingleWeight = true),
}

/**
 * `textLayer.weight` (owner amendment 2026-10-11, second): Thin 200, Regular 400, Bold 700 on the font's `wght` axis
 * (rendering-v2 §7.4). Optional on read (a recipe written before it reads as regular) and always written.
 */
@Serializable
enum class TextWeight(val axisValue: Int) {
    @SerialName("thin") THIN(200),
    @SerialName("regular") REGULAR(400),
    @SerialName("bold") BOLD(700),
}

/**
 * One text box (edit-recipe-v1 `textLayer`): [centre] of the text block as fractions of the photo frame (after crop,
 * before border), font size = [size] / 100 × 0.25 × the frame's short edge, [rotation] degrees clockwise about the centre.
 * [id] is stable (8 lowercase hex digits), so the selection survives Undo.
 */
@Serializable
data class TextLayer(
    val id: String,
    val text: String,
    val font: TextFont,
    // Declared after `font` so it is written there, as iOS writes it; the default makes it optional on read, and
    // SessionJson's encodeDefaults always writes it.
    val weight: TextWeight = TextWeight.REGULAR,
    val size: Int,
    val colour: String,
    val opacity: Double,
    val centre: NormalisedPoint,
    val rotation: Double,
) {
    init {
        require(Regex("^[0-9a-f]{8}$").matches(id)) { "text layer id must be 8 lowercase hex digits, was $id" }
        require(text.length in 1..MAX_TEXT_LENGTH) { "text must be 1..$MAX_TEXT_LENGTH characters" }
        require(size in MIN_SIZE..MAX_SIZE) { "text size must be in $MIN_SIZE..$MAX_SIZE" }
        requireColour(colour)
        requirePercent(opacity, "text opacity")
        require(rotation in -180.0..180.0) { "text rotation must be in -180..180" }
    }

    companion object {
        const val MAX_TEXT_LENGTH = 120
        const val MIN_SIZE = 10
        const val MAX_SIZE = 100
    }
}

// --- border -----------------------------------------------------------------------------------------

@Serializable enum class BorderType { @SerialName("none") NONE, @SerialName("solid") SOLID, @SerialName("frame") FRAME, @SerialName("polaroid") POLAROID, @SerialName("paper") PAPER }

@Serializable
@OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
data class BorderTool(val type: BorderType, val colour: String, val width: Double, val spacing: Double, val mat: String, @kotlinx.serialization.EncodeDefault(kotlinx.serialization.EncodeDefault.Mode.NEVER) val paperFinish: String = "deckled", @kotlinx.serialization.EncodeDefault(kotlinx.serialization.EncodeDefault.Mode.NEVER) val texture: Double = 25.0) {
    init {
        requireColour(colour); requireColour(mat)
        require(paperFinish in listOf("clean", "deckled", "torn")); require(texture in 0.0..100.0)
        require(width in 1.0..15.0) { "border width must be in 1..15" }
        require(spacing in 0.0..12.0) { "border spacing must be in 0..12" }
    }
}

// --- array-shaped serializers and checks ------------------------------------------------------------

private val numberList = ListSerializer(CanonicalDoubleSerializer)

/** `[x, y]`. */
object NormalisedPointSerializer : KSerializer<NormalisedPoint> {
    override val descriptor: SerialDescriptor = SerialDescriptor("lightly.Point", numberList.descriptor)
    override fun serialize(encoder: Encoder, value: NormalisedPoint) = encoder.encodeSerializableValue(numberList, listOf(value.x, value.y))
    override fun deserialize(decoder: Decoder): NormalisedPoint {
        val values = decoder.decodeSerializableValue(numberList)
        require(values.size == 2) { "a point is [x, y]" }
        return NormalisedPoint(values[0], values[1])
    }
}

/** `[x, y, w, h]`. */
object NormalisedRectSerializer : KSerializer<NormalisedRect> {
    override val descriptor: SerialDescriptor = SerialDescriptor("lightly.Rect", numberList.descriptor)
    override fun serialize(encoder: Encoder, value: NormalisedRect) = encoder.encodeSerializableValue(numberList, listOf(value.x, value.y, value.width, value.height))
    override fun deserialize(decoder: Decoder): NormalisedRect {
        val values = decoder.decodeSerializableValue(numberList)
        require(values.size == 4) { "a rect is [x, y, w, h]" }
        return NormalisedRect(values[0], values[1], values[2], values[3])
    }
}

/** Tolerance for `x + w <= 1` on values that went through decimal text. */
private const val EPSILON = 1e-9

private fun requireUnit(value: Double, label: String) = require(value in 0.0..1.0) { "$label must be in 0..1, was $value" }
private fun requirePercent(value: Double, label: String) = require(value in 0.0..100.0) { "$label must be in 0..100, was $value" }
private fun requireSlider(value: Double, label: String) = require(value in -100.0..100.0) { "$label must be in -100..100, was $value" }
private fun requireColour(value: String) = require(Regex("^#[0-9A-F]{6}$").matches(value)) { "colour must be #RRGGBB in upper case, was $value" }
private fun requireSha256(value: String) = require(value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }) { "sha256 must be 64 lowercase hex digits" }
