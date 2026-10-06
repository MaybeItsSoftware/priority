package uk.co.maybeitsadam.takt.core.theme

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

// Port of Sources/TaktCore/Theming/ThemeTypographyOverride.swift.

/**
 * The reader's own type choices, laid over whichever theme is in force.
 *
 * A theme says what the faces and sizes are; this says "but set the body in
 * Inter, and a size up". It is kept apart from the theme so that switching
 * theme keeps the choices, and clearing it ("Reset to theme") hands every
 * role back to the theme without touching the theme's file.
 *
 * It is applied through [ThemeFileLoader.merge], the same overlay a theme
 * file's own `structure` goes through, so a family chosen here resolves
 * exactly the way a family named in a theme file would: tried first, with
 * the theme's own families and design behind it.
 *
 * Stored as JSON with the Mac's keys (`bodyFamily`, `displayFamily`,
 * `monoFamily`, `textScale`), per device as on the Mac.
 */
@Serializable
data class ThemeTypographyOverride(
    /** Interface text: rows, fields, captions, micro-labels. */
    val bodyFamily: String? = null,
    /** Headings and pane titles. */
    val displayFamily: String? = null,
    /** Numerals, key caps, code and the clock. */
    val monoFamily: String? = null,
    /**
     * A multiplier on the theme's body size and every step of its type scale,
     * so the theme's proportions survive. Null or 1 leaves sizes alone.
     */
    val textScale: Double? = null,
) {
    /** The text size actually applied: clamped, and 1 when unset. */
    val effectiveTextScale: Double
        get() {
            val scale = textScale ?: return 1.0
            if (!scale.isFinite()) return 1.0
            return scale.coerceIn(TEXT_SCALE_MIN, TEXT_SCALE_MAX)
        }

    /** True when nothing is overridden, so the theme renders as it ships. */
    val isEmpty: Boolean
        get() = cleaned(bodyFamily) == null && cleaned(displayFamily) == null &&
            cleaned(monoFamily) == null && effectiveTextScale == 1.0

    /** The override as the partial structure a theme file would state; null when empty. */
    fun structureOverlay(base: ThemeTypography): ThemeFile.Structure? {
        if (isEmpty) return null
        fun face(family: String?, baseFace: ThemeFontFace): ThemeFile.Face? {
            val chosen = cleaned(family) ?: return null
            // The choice first, then the theme's own request behind it, so a
            // face that is not available falls back to the theme's rather
            // than to the system's.
            return ThemeFile.Face(listOf(chosen) + baseFace.families.filter { it != chosen }, baseFace.design.raw)
        }
        val factor = effectiveTextScale
        var bodySize: Double? = null
        var scale: ThemeFile.TypeScale? = null
        var microLabel: ThemeFile.MicroLabel? = null
        if (factor != 1.0) {
            fun scaled(value: Double) = schoolbookRound(value * factor * 2) / 2
            bodySize = scaled(base.bodySize)
            scale = ThemeFile.TypeScale(
                caption = scaled(base.scale.caption),
                body = scaled(base.scale.body),
                title = scaled(base.scale.title),
                display = scaled(base.scale.display),
                hero = scaled(base.scale.hero),
            )
            microLabel = ThemeFile.MicroLabel(size = scaled(base.microLabel.size))
        }
        return ThemeFile.Structure(
            typography = ThemeFile.Typography(
                display = face(displayFamily, base.display),
                body = face(bodyFamily, base.body),
                mono = face(monoFamily, base.mono),
                bodySize = bodySize,
                scale = scale,
                microLabel = microLabel,
            ),
        )
    }

    /**
     * [specification] with these choices laid over its typography. Everything
     * else (identity, palette, radii, spacing) is the theme's.
     */
    fun applied(specification: ThemeSpecification): ThemeSpecification {
        val overlay = structureOverlay(specification.structure.typography) ?: return specification
        return specification.copy(structure = ThemeFileLoader.merge(overlay, specification.structure))
    }

    /** This override as the JSON it is stored as. */
    fun toJson(): String = json.encodeToString(serializer(), this)

    /** A copy with [role]'s family set, or cleared with null. */
    fun withFamily(role: ThemeFontRole, family: String?): ThemeTypographyOverride = when (role) {
        ThemeFontRole.BODY -> copy(bodyFamily = family)
        ThemeFontRole.DISPLAY -> copy(displayFamily = family)
        ThemeFontRole.MONO -> copy(monoFamily = family)
    }

    fun family(role: ThemeFontRole): String? = when (role) {
        ThemeFontRole.BODY -> bodyFamily
        ThemeFontRole.DISPLAY -> displayFamily
        ThemeFontRole.MONO -> monoFamily
    }

    companion object {
        /** Below this captions stop being legible; above it fixed-width columns stop fitting. */
        const val TEXT_SCALE_MIN = 0.85
        const val TEXT_SCALE_MAX = 1.3

        /** The steps the text size control offers, as on the Mac. */
        val TEXT_SCALES = listOf(0.85, 0.9, 1.0, 1.1, 1.2, 1.3)

        private val json = Json {
            ignoreUnknownKeys = true
            explicitNulls = false
        }

        /** The stored override; an empty one for missing or unreadable text. */
        fun fromJson(text: String?): ThemeTypographyOverride {
            if (text.isNullOrBlank()) return ThemeTypographyOverride()
            return runCatching { json.decodeFromString(serializer(), text) }.getOrNull() ?: ThemeTypographyOverride()
        }

        /** The offered step nearest [value]. */
        fun nearestTextScale(value: Double): Double = TEXT_SCALES.minBy { kotlin.math.abs(it - value) }

        private fun cleaned(family: String?): String? = family?.trim()?.takeIf { it.isNotEmpty() }
    }
}

/** Which face a font control sets. */
enum class ThemeFontRole(val title: String, val detail: String) {
    BODY("Interface", "Rows, fields, captions and labels."),
    DISPLAY("Headings", "Pane titles and headings."),
    MONO("Numerals and code", "The clock, estimates, key caps and code."),
    ;

    fun face(typography: ThemeTypography): ThemeFontFace = when (this) {
        BODY -> typography.body
        DISPLAY -> typography.display
        MONO -> typography.mono
    }
}

/** A family the apps ship, so choosing it looks the same on every device. */
data class BundledFontFamily(
    val name: String,
    val design: ThemeFontDesign,
    /** One line on what it is for, shown beside its preview. */
    val note: String,
) {
    companion object {
        /** Every bundled family, in the order a picker lists them: sans, serif, then monospaced. As on the Mac. */
        val all: List<BundledFontFamily> = listOf(
            BundledFontFamily("IBM Plex Sans", ThemeFontDesign.SANS, "Zed's interface face; humanist and compact"),
            BundledFontFamily("Inter", ThemeFontDesign.SANS, "Neutral screen sans with tabular figures"),
            BundledFontFamily("Geist", ThemeFontDesign.SANS, "Geometric and crisp at small sizes"),
            BundledFontFamily("Arvo", ThemeFontDesign.SERIF, "Slab serif; the Grape house face"),
            BundledFontFamily("Lilex", ThemeFontDesign.MONOSPACED, "Zed's monospace, with ligatures"),
            BundledFontFamily("JetBrains Mono", ThemeFontDesign.MONOSPACED, "Tall x-height code face"),
            BundledFontFamily("Geist Mono", ThemeFontDesign.MONOSPACED, "Geist's monospaced companion"),
        )

        fun named(name: String): BundledFontFamily? = all.firstOrNull { it.name == name }

        /** The bundled families in the order a picker for [role] offers them: those suited to it first. */
        fun ordered(role: ThemeFontRole): List<BundledFontFamily> {
            val preferred = all.filter { (it.design == ThemeFontDesign.MONOSPACED) == (role == ThemeFontRole.MONO) }
            return preferred + all.filterNot { it in preferred }
        }
    }
}
