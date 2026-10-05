package uk.co.maybeitsadam.takt.core.theme

// Port of Sources/TaktCore/Theming/ThemeStructure.swift. Every size is in
// points, which Android draws as dp (and sp for type).

/** The three apps a theme file is resolved for. Its key under `platforms`. */
enum class ThemePlatform(val raw: String) {
    MACOS("macos"),
    IOS("ios"),
    ANDROID("android");

    companion object {
        fun of(raw: String?): ThemePlatform? = entries.firstOrNull { it.raw == raw }
    }
}

data class ThemeRadiusScale(
    val panel: Double,
    val row: Double,
    val control: Double,
    val pill: Double,
    val shell: Double,
)

data class ThemeBorderScale(
    val hairline: Double,
    val emphasis: Double,
    val focusRing: Double,
)

data class ThemeSpacingScale(
    val xxs: Double,
    val xs: Double,
    val sm: Double,
    val md: Double,
    val lg: Double,
    val xl: Double,
)

enum class ThemeFontDesign(val raw: String) {
    SERIF("serif"),
    SANS("sans"),
    MONOSPACED("monospaced"),
    ROUNDED("rounded");

    companion object {
        fun of(raw: String?): ThemeFontDesign? = entries.firstOrNull { it.raw == raw }
    }
}

enum class ThemeFontWeight(val raw: String) {
    REGULAR("regular"),
    MEDIUM("medium"),
    SEMIBOLD("semibold"),
    BOLD("bold"),
    BLACK("black");

    companion object {
        fun of(raw: String?): ThemeFontWeight? = entries.firstOrNull { it.raw == raw }
    }
}

/** A face: families tried in order, then the design's system face. */
data class ThemeFontFace(val families: List<String>, val design: ThemeFontDesign)

data class ThemeMicroLabel(
    val size: Double,
    val weight: ThemeFontWeight,
    /** In em. */
    val tracking: Double,
    val isUppercased: Boolean,
    val role: ThemeColorRole,
) {
    val trackingPoints: Double get() = size * tracking
}

/** The named sizes views ask for. */
data class ThemeTypeScale(
    val caption: Double,
    val body: Double,
    val title: Double,
    val display: Double,
    val hero: Double,
) {
    companion object {
        /** The scale a body size implies, when a theme gives a size and no scale. */
        fun proportioned(fromBody: Double): ThemeTypeScale = ThemeTypeScale(
            caption = schoolbookRound(fromBody * 0.85),
            body = fromBody,
            title = schoolbookRound(fromBody * 1.25),
            display = schoolbookRound(fromBody * 2.2),
            hero = schoolbookRound(fromBody * 5),
        )
    }
}

data class ThemeTypography(
    val display: ThemeFontFace,
    val body: ThemeFontFace,
    val mono: ThemeFontFace,
    val bodySize: Double,
    val scale: ThemeTypeScale = ThemeTypeScale.proportioned(bodySize),
    val microLabel: ThemeMicroLabel,
)

data class ThemeStructure(
    val radius: ThemeRadiusScale,
    val border: ThemeBorderScale,
    val spacing: ThemeSpacingScale,
    val typography: ThemeTypography,
    /**
     * The minimum hit area a control is grown to, invisibly, so the painted
     * control keeps its size. 0 is a pointer platform with no minimum.
     */
    val touchTarget: Double = 0.0,
    val usesShadows: Boolean = false,
    val usesGradientsOnChrome: Boolean = false,
)
