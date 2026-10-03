package com.lightlylabs.lightly.prefs

import org.json.JSONObject

/** One heading plus its paragraphs. */
data class TextSection(val heading: String, val body: String)

data class ReleaseDocument(val sections: List<TextSection>)

/**
 * Privacy Policy, Terms of Use and the Support destination (dependency D2 in docs/v1/plan.md).
 *
 * The text is loaded from `assets/legal/release-text.json`, which is deliberately EMPTY until the
 * product owner supplies the release text. An empty or absent file means every document is
 * unavailable and the screens say so neutrally. Nothing here may ever be filled with invented or
 * placeholder text.
 *
 * Format, once supplied:
 * ```
 * { "privacyPolicy": { "sections": [ { "heading": "…", "body": "…" } ] },
 *   "termsOfUse":    { "sections": [ … ] },
 *   "supportDestination": "mailto:… or https://…" }
 * ```
 */
data class ReleaseText(
    val privacyPolicy: ReleaseDocument? = null,
    val termsOfUse: ReleaseDocument? = null,
    val supportDestination: String? = null,
) {
    companion object {
        const val ASSET_PATH = "legal/release-text.json"
        const val UNAVAILABLE_DOCUMENT = "This document isn’t available in this build."
        const val UNAVAILABLE_SUPPORT = "Support isn’t available in this build."

        val NONE = ReleaseText()

        /** Blank input is the expected pre-release state, not an error. */
        fun parse(json: String?): ReleaseText {
            if (json.isNullOrBlank()) return NONE
            val root = JSONObject(json)
            return ReleaseText(
                privacyPolicy = root.optJSONObject("privacyPolicy")?.toDocument(),
                termsOfUse = root.optJSONObject("termsOfUse")?.toDocument(),
                supportDestination = root.optString("supportDestination").takeIf { it.isNotBlank() },
            )
        }

        private fun JSONObject.toDocument(): ReleaseDocument? {
            val sections = optJSONArray("sections") ?: return null
            val parsed = (0 until sections.length()).map { index ->
                val section = sections.getJSONObject(index)
                TextSection(section.optString("heading"), section.optString("body"))
            }.filter { it.body.isNotBlank() }
            return ReleaseDocument(parsed).takeIf { parsed.isNotEmpty() }
        }
    }
}
