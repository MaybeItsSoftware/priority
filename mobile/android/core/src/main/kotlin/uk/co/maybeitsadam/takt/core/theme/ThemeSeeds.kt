package uk.co.maybeitsadam.takt.core.theme

import uniffi.takt_core.CoreThemeSeeds
import uniffi.takt_core.themeMix
import uniffi.takt_core.themeSeedRoles

// The arithmetic is the Rust core's (core/src/theme/seeds.rs); this is its type.

/**
 * The few colours a whole palette can be grown from.
 *
 * A theme can give `seeds` instead of all 21 roles twice: a background, a
 * foreground and an accent per appearance, and optionally the three status
 * colours. The eleven neutrals are mixed from them by fixed proportions. Any
 * role the theme also states in `palette` wins over the derived one.
 *
 * The arithmetic is part of the format and lives in the core, so every
 * client grows the same palette. Channels are 0–255 integers, and a mix is
 * `round(a + (b − a) × t)`, rounded half away from zero.
 */
data class ThemeSeeds(
    val background: ThemeColorValue? = null,
    val foreground: ThemeColorValue? = null,
    val accent: ThemeColorValue? = null,
    val success: ThemeColorValue? = null,
    val danger: ThemeColorValue? = null,
    val warning: ThemeColorValue? = null,
) {
    /** Declaration order is the format's order. */
    enum class Key(val raw: String) {
        BACKGROUND("background"),
        FOREGROUND("foreground"),
        ACCENT("accent"),
        SUCCESS("success"),
        DANGER("danger"),
        WARNING("warning");

        companion object {
            fun of(raw: String?): Key? = entries.firstOrNull { it.raw == raw }
        }
    }

    operator fun get(key: Key): ThemeColorValue? = when (key) {
        Key.BACKGROUND -> background
        Key.FOREGROUND -> foreground
        Key.ACCENT -> accent
        Key.SUCCESS -> success
        Key.DANGER -> danger
        Key.WARNING -> warning
    }

    /** A copy with [key] set to [value]. */
    fun with(key: Key, value: ThemeColorValue?): ThemeSeeds = when (key) {
        Key.BACKGROUND -> copy(background = value)
        Key.FOREGROUND -> copy(foreground = value)
        Key.ACCENT -> copy(accent = value)
        Key.SUCCESS -> copy(success = value)
        Key.DANGER -> copy(danger = value)
        Key.WARNING -> copy(warning = value)
    }

    /** `this`, with every seed [overrides] states laid over it. */
    fun overlaid(overrides: ThemeSeeds): ThemeSeeds {
        var merged = this
        for (key in Key.entries) overrides[key]?.let { merged = merged.with(key, it) }
        return merged
    }

    /**
     * The roles these seeds paint in [appearance], or null without both a
     * background and a foreground — there is nothing to mix between.
     *
     * `raised` is the one neutral that does not head towards the text: a card
     * sits above the page, which in the light is whiter and in the dark is a
     * step lighter.
     */
    fun roles(appearance: ThemeAppearance): Map<ThemeColorRole, ThemeColorValue>? {
        val seeds = CoreThemeSeeds(
            background?.core, foreground?.core, accent?.core, success?.core, danger?.core, warning?.core,
        )
        return themeSeedRoles(seeds, appearance.core)?.entries
            ?.mapNotNull { (key, value) -> ThemeColorRole.of(key)?.let { it to ThemeColorValue.of(value) } }
            ?.sortedBy { it.first.ordinal }
            ?.toMap(LinkedHashMap())
    }

    companion object {
        /**
         * The seeds a resolved table already implies: its page, its ink, its
         * primary and its status colours. A file's seeds are laid over these.
         */
        fun implicitIn(table: Map<ThemeColorRole, ThemeColorValue>): ThemeSeeds = ThemeSeeds(
            background = table[ThemeColorRole.PAPER],
            foreground = table[ThemeColorRole.INK],
            accent = table[ThemeColorRole.PRIMARY],
            success = table[ThemeColorRole.SUCCESS],
            danger = table[ThemeColorRole.DANGER],
            warning = table[ThemeColorRole.WARNING],
        )

        /** [a] moved [t] of the way to [b], per channel, on whole 0–255 steps. The result is opaque. */
        fun mix(a: ThemeColorValue, b: ThemeColorValue, t: Double): ThemeColorValue =
            ThemeColorValue.of(themeMix(a.core, b.core, t))
    }
}
