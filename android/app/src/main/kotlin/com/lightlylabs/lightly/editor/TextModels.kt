package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.session.NormalisedPoint
import com.lightlylabs.lightly.session.TextFont
import com.lightlylabs.lightly.session.TextLayer
import com.lightlylabs.lightly.session.TextTool
import com.lightlylabs.lightly.session.TextWeight
import kotlin.math.roundToInt
import kotlin.random.Random

/** What the text sheet ("Cancel · Text · Done") is open for: a new layer, or editing an existing layer's text. */
sealed interface TextSheet {
    data object Adding : TextSheet
    data class Editing(val layerId: String) : TextSheet
}

/**
 * Text tool UI state (owner amendment 2026-10-11). Never in history: the selection is by layer id, so it survives Undo
 * while the layer exists; a missing id simply selects nothing.
 */
data class TextUi(
    val selectedId: String? = null,
    val sheet: TextSheet? = null,
    /** The slider being dragged and its value (preview only until release). */
    val sliderDrag: Pair<String, Double>? = null,
    /**
     * A gesture on the photo (move, corner handle, pinch) and its commit until the preview shows it: the photo is rendered
     * without this layer and the Text marks draw it live over the photo instead (owner report 2026-10-11: resizing with the
     * handle was not smooth while every move event re-rendered the photo).
     */
    val liveLayerId: String? = null,
    /** After the gesture: the committed layer, drawn by the marks until the preview that contains it is shown. */
    val settlingLayer: TextLayer? = null,
)

/**
 * A text under a finger: [layer] is what the gesture commits (the recipe stores whole-number sizes), [exactSize] the size
 * following the finger without those steps, which the live drawing, outline and handles use while the finger is down.
 */
data class TextDraft(val layer: TextLayer, val exactSize: Double) {
    companion object {
        fun of(layer: TextLayer) = TextDraft(layer, layer.size.toDouble())
    }
}

/** The approved Text panel copy and the new layer's defaults (Lightly 2 `textPanel`, `tx-*` screens). */
object TextOptions {
    const val ADD_TEXT = "Add text"
    const val ADD = "Add"
    const val EMPTY_NOTE = "Add text, then drag it anywhere on the photo. Pinch to resize or turn it."
    const val SHEET_TITLE = "Text"

    /** The fonts row, in the mockup's `TEXT_FONTS` order (the enum's order): eleven since 2026-10-11 (second amendment). */
    val FONTS: List<TextFont> = TextFont.entries

    /** The weight row (mockup `weights`): each label is drawn at its own weight. */
    val WEIGHTS: List<Pair<TextWeight, String>> = listOf(TextWeight.THIN to "Thin", TextWeight.REGULAR to "Regular", TextWeight.BOLD to "Bold")

    val DEFAULT_FONT = TextFont.PLAYFAIR_DISPLAY
    const val DEFAULT_SIZE = 42
    const val DEFAULT_COLOUR = "#FFFFFF"
    const val DEFAULT_OPACITY = 100.0
}

/** Pure changes to the recipe's text layers; every finished change is one commit (one undo step) in the view model. */
object TextEdits {
    /** A new layer as Done adds it: centred, size 42, Playfair Display, white, fully opaque, unturned. */
    fun newLayer(id: String, text: String) = TextLayer(
        id = id, text = text, font = TextOptions.DEFAULT_FONT, size = TextOptions.DEFAULT_SIZE, colour = TextOptions.DEFAULT_COLOUR,
        opacity = TextOptions.DEFAULT_OPACITY, centre = NormalisedPoint(0.5, 0.5), rotation = 0.0,
    )

    /** A random 8-digit lowercase hex id that no existing layer uses. */
    fun newId(existing: Collection<String>, random: Random = Random.Default): String {
        while (true) {
            val id = "%08x".format(random.nextInt())
            if (id !in existing) return id
        }
    }

    fun canAdd(tool: TextTool) = tool.layers.size < TextTool.MAX_LAYERS

    fun added(tool: TextTool, layer: TextLayer): TextTool = if (canAdd(tool)) TextTool(tool.layers + layer) else tool

    fun replaced(tool: TextTool, layer: TextLayer): TextTool = TextTool(tool.layers.map { if (it.id == layer.id) layer else it })

    fun removed(tool: TextTool, id: String): TextTool = TextTool(tool.layers.filterNot { it.id == id })

    /** The sheet's text as stored: at most 120 characters; null when blank (Done is disabled then). */
    fun acceptedText(typed: String): String? = typed.take(TextLayer.MAX_TEXT_LENGTH).takeIf { it.isNotBlank() }

    /** Whether [font] has [weight]: every font has regular; a single-weight font has nothing else (the row greys it). */
    fun isWeightAvailable(weight: TextWeight, font: TextFont): Boolean = weight == TextWeight.REGULAR || !font.hasSingleWeight

    /** The layer in [font]; a single-weight font only takes regular, so a thin or bold layer becomes regular with it. */
    fun withFont(layer: TextLayer, font: TextFont): TextLayer =
        layer.copy(font = font, weight = if (isWeightAvailable(layer.weight, font)) layer.weight else TextWeight.REGULAR)

    /** The layer at [weight]; unchanged when its font does not have that weight (a greyed, disabled segment). */
    fun withWeight(layer: TextLayer, weight: TextWeight): TextLayer =
        if (isWeightAvailable(weight, layer.font)) layer.copy(weight = weight) else layer

    /** Size (10…100, whole numbers) and Opacity (0…100) from their sliders. */
    fun withSlider(layer: TextLayer, field: String, value: Double): TextLayer = when (field) {
        "size" -> layer.copy(size = value.roundToInt().coerceIn(TextLayer.MIN_SIZE, TextLayer.MAX_SIZE))
        "opacity" -> layer.copy(opacity = value.coerceIn(0.0, 100.0))
        else -> layer
    }

    /** The layer moved by a fraction of the frame; its centre stays inside the frame (0…1). */
    fun moved(layer: TextLayer, dx: Double, dy: Double): TextLayer =
        layer.copy(centre = NormalisedPoint((layer.centre.x + dx).coerceIn(0.0, 1.0), (layer.centre.y + dy).coerceIn(0.0, 1.0)))

    /** The layer resized by [scale] and turned by [degrees] clockwise about its centre (corner handle, two-finger pinch). */
    fun scaledAndTurned(layer: TextLayer, scale: Double, degrees: Double): TextLayer = layer.copy(
        size = (layer.size * scale).roundToInt().coerceIn(TextLayer.MIN_SIZE, TextLayer.MAX_SIZE),
        rotation = normalisedDegrees(layer.rotation + degrees),
    )

    /**
     * [start] moved by a fraction of the frame, resized by [scale] and turned by [degrees] clockwise about its centre, as
     * one draft: the exact size is kept in range but not rounded, so the text grows smoothly under the finger.
     */
    fun drafted(start: TextLayer, dx: Double, dy: Double, scale: Double, degrees: Double): TextDraft {
        val exactSize = (start.size * scale).coerceIn(TextLayer.MIN_SIZE.toDouble(), TextLayer.MAX_SIZE.toDouble())
        val layer = moved(start, dx, dy).copy(
            size = exactSize.roundToInt().coerceIn(TextLayer.MIN_SIZE, TextLayer.MAX_SIZE),
            rotation = normalisedDegrees(start.rotation + degrees),
        )
        return TextDraft(layer, exactSize)
    }

    /** An angle in (−180, 180], the recipe's range. */
    fun normalisedDegrees(degrees: Double): Double {
        var d = degrees % 360.0
        if (d > 180.0) d -= 360.0
        if (d <= -180.0) d += 360.0
        return d
    }
}
