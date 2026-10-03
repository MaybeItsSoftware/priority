package uk.co.maybeitsadam.priority.core.theme

import java.util.concurrent.ConcurrentHashMap

// Counterpart of Sources/PriorityCore/Theming/BuiltInThemeSpecifications.swift.

/**
 * Chalk and Chalk Dark, resolved per platform.
 *
 * They are defined once, in Swift, and exported as complete JSON to
 * `shared/themes/`. The `copySharedThemes` Gradle task puts those files on
 * this module's classpath under [RESOURCE_DIRECTORY], and they are parsed from
 * there like any other theme file, so the apps cannot drift apart on a hex
 * value. There is no Kotlin copy to fall back on: a build without them fails.
 */
object BuiltInThemeSpecifications {
    const val CHALK_IDENTIFIER = "native.theme.chalk"
    const val CHALK_DARK_IDENTIFIER = "native.theme.chalk.dark"

    /** Where the shared files land on the classpath. */
    const val RESOURCE_DIRECTORY = "uk/co/maybeitsadam/priority/core/theme/builtin"
    val RESOURCE_FILES = listOf("chalk.json", "chalk-dark.json")

    private val cache = ConcurrentHashMap<ThemePlatform, List<ThemeSpecification>>()

    /** Chalk, then Chalk Dark. */
    fun all(platform: ThemePlatform): List<ThemeSpecification> = cache.getOrPut(platform) { load(platform) }

    fun chalk(platform: ThemePlatform): ThemeSpecification = all(platform)[0]

    fun chalkDark(platform: ThemePlatform): ThemeSpecification = all(platform)[1]

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
        return listOf(CHALK_IDENTIFIER, CHALK_DARK_IDENTIFIER).map { identifier ->
            library.themes.firstOrNull { it.identifier == identifier }
                ?: error("$identifier did not load from shared/themes: ${library.issues}")
        }
    }

    /**
     * The base the shared files are laid over. Both say `"extends": null` and
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
