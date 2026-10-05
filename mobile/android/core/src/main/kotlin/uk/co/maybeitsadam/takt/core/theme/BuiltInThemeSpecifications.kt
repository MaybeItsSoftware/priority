package uk.co.maybeitsadam.takt.core.theme

import java.util.concurrent.ConcurrentHashMap

// Counterpart of Sources/TaktCore/Theming/BuiltInThemeSpecifications.swift.

/**
 * Priority (the default), then Zed and Zed Dark, resolved per platform.
 *
 * They are defined once, in Swift, and exported as complete JSON to
 * `shared/themes/`. The `copySharedThemes` Gradle task puts those files on
 * this module's classpath under [RESOURCE_DIRECTORY], and they are parsed from
 * there like any other theme file, so the apps cannot drift apart on a hex
 * value. There is no Kotlin copy to fall back on: a build without them fails.
 */
object BuiltInThemeSpecifications {
    /**
     * Priority, the default: what a fresh install shows, what a theme file
     * extends unless it says otherwise, and what stands in for a theme that
     * will not load.
     */
    const val PRIORITY_IDENTIFIER = "native.theme.priority"

    /**
     * The Zed look. The identifiers still say Chalk, its old name, because
     * they are stored as people's choice and synced between devices.
     */
    const val CHALK_IDENTIFIER = "native.theme.chalk"
    const val CHALK_DARK_IDENTIFIER = "native.theme.chalk.dark"

    /** Grape: the house design language — Zed's palette with Arvo, Geist Mono and small capitals. */
    const val GRAPE_IDENTIFIER = "native.theme.grape"

    /** The identifier a device uses when nothing has been chosen. */
    const val DEFAULT_IDENTIFIER = PRIORITY_IDENTIFIER

    private val IDENTIFIERS = listOf(PRIORITY_IDENTIFIER, CHALK_IDENTIFIER, CHALK_DARK_IDENTIFIER, GRAPE_IDENTIFIER)

    /** Where the shared files land on the classpath. */
    const val RESOURCE_DIRECTORY = "uk/co/maybeitsadam/takt/core/theme/builtin"
    val RESOURCE_FILES = listOf("priority.json", "chalk.json", "chalk-dark.json", "grape.json")

    private val cache = ConcurrentHashMap<ThemePlatform, List<ThemeSpecification>>()

    /** Priority, then Zed, Zed Dark and Grape: the default first. */
    fun all(platform: ThemePlatform): List<ThemeSpecification> = cache.getOrPut(platform) { load(platform) }

    /** The default theme, resolved for [platform]. */
    fun defaultTheme(platform: ThemePlatform): ThemeSpecification = priority(platform)

    fun priority(platform: ThemePlatform): ThemeSpecification = all(platform)[0]

    /** Zed, under its old identifier. */
    fun chalk(platform: ThemePlatform): ThemeSpecification = all(platform)[1]

    /** Zed Dark, under its old identifier. */
    fun chalkDark(platform: ThemePlatform): ThemeSpecification = all(platform)[2]

    fun grape(platform: ThemePlatform): ThemeSpecification = all(platform)[3]

    fun specification(identifier: String, platform: ThemePlatform): ThemeSpecification? =
        all(platform).firstOrNull { it.identifier == identifier }

    /** The shared files, read from the classpath. */
    fun sharedSources(): List<ThemeFileSource> = RESOURCE_FILES.map { name ->
        val stream = BuiltInThemeSpecifications::class.java.classLoader?.getResourceAsStream("$RESOURCE_DIRECTORY/$name")
            ?: error("shared/themes/$name is not on the classpath; the copySharedThemes task puts it there")
        stream.use { ThemeFileSource(name, it.readBytes().decodeToString()) }
    }

    /** What loading the shared files reported, for tests. */
    fun library(platform: ThemePlatform): ThemeFileLibrary =
        ThemeFileLoader.load(sharedSources(), platform, builtIns = emptyList(), defaultBase = bootstrap)

    private fun load(platform: ThemePlatform): List<ThemeSpecification> {
        val library = library(platform)
        return IDENTIFIERS.map { identifier ->
            library.themes.firstOrNull { it.identifier == identifier }
                ?: error("$identifier did not load from shared/themes: ${library.issues}")
        }
    }

    /**
     * The base the shared files are laid over. All say `"extends": null` and
     * state every value, so none of this survives into a built-in; it exists
     * because a merge needs something underneath. A test checks the files
     * really do state everything.
     */
    internal val bootstrap: ThemeSpecification = run {
        val nothing = ThemeColorValue.UNRESOLVED
        val face = ThemeFontFace(emptyList(), ThemeFontDesign.SANS)
        ThemeSpecification(
            identifier = "bootstrap",
            name = "bootstrap",
            summary = "",
            palette = ThemePalette(ThemeColorRole.entries.associateWith { nothing }, emptyMap()),
            structure = ThemeStructure(
                radius = ThemeRadiusScale(0.0, 0.0, 0.0, 0.0, 0.0),
                border = ThemeBorderScale(0.0, 0.0, 0.0),
                spacing = ThemeSpacingScale(0.0, 0.0, 0.0, 0.0, 0.0, 0.0),
                typography = ThemeTypography(
                    display = face, body = face, mono = face, bodySize = 1.0,
                    scale = ThemeTypeScale(1.0, 1.0, 1.0, 1.0, 1.0),
                    microLabel = ThemeMicroLabel(1.0, ThemeFontWeight.REGULAR, 0.0, false, ThemeColorRole.MUTED_TEXT),
                ),
                touchTarget = 0.0,
            ),
        )
    }
}
