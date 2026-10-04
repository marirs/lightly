package com.lightlylabs.lightly.editor

import com.lightlylabs.lightly.session.Eyes
import com.lightlylabs.lightly.session.FaceEdit
import com.lightlylabs.lightly.session.FaceIdentity
import com.lightlylabs.lightly.session.Hair
import com.lightlylabs.lightly.session.NormalisedRect
import com.lightlylabs.lightly.session.PortraitTool
import com.lightlylabs.lightly.session.Skin
import com.lightlylabs.lightly.session.Teeth
import com.lightlylabs.lightly.session.UnderEye
import com.lightlylabs.lightly.vision.DetectedFace

/** Prototype `portraitPanel` tabs, in order, with their approved labels. */
enum class PortraitTab(val label: String) { SKIN("Skin"), UNDER("Under-eye"), EYES("Eyes"), TEETH("Teeth"), HAIR("Hair & Beard") }

/**
 * Portrait UI state: the tab (prototype `ui.sub`, reset when the tool changes) and the chosen face
 * (prototype `s.face`: one face is selected automatically, and the choice stays with the photo).
 */
data class PortraitUi(
    val tab: PortraitTab = PortraitTab.SKIN,
    val selectedFace: Int = 0,
    /** The slider being dragged and its value (preview only until release). */
    val sliderDrag: Pair<String, Double>? = null,
)

/** One Portrait slider: its approved label, recipe field and the note that follows the tab's sliders. */
data class PortraitSlider(val label: String, val field: String)

object PortraitOptions {
    /** Prototype `portraitPanel` bodies, verbatim. */
    fun sliders(tab: PortraitTab): List<PortraitSlider> = when (tab) {
        PortraitTab.SKIN -> listOf(PortraitSlider("Smoothing", "skin.smoothing"), PortraitSlider("Blemishes", "skin.blemishes"),
            PortraitSlider("Even tone", "skin.evenTone"), PortraitSlider("Keep texture", "skin.keepTexture"))
        PortraitTab.UNDER -> listOf(PortraitSlider("Brighten", "underEye.brighten"), PortraitSlider("Soften lines", "underEye.softenLines"))
        PortraitTab.EYES -> listOf(PortraitSlider("Brighten", "eyes.brighten"), PortraitSlider("Clarity", "eyes.clarity"))
        PortraitTab.TEETH -> listOf(PortraitSlider("Brighten", "teeth.brighten"))
        PortraitTab.HAIR -> listOf(PortraitSlider("Definition", "hair.definition"), PortraitSlider("Flyaways", "hair.flyaways"), PortraitSlider("Shine", "hair.shine"))
    }

    fun note(tab: PortraitTab): String? = when (tab) {
        PortraitTab.SKIN -> "Blemish reduction is temporary marks only. Pores, freckles, moles and skin tone colour stay."
        PortraitTab.EYES -> "Eye colour and shape are never changed."
        PortraitTab.TEETH -> "Stays within a natural range. There is no automatic whitening."
        else -> null
    }

    const val KEEP_TEXTURE_DEFAULT = 85.0
}

/** The recipe's per-face Portrait entries (iOS `PortraitPanelModel`). */
object PortraitEdits {
    /** A face's entry is matched by its box and detector (edit recipe v1 `faceEdit.face`). */
    fun matches(edit: FaceEdit, face: DetectedFace) = edit.face.box == face.box && edit.face.detector == DetectedFace.DETECTOR

    fun neutral(box: NormalisedRect) = FaceEdit(
        FaceIdentity(box, DetectedFace.DETECTOR), Skin(0.0, 0.0, 0.0, PortraitOptions.KEEP_TEXTURE_DEFAULT), UnderEye(0.0, 0.0), Eyes(0.0, 0.0), Teeth(0.0), Hair(0.0, 0.0, 0.0),
    )

    fun editFor(tool: PortraitTool, face: DetectedFace): FaceEdit = tool.faces.firstOrNull { matches(it, face) } ?: neutral(face.box)

    /** Prototype `countChanges`: settings away from their defaults (Keep texture's default is 85). */
    fun changeCount(e: FaceEdit): Int {
        val values = listOf(e.skin.smoothing, e.skin.blemishes, e.skin.evenTone, e.underEye.brighten, e.underEye.softenLines, e.eyes.brighten,
            e.eyes.clarity, e.teeth.brighten, e.hair.definition, e.hair.flyaways, e.hair.shine)
        return values.count { it != 0.0 } + if (e.skin.keepTexture != PortraitOptions.KEEP_TEXTURE_DEFAULT) 1 else 0
    }

    fun value(e: FaceEdit, field: String): Double = when (field) {
        "skin.smoothing" -> e.skin.smoothing
        "skin.blemishes" -> e.skin.blemishes
        "skin.evenTone" -> e.skin.evenTone
        "skin.keepTexture" -> e.skin.keepTexture
        "underEye.brighten" -> e.underEye.brighten
        "underEye.softenLines" -> e.underEye.softenLines
        "eyes.brighten" -> e.eyes.brighten
        "eyes.clarity" -> e.eyes.clarity
        "teeth.brighten" -> e.teeth.brighten
        "hair.definition" -> e.hair.definition
        "hair.flyaways" -> e.hair.flyaways
        "hair.shine" -> e.hair.shine
        else -> throw IllegalArgumentException("unknown Portrait field $field")
    }

    fun with(e: FaceEdit, field: String, raw: Double): FaceEdit {
        val v = raw.coerceIn(0.0, 100.0)
        return when (field) {
            "skin.smoothing" -> e.copy(skin = e.skin.copy(smoothing = v))
            "skin.blemishes" -> e.copy(skin = e.skin.copy(blemishes = v))
            "skin.evenTone" -> e.copy(skin = e.skin.copy(evenTone = v))
            "skin.keepTexture" -> e.copy(skin = e.skin.copy(keepTexture = v))
            "underEye.brighten" -> e.copy(underEye = e.underEye.copy(brighten = v))
            "underEye.softenLines" -> e.copy(underEye = e.underEye.copy(softenLines = v))
            "eyes.brighten" -> e.copy(eyes = e.eyes.copy(brighten = v))
            "eyes.clarity" -> e.copy(eyes = e.eyes.copy(clarity = v))
            "teeth.brighten" -> e.copy(teeth = e.teeth.copy(brighten = v))
            "hair.definition" -> e.copy(hair = e.hair.copy(definition = v))
            "hair.flyaways" -> e.copy(hair = e.hair.copy(flyaways = v))
            "hair.shine" -> e.copy(hair = e.hair.copy(shine = v))
            else -> throw IllegalArgumentException("unknown Portrait field $field")
        }
    }

    /** The tool with [face]'s entry changed (added on its first change). The schema allows 16 faces. */
    fun updated(tool: PortraitTool, face: DetectedFace, change: (FaceEdit) -> FaceEdit): PortraitTool {
        val index = tool.faces.indexOfFirst { matches(it, face) }
        return if (index >= 0) PortraitTool(tool.faces.toMutableList().also { it[index] = change(it[index]) })
        else if (tool.faces.size < 16) PortraitTool(tool.faces + change(neutral(face.box)))
        else tool
    }
}
