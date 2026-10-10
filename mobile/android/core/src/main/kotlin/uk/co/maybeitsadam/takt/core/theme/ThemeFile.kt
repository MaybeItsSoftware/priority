package uk.co.maybeitsadam.takt.core.theme

import uniffi.takt_core.CoreThemePlatformSpecification
import uniffi.takt_core.themeFileEncode
import uniffi.takt_core.themeFileFromSpecification

// The format is read and written by the Rust core (core/src/theme/file.rs);
// these are its Kotlin types.

/**
 * A theme as a user writes one: a JSON document, every field optional. This is
 * the *file*, not the theme: everything in it is a partial override of the
 * theme it `extends`. [ThemeFileLoader] merges and resolves it.
 *
 * Enumerated values (appearances, designs, weights, roles) are carried as
 * strings so that one typo is one reported issue rather than a file that
 * fails to read. The format is `docs/themes.md`.
 */
data class ThemeFile(
    val identifier: String? = null,
    val name: String? = null,
    val summary: String? = null,
    val lockedAppearance: Lock = Lock.Inherit,
    val extends: Base = Base.DefaultTheme,
    /**
     * A few colours per appearance the palette is grown from; see
     * [ThemeSeeds]. Laid under [palette], which still wins role by role.
     */
    val seeds: Palette? = null,
    val palette: Palette? = null,
    val structure: Structure? = null,
    /** Per-platform structure, laid over [structure] on that platform only. */
    val platforms: Platforms? = null,
) {
    /** What the file inherits every value it does not state from. */
    sealed interface Base {
        /** Key absent: the default theme, Priority. */
        data object DefaultTheme : Base

        /** `"extends": "<identifier>"`. */
        data class Theme(val identifier: String) : Base

        /** `"extends": null`: no colours inherited. Structure still falls back to the default's. */
        data object Nothing : Base
    }

    /** `lockedAppearance`: absent inherits, `null` clears, a string sets (or is reported). */
    sealed interface Lock {
        data object Inherit : Lock
        data object Unlocked : Lock
        data class Locked(val raw: String) : Lock
    }

    /**
     * Name → hex, per appearance: a role name under `palette`, a seed name
     * under `seeds`.
     */
    data class Palette(val light: Map<String, String>? = null, val dark: Map<String, String>? = null) {
        fun of(appearance: ThemeAppearance): Map<String, String>? =
            if (appearance == ThemeAppearance.LIGHT) light else dark
    }

    data class Radius(
        val panel: Double? = null,
        val row: Double? = null,
        val control: Double? = null,
        val pill: Double? = null,
        val shell: Double? = null,
    )

    data class Border(val hairline: Double? = null, val emphasis: Double? = null, val focusRing: Double? = null)

    data class Spacing(
        val xxs: Double? = null,
        val xs: Double? = null,
        val sm: Double? = null,
        val md: Double? = null,
        val lg: Double? = null,
        val xl: Double? = null,
    )

    data class Face(val families: List<String>? = null, val design: String? = null)

    data class TypeScale(
        val caption: Double? = null,
        val body: Double? = null,
        val title: Double? = null,
        val display: Double? = null,
        val hero: Double? = null,
    )

    data class MicroLabel(
        val size: Double? = null,
        val weight: String? = null,
        val tracking: Double? = null,
        val uppercase: Boolean? = null,
        val role: String? = null,
    )

    data class Typography(
        val display: Face? = null,
        val body: Face? = null,
        val mono: Face? = null,
        val bodySize: Double? = null,
        val scale: TypeScale? = null,
        val microLabel: MicroLabel? = null,
    )

    data class Structure(
        val radius: Radius? = null,
        val border: Border? = null,
        val spacing: Spacing? = null,
        val typography: Typography? = null,
        val touchTarget: Double? = null,
        val usesShadows: Boolean? = null,
        val usesGradientsOnChrome: Boolean? = null,
    )

    /** One platform's override. A `palette` here is read only to be reported and ignored. */
    data class PlatformOverride(val structure: Structure? = null)

    data class Platforms(
        val macos: PlatformOverride? = null,
        val ios: PlatformOverride? = null,
        val android: PlatformOverride? = null,
    ) {
        fun of(platform: ThemePlatform): PlatformOverride? = when (platform) {
            ThemePlatform.MACOS -> macos
            ThemePlatform.IOS -> ios
            ThemePlatform.ANDROID -> android
        }
    }

    /** Pretty-printed with sorted keys, in the layout every client writes, so an export diffs cleanly. */
    fun encoded(): String = themeFileEncode(core) ?: error("a theme file holds a number that is not finite")

    companion object {
        /**
         * Every value of [specification], stated explicitly: what "export" writes.
         * It still extends the default theme, so a role added later inherits
         * rather than going missing from an old export. Each of
         * [platformVariants] that differs is written as the smallest
         * `platforms.<platform>.structure` that gets back to it.
         */
        fun of(
            specification: ThemeSpecification,
            platformVariants: Map<ThemePlatform, ThemeSpecification> = emptyMap(),
        ): ThemeFile = themeFileFromSpecification(
            specification.core,
            ThemePlatform.entries.mapNotNull { platform ->
                platformVariants[platform]?.let { CoreThemePlatformSpecification(platform.core, it.core) }
            },
        ).local()
    }
}
