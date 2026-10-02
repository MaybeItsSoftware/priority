package uk.co.maybeitsadam.priority.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color

/**
 * Every colour role a theme can set, as `docs/themes.md` names them. Chalk is
 * the default; an imported theme overrides any subset, light and dark apart.
 */
@Immutable
data class ChalkPalette(
    val paper: Color,
    val raised: Color,
    val altRow: Color,
    val hover: Color,
    val well: Color,
    val border: Color,
    val borderMuted: Color,
    val inputBorder: Color,
    val ink: Color,
    val mutedText: Color,
    val dimText: Color,
    val primary: Color,
    val success: Color,
    val danger: Color,
    val warning: Color,
    val categoricalPurple: Color,
    val categoricalPink: Color,
    val categoricalOrange: Color,
    val isDark: Boolean,
) {
    /** Text drawn on a filled accent (primary buttons, the running block). */
    val onAccent: Color get() = Color.White

    /** The role by its docs/themes.md key, for the theme importer. */
    fun with(role: String, color: Color): ChalkPalette = when (role) {
        "paper" -> copy(paper = color)
        "raised" -> copy(raised = color)
        "altRow" -> copy(altRow = color)
        "hover" -> copy(hover = color)
        "well" -> copy(well = color)
        "border" -> copy(border = color)
        "borderMuted" -> copy(borderMuted = color)
        "inputBorder" -> copy(inputBorder = color)
        "ink" -> copy(ink = color)
        "mutedText" -> copy(mutedText = color)
        "dimText" -> copy(dimText = color)
        "primary" -> copy(primary = color)
        "success" -> copy(success = color)
        "danger" -> copy(danger = color)
        "warning" -> copy(warning = color)
        "categoricalPurple" -> copy(categoricalPurple = color)
        "categoricalPink" -> copy(categoricalPink = color)
        "categoricalOrange" -> copy(categoricalOrange = color)
        else -> this
    }

    companion object {
        val ChalkLight = ChalkPalette(
            paper = Color(0xFFFAF8F4),
            raised = Color(0xFFFFFFFF),
            altRow = Color(0xFFF5F3F1),
            hover = Color(0xFFF1EFF1),
            well = Color(0xFFEDEBEF),
            border = Color(0xFFE6E4EA),
            borderMuted = Color(0xFFEFEDF2),
            inputBorder = Color(0xFFD8D5DD),
            ink = Color(0xFF444054),
            mutedText = Color(0xFF6E6B7C),
            dimText = Color(0xFFB6B3BF),
            primary = Color(0xFF007FFF),
            success = Color(0xFF4CC38E),
            danger = Color(0xFFD62246),
            warning = Color(0xFFFFBF00),
            categoricalPurple = Color(0xFF7A4DE8),
            categoricalPink = Color(0xFFFF88DC),
            categoricalOrange = Color(0xFFFF6B2B),
            isDark = false,
        )

        val ChalkDark = ChalkPalette(
            paper = Color(0xFF1C1A23),
            raised = Color(0xFF25232F),
            altRow = Color(0xFF211F29),
            hover = Color(0xFF2D2B38),
            well = Color(0xFF2D2B38),
            border = Color(0xFF34313F),
            borderMuted = Color(0xFF2D2B38),
            inputBorder = Color(0xFF403D4D),
            ink = Color(0xFFF5F4F7),
            mutedText = Color(0xFFB6B3BF),
            dimText = Color(0xFF6E6B7C),
            primary = Color(0xFF007FFF),
            success = Color(0xFF4CC38E),
            danger = Color(0xFFD62246),
            warning = Color(0xFFFFBF00),
            categoricalPurple = Color(0xFF7A4DE8),
            categoricalPink = Color(0xFFFF88DC),
            categoricalOrange = Color(0xFFFF6B2B),
            isDark = true,
        )

        /** The colours a list can carry, in picker order. */
        val listColors: List<Pair<String, String>> = listOf(
            "Azure" to "#007fff", "Emerald" to "#4cc38e", "Raspberry" to "#d62246", "Amber" to "#ffbf00",
            "Purple" to "#7a4de8", "Pink" to "#ff88dc", "Orange" to "#ff6b2b", "Grape" to "#444054",
        )
    }
}

/** `#rrggbb` or `#rrggbbaa`; null for anything else. */
fun parseHexColor(hex: String?): Color? {
    val body = hex?.trim()?.removePrefix("#") ?: return null
    if (body.length != 6 && body.length != 8) return null
    val value = body.toLongOrNull(16) ?: return null
    return if (body.length == 6) {
        Color(0xFF000000 or value)
    } else {
        val rgb = value shr 8
        val alpha = value and 0xFF
        Color((alpha shl 24) or rgb)
    }
}
