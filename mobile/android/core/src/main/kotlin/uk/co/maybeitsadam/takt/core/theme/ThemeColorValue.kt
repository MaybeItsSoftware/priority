package uk.co.maybeitsadam.takt.core.theme

import java.util.Locale
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

// Port of Sources/TaktCore/Theming/ThemeColorValue.swift.

/**
 * A colour as a theme states it: sRGB channels and alpha in 0…1, clamped on
 * the way in. Pure data, so the format, the audit and the resolution can be
 * tested without Compose.
 */
class ThemeColorValue(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
    val red: Double = clamped(red)
    val green: Double = clamped(green)
    val blue: Double = clamped(blue)
    val alpha: Double = clamped(alpha)

    /** `#RRGGBB`, or `#RRGGBBAA` when not opaque. Upper case, as Swift writes it. */
    val hexString: String
        get() {
            val base = String.format(Locale.ROOT, "#%02X%02X%02X", byte(red), byte(green), byte(blue))
            return if (alpha < 1) base + String.format(Locale.ROOT, "%02X", byte(alpha)) else base
        }

    /** `0xAARRGGBB`, for Compose's `Color(Int)` and Android's colour ints. */
    val argb: Int
        get() = (byte(alpha) shl 24) or (byte(red) shl 16) or (byte(green) shl 8) or byte(blue)

    fun withAlpha(newAlpha: Double): ThemeColorValue = ThemeColorValue(red, green, blue, newAlpha)

    /** WCAG relative luminance. Alpha is ignored. */
    val relativeLuminance: Double
        get() {
            fun linear(channel: Double) =
                if (channel <= 0.03928) channel / 12.92 else ((channel + 0.055) / 1.055).pow(2.4)
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

    fun contrastRatio(against: ThemeColorValue): Double {
        val first = relativeLuminance
        val second = against.relativeLuminance
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    override fun equals(other: Any?): Boolean = other is ThemeColorValue &&
        red == other.red && green == other.green && blue == other.blue && alpha == other.alpha

    override fun hashCode(): Int = listOf(red, green, blue, alpha).hashCode()

    override fun toString(): String = hexString

    companion object {
        /** Debug magenta: what a role with no value anywhere would paint. */
        val UNRESOLVED = ThemeColorValue(1.0, 0.0, 1.0)

        /** `#rgb`, `#rrggbb` or `#rrggbbaa`, the `#` optional; null for anything else. */
        fun hex(raw: String): ThemeColorValue? {
            val trimmed = raw.trim()
            val digits = trimmed.removePrefix("#").lowercase()
            if (digits.isEmpty() || !digits.all { it in '0'..'9' || it in 'a'..'f' }) return null
            val expanded = when (digits.length) {
                3 -> digits.map { "$it$it" }.joinToString("")
                6, 8 -> digits
                else -> return null
            }
            fun channel(offset: Int) = expanded.substring(offset, offset + 2).toInt(16) / 255.0
            return ThemeColorValue(channel(0), channel(2), channel(4), if (expanded.length == 8) channel(6) else 1.0)
        }

        /** From `0xAARRGGBB`. */
        fun argb(value: Int): ThemeColorValue = ThemeColorValue(
            ((value shr 16) and 0xFF) / 255.0,
            ((value shr 8) and 0xFF) / 255.0,
            (value and 0xFF) / 255.0,
            ((value ushr 24) and 0xFF) / 255.0,
        )

        private fun clamped(value: Double): Double = if (!value.isFinite()) 0.0 else min(max(value, 0.0), 1.0)

        private fun byte(channel: Double): Int = schoolbookRound(channel * 255).toInt()
    }
}

/** Swift's `rounded()`: half away from zero, not Kotlin's half-to-even `round`. */
internal fun schoolbookRound(value: Double): Double {
    if (!value.isFinite()) return value
    // `floor(x + 0.5)` misrounds the double just under a half, whose sum rounds up; the remainder is exact.
    val magnitude = kotlin.math.abs(value)
    val whole = floor(magnitude)
    val rounded = if (magnitude - whole >= 0.5) whole + 1 else whole
    return if (value < 0) -rounded else rounded
}
