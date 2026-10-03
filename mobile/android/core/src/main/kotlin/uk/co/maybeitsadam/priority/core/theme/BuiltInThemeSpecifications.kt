package uk.co.maybeitsadam.priority.core.theme

import java.util.concurrent.ConcurrentHashMap

// Port of Sources/PriorityCore/Theming/BuiltInThemeSpecifications.swift.

/**
 * Chalk and Chalk Dark, resolved per platform.
 *
 * They are defined once, in Swift, and exported as JSON to `shared/themes/`;
 * the `copySharedThemes` Gradle task puts those files on this module's
 * classpath under [RESOURCE_DIRECTORY], and they are parsed from there so the
 * apps cannot drift apart on a hex value. [Fallback] stands in only while the
 * shared files do not exist yet.
 */
object BuiltInThemeSpecifications {
    const val CHALK_IDENTIFIER = "native.theme.chalk"
    const val CHALK_DARK_IDENTIFIER = "native.theme.chalk.dark"

    /** Where the shared files land on the classpath. */
    const val RESOURCE_DIRECTORY = "uk/co/maybeitsadam/priority/core/theme/builtin"
    val RESOURCE_FILES = listOf("chalk.json", "chalk-dark.json")

    private val cache = ConcurrentHashMap<ThemePlatform, List<ThemeSpecification>>()

    fun all(platform: ThemePlatform): List<ThemeSpecification> = cache.getOrPut(platform) { load(platform) }

    fun chalk(platform: ThemePlatform): ThemeSpecification = specification(CHALK_IDENTIFIER, platform)!!

    fun chalkDark(platform: ThemePlatform): ThemeSpecification = specification(CHALK_DARK_IDENTIFIER, platform)!!

    fun specification(identifier: String, platform: ThemePlatform): ThemeSpecification? =
        all(platform).firstOrNull { it.identifier == identifier }

    /** The shared files, if this build carries them. */
    fun sharedSources(): List<ThemeFileSource> = RESOURCE_FILES.mapNotNull { name ->
        BuiltInThemeSpecifications::class.java.classLoader
            ?.getResourceAsStream("$RESOURCE_DIRECTORY/$name")
            ?.use { ThemeFileSource(name, it.readBytes().decodeToString()) }
    }

    /** Whether Chalk and Chalk Dark came from the shared files rather than [Fallback]. */
    val isFromSharedFiles: Boolean get() = sharedSources().size == RESOURCE_FILES.size

    private fun load(platform: ThemePlatform): List<ThemeSpecification> {
        val sources = sharedSources()
        if (sources.size == RESOURCE_FILES.size) {
            val library = ThemeFileLoader.load(
                sources, platform, builtIns = emptyList(), defaultBase = Fallback.chalk(platform),
            )
            val chalk = library.themes.firstOrNull { it.identifier == CHALK_IDENTIFIER }
            val chalkDark = library.themes.firstOrNull { it.identifier == CHALK_DARK_IDENTIFIER }
            if (chalk != null && chalkDark != null) return listOf(chalk, chalkDark)
        }
        return listOf(Fallback.chalk(platform), Fallback.chalkDark(platform))
    }

    /**
     * The built-ins as `docs/themes.md` states them, for builds made before
     * `shared/themes/` existed. Delete once the shared files are in.
     */
    object Fallback {
        private val azure = hex("#007fff")
        private val emerald = hex("#4cc38e")
        private val raspberry = hex("#d62246")
        private val amber = hex("#ffbf00")
        private val purple = hex("#7a4de8")
        private val pink = hex("#ff88dc")
        private val orange = hex("#ff6b2b")

        val palette = ThemePalette(
            light = mapOf(
                ThemeColorRole.PAPER to hex("#faf8f4"),
                ThemeColorRole.RAISED to hex("#ffffff"),
                ThemeColorRole.ALT_ROW to hex("#f5f3f1"),
                ThemeColorRole.HOVER to hex("#f1eff1"),
                ThemeColorRole.WELL to hex("#edebef"),
                ThemeColorRole.BORDER to hex("#e6e4ea"),
                ThemeColorRole.BORDER_MUTED to hex("#efedf2"),
                ThemeColorRole.INPUT_BORDER to hex("#d8d5dd"),
                ThemeColorRole.INK to hex("#444054"),
                ThemeColorRole.MUTED_TEXT to hex("#6e6b7c"),
                ThemeColorRole.DIM_TEXT to hex("#b6b3bf"),
                ThemeColorRole.PRIMARY to azure,
                ThemeColorRole.SUCCESS to emerald,
                ThemeColorRole.DANGER to raspberry,
                ThemeColorRole.WARNING to amber,
                ThemeColorRole.CATEGORICAL_PURPLE to purple,
                ThemeColorRole.CATEGORICAL_PINK to pink,
                ThemeColorRole.CATEGORICAL_ORANGE to orange,
                ThemeColorRole.MEDIA_LETTERBOX to hex("#000000"),
                ThemeColorRole.MEDIA_SCRIM to hex("#000000").withAlpha(0.7),
                ThemeColorRole.MEDIA_SCRIM_INK to hex("#ffffff"),
            ),
            dark = mapOf(
                ThemeColorRole.PAPER to hex("#1c1a23"),
                ThemeColorRole.RAISED to hex("#25232f"),
                ThemeColorRole.ALT_ROW to hex("#211f29"),
                ThemeColorRole.HOVER to hex("#2d2b38"),
                ThemeColorRole.WELL to hex("#2d2b38"),
                ThemeColorRole.BORDER to hex("#34313f"),
                ThemeColorRole.BORDER_MUTED to hex("#2d2b38"),
                ThemeColorRole.INPUT_BORDER to hex("#403d4d"),
                ThemeColorRole.INK to hex("#f5f4f7"),
                ThemeColorRole.MUTED_TEXT to hex("#b6b3bf"),
                ThemeColorRole.DIM_TEXT to hex("#6e6b7c"),
                ThemeColorRole.PRIMARY to azure,
                ThemeColorRole.SUCCESS to emerald,
                ThemeColorRole.DANGER to raspberry,
                ThemeColorRole.WARNING to amber,
                ThemeColorRole.CATEGORICAL_PURPLE to purple,
                ThemeColorRole.CATEGORICAL_PINK to pink,
                ThemeColorRole.CATEGORICAL_ORANGE to orange,
            ),
        )

        /** "Chalk's defaults per platform" in `docs/themes.md`. */
        fun structure(platform: ThemePlatform): ThemeStructure {
            val (bodySize, scale, microSize) = when (platform) {
                ThemePlatform.MACOS -> Triple(13.0, ThemeTypeScale(12.0, 13.0, 15.0, 28.0, 64.0), 12.0)
                ThemePlatform.IOS -> Triple(17.0, ThemeTypeScale(13.0, 17.0, 20.0, 34.0, 72.0), 13.0)
                ThemePlatform.ANDROID -> Triple(16.0, ThemeTypeScale(12.0, 16.0, 20.0, 32.0, 72.0), 12.0)
            }
            val radius = when (platform) {
                ThemePlatform.MACOS -> ThemeRadiusScale(panel = 0.0, row = 0.0, control = 4.0, pill = 9999.0, shell = 20.0)
                else -> ThemeRadiusScale(panel = 8.0, row = 0.0, control = 6.0, pill = 9999.0, shell = 20.0)
            }
            val touchTarget = when (platform) {
                ThemePlatform.MACOS -> 0.0
                ThemePlatform.IOS -> 44.0
                ThemePlatform.ANDROID -> 48.0
            }
            return ThemeStructure(
                radius = radius,
                border = ThemeBorderScale(hairline = 1.0, emphasis = 2.0, focusRing = 2.0),
                spacing = ThemeSpacingScale(xxs = 2.0, xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 24.0),
                typography = ThemeTypography(
                    display = ThemeFontFace(listOf("IBM Plex Sans"), ThemeFontDesign.SANS),
                    body = ThemeFontFace(listOf("IBM Plex Sans"), ThemeFontDesign.SANS),
                    mono = ThemeFontFace(listOf("Lilex"), ThemeFontDesign.MONOSPACED),
                    bodySize = bodySize,
                    scale = scale,
                    microLabel = ThemeMicroLabel(
                        size = microSize, weight = ThemeFontWeight.REGULAR, tracking = 0.0,
                        isUppercased = false, role = ThemeColorRole.MUTED_TEXT,
                    ),
                ),
                touchTarget = touchTarget,
            )
        }

        fun chalk(platform: ThemePlatform) = ThemeSpecification(
            identifier = CHALK_IDENTIFIER,
            name = "Chalk",
            summary = "The house style. Warm off-white paper, grape ink, hairline borders, and colour kept for meaning.",
            palette = palette,
            structure = structure(platform),
        )

        fun chalkDark(platform: ThemePlatform) = ThemeSpecification(
            identifier = CHALK_DARK_IDENTIFIER,
            name = "Chalk Dark",
            summary = "The house style with the lights off. The same grape hue pulled down, never neutral grey.",
            lockedAppearance = ThemeAppearance.DARK,
            palette = palette,
            structure = structure(platform),
        )

        private fun hex(value: String) = ThemeColorValue.hex(value) ?: ThemeColorValue.UNRESOLVED
    }
}
