@file:UseSerializers(CanonicalDoubleSerializer::class)
@file:OptIn(ExperimentalSerializationApi::class)

package com.lightlylabs.lightly.session

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import kotlinx.serialization.builtins.ListSerializer
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

@Serializable
data class Hair(val definition: Double, val flyaways: Double, val shine: Double) {
    init { listOf(definition, flyaways, shine).forEach { requirePercent(it, "hair") } }
}

@Serializable
data class FaceEdit(val face: FaceIdentity, val skin: Skin, val underEye: UnderEye, val eyes: Eyes, val teeth: Teeth, val hair: Hair)

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

@Serializable enum class LeakStyle { @SerialName("warm") WARM, @SerialName("amber") AMBER, @SerialName("rose") ROSE, @SerialName("prism") PRISM }
@Serializable enum class GrainStyle { @SerialName("fine") FINE, @SerialName("film") FILM, @SerialName("coarse") COARSE }

@Serializable
data class EffectsTool(val lightLeak: LightLeak, val grain: UserGrain, val vignette: UserVignette)

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
@Serializable enum class WatermarkPlacement { @SerialName("photo") PHOTO, @SerialName("border") BORDER }
@Serializable enum class SignatureKind { @SerialName("drawn") DRAWN, @SerialName("imported") IMPORTED }
@Serializable enum class WatermarkFont { @SerialName("Allura") ALLURA, @SerialName("Cormorant Garamond") CORMORANT_GARAMOND, @SerialName("Inter") INTER, @SerialName("Caveat") CAVEAT }

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

// --- border -----------------------------------------------------------------------------------------

@Serializable enum class BorderType { @SerialName("none") NONE, @SerialName("solid") SOLID, @SerialName("frame") FRAME, @SerialName("polaroid") POLAROID }

@Serializable
data class BorderTool(val type: BorderType, val colour: String, val width: Double, val spacing: Double, val mat: String) {
    init {
        requireColour(colour); requireColour(mat)
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
