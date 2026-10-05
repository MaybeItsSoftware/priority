package uk.co.maybeitsadam.takt.core.theme

// Port of Sources/TaktCore/Theming/ThemeSeeds.swift.

/**
 * The few colours a whole palette can be grown from.
 *
 * A theme can give `seeds` instead of all 21 roles twice: a background, a
 * foreground and an accent per appearance, and optionally the three status
 * colours. The eleven neutrals are mixed from them by fixed proportions. Any
 * role the theme also states in `palette` wins over the derived one.
 *
 * The arithmetic is part of the format, and `shared/themes/conformance/`
 * holds this port to Swift's answers. Channels are 0–255 integers, and a mix
 * is `round(a + (b − a) × t)`, computed in that order in doubles and rounded
 * half away from zero.
 */
data class ThemeSeeds(
    val background: ThemeColorValue? = null,
    val foreground: ThemeColorValue? = null,
    val accent: ThemeColorValue? = null,
    val success: ThemeColorValue? = null,
    val danger: ThemeColorValue? = null,
    val warning: ThemeColorValue? = null,
) {
    /** Declaration order is the Swift `allCases` order. */
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
        val background = background ?: return null
        val foreground = foreground ?: return null
        val roles = LinkedHashMap<ThemeColorRole, ThemeColorValue>()
        roles[ThemeColorRole.PAPER] = background
        roles[ThemeColorRole.INK] = foreground
        for ((role, step) in NEUTRAL_STEPS) roles[role] = mix(background, foreground, step)
        roles[ThemeColorRole.RAISED] = if (appearance == ThemeAppearance.LIGHT) {
            mix(background, ThemeColorValue(1.0, 1.0, 1.0), 0.6)
        } else {
            mix(background, foreground, 0.04)
        }
        accent?.let { roles[ThemeColorRole.PRIMARY] = it }
        success?.let { roles[ThemeColorRole.SUCCESS] = it }
        danger?.let { roles[ThemeColorRole.DANGER] = it }
        warning?.let { roles[ThemeColorRole.WARNING] = it }
        return roles
    }

    companion object {
        /**
         * How far from the background towards the foreground each neutral
         * sits. The page is 0 and the text is 1.
         */
        val NEUTRAL_STEPS: List<Pair<ThemeColorRole, Double>> = listOf(
            ThemeColorRole.ALT_ROW to 0.025,
            ThemeColorRole.HOVER to 0.05,
            ThemeColorRole.WELL to 0.07,
            ThemeColorRole.BORDER_MUTED to 0.07,
            ThemeColorRole.BORDER to 0.12,
            ThemeColorRole.INPUT_BORDER to 0.2,
            ThemeColorRole.DIM_TEXT to 0.38,
            ThemeColorRole.MUTED_TEXT to 0.75,
        )

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

        /**
         * [a] moved [t] of the way to [b], per channel, on whole 0–255 steps.
         * The result is opaque.
         */
        fun mix(a: ThemeColorValue, b: ThemeColorValue, t: Double): ThemeColorValue {
            fun channel(from: Double, to: Double): Double {
                val start = schoolbookRound(from * 255)
                val end = schoolbookRound(to * 255)
                return schoolbookRound(start + (end - start) * t) / 255
            }
            return ThemeColorValue(channel(a.red, b.red), channel(a.green, b.green), channel(a.blue, b.blue))
        }
    }
}
