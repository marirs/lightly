@file:OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)

package com.lightlylabs.lightly.session

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonUnquotedLiteral
import kotlinx.serialization.json.double
import java.math.BigDecimal

/**
 * Canonical number text for saved edits (shared/fixtures/edit-recipe/README.md): integers without a
 * decimal point (`40`, not `40.0`), other values as Python's shortest `repr` (`0.75`, `1e-05`), so
 * iOS, Android and the Python generator write byte-identical JSON for the same edit.
 *
 * Decoding accepts any JSON number but never a quoted one: `"0.5"` is a string and is rejected.
 */
object CanonicalNumber {
    fun format(value: Double): String {
        require(value.isFinite()) { "Saved edits hold finite numbers only, got $value" }
        if (value == Math.rint(value) && kotlin.math.abs(value) < 1e15) return value.toLong().toString()
        return pythonRepr(value)
    }

    /**
     * Python's float repr: the shortest round-tripping digits (Java's Double.toString finds the same
     * digits), written positionally when the decimal exponent is in [-5, 16), otherwise as `de±XX`.
     */
    internal fun pythonRepr(value: Double): String {
        val decimal = BigDecimal(value.toString()).stripTrailingZeros()
        val digits = decimal.unscaledValue().abs().toString()
        val exponent = digits.length - 1 - decimal.scale() // decimal exponent of the leading digit
        val sign = if (value < 0) "-" else ""
        if (exponent < -4 || exponent >= 16) {
            val mantissa = if (digits.length == 1) digits else digits[0] + "." + digits.substring(1)
            val expSign = if (exponent < 0) "-" else "+"
            return "$sign${mantissa}e$expSign${kotlin.math.abs(exponent).toString().padStart(2, '0')}"
        }
        return sign + decimal.abs().toPlainString()
    }

    fun decode(decoder: Decoder): Double {
        val json = decoder as? JsonDecoder ?: return decoder.decodeDouble()
        val element = json.decodeJsonElement()
        val primitive = element as? JsonPrimitive ?: throw SerializationException("Expected a number, got $element")
        if (primitive.isString) throw SerializationException("Expected a number, got the string \"${primitive.content}\"")
        val value = primitive.double
        if (!value.isFinite()) throw SerializationException("Expected a finite number, got ${primitive.content}")
        return value
    }

    fun encode(encoder: Encoder, value: Double) {
        val json = encoder as? JsonEncoder
        if (json == null) encoder.encodeDouble(value) else json.encodeJsonElement(JsonUnquotedLiteral(format(value)))
    }
}

/** Double property serializer with canonical text; applied file-wide with `@file:UseSerializers`. */
object CanonicalDoubleSerializer : KSerializer<Double> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("lightly.CanonicalDouble", PrimitiveKind.DOUBLE)
    override fun serialize(encoder: Encoder, value: Double) = CanonicalNumber.encode(encoder, value)
    override fun deserialize(decoder: Decoder): Double = CanonicalNumber.decode(decoder)
}

/**
 * Float property serializer with canonical text. The value is written from its own shortest decimal
 * (0.75f → `0.75`, 0.6f → `0.6`), not from its widened double (0.6000000238418579).
 */
object CanonicalFloatSerializer : KSerializer<Float> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("lightly.CanonicalFloat", PrimitiveKind.FLOAT)
    override fun serialize(encoder: Encoder, value: Float) = CanonicalNumber.encode(encoder, value.toString().toDouble())
    override fun deserialize(decoder: Decoder): Float = CanonicalNumber.decode(decoder).toFloat()
}
