package com.lightlylabs.lightly.develop

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.security.MessageDigest

/**
 * The canonical JSON that `shared/look-pack/build_pack.py` hashes: Python's
 * `json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`.
 *
 * Numbers are written with their ORIGINAL literal text. The pack and the contract were themselves
 * written by Python's json module, so each literal already is Python's `repr` of the value; reformatting
 * it through a Kotlin Double would turn `52` into `52.0` and break every digest.
 */
object CanonicalJson {
    fun encode(element: JsonElement): String = StringBuilder().also { write(element, it) }.toString()

    fun sha256Hex(element: JsonElement): String = sha256Hex(encode(element).toByteArray(Charsets.UTF_8))

    fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private fun write(element: JsonElement, out: StringBuilder) {
        when (element) {
            is JsonNull -> out.append("null")
            is JsonPrimitive -> if (element.isString) writeString(element.content, out) else out.append(element.content)
            is JsonArray -> {
                out.append('[')
                element.forEachIndexed { index, item ->
                    if (index > 0) out.append(',')
                    write(item, out)
                }
                out.append(']')
            }
            is JsonObject -> {
                out.append('{')
                // Python sorts str keys by code point; every key here is ASCII, where UTF-16 order is the same.
                element.keys.sorted().forEachIndexed { index, key ->
                    if (index > 0) out.append(',')
                    writeString(key, out)
                    out.append(':')
                    write(element.getValue(key), out)
                }
                out.append('}')
            }
        }
    }

    /** json.dumps string escaping with ensure_ascii=False: only quotes, backslashes and controls. */
    private fun writeString(value: String, out: StringBuilder) {
        out.append('"')
        for (char in value) {
            when (char) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                else -> if (char < ' ') out.append("\\u%04x".format(char.code)) else out.append(char)
            }
        }
        out.append('"')
    }
}
