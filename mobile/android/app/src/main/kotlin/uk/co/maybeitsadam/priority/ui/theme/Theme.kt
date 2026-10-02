package uk.co.maybeitsadam.priority.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import uk.co.maybeitsadam.priority.R

/** IBM Plex Sans for everything read, Lilex for numbers and code: Zed's pair. */
object Fonts {
    val sans = FontFamily(
        Font(R.font.ibmplexsans_regular, FontWeight.Normal),
        Font(R.font.ibmplexsans_italic, FontWeight.Normal, FontStyle.Italic),
        Font(R.font.ibmplexsans_medium, FontWeight.Medium),
        Font(R.font.ibmplexsans_semibold, FontWeight.SemiBold),
        Font(R.font.ibmplexsans_bold, FontWeight.Bold),
    )
    val mono = FontFamily(
        Font(R.font.lilex_regular, FontWeight.Normal),
        Font(R.font.lilex_medium, FontWeight.Medium),
        Font(R.font.lilex_bold, FontWeight.Bold),
    )
}

/** Spacing, radii and hairlines. Square-ish Zed proportions with the house radius scale. */
object Metrics {
    val xxs: Dp = 2.dp
    val xs: Dp = 4.dp
    val sm: Dp = 8.dp
    val md: Dp = 12.dp
    val lg: Dp = 16.dp
    val xl: Dp = 24.dp
    val hairline: Dp = 1.dp
    val cardRadius: Dp = 8.dp
    val controlRadius: Dp = 6.dp
    val touchTarget: Dp = 48.dp
    val rowHeight: Dp = 48.dp
    /** Indent per outline level; a phone runs out of width four levels down. */
    val indent: Dp = 18.dp
    val headerHeight: Dp = 52.dp
    val inspectorWidth: Dp = 380.dp

    val card = RoundedCornerShape(cardRadius)
    val control = RoundedCornerShape(controlRadius)
}

/** The text styles the app uses, by role rather than by Material's size names. */
@Immutable
data class PriorityType(
    val title: TextStyle,
    val heading: TextStyle,
    val body: TextStyle,
    val bodyStrong: TextStyle,
    val small: TextStyle,
    /** Sentence-case muted label: section headers, captions. Never uppercase. */
    val label: TextStyle,
    val mono: TextStyle,
    val monoSmall: TextStyle,
    val monoLarge: TextStyle,
)

private val priorityType = PriorityType(
    title = TextStyle(fontFamily = Fonts.sans, fontWeight = FontWeight.SemiBold, fontSize = 20.sp, lineHeight = 26.sp),
    heading = TextStyle(fontFamily = Fonts.sans, fontWeight = FontWeight.Medium, fontSize = 16.sp, lineHeight = 22.sp),
    body = TextStyle(fontFamily = Fonts.sans, fontWeight = FontWeight.Normal, fontSize = 15.sp, lineHeight = 21.sp),
    bodyStrong = TextStyle(fontFamily = Fonts.sans, fontWeight = FontWeight.Medium, fontSize = 15.sp, lineHeight = 21.sp),
    small = TextStyle(fontFamily = Fonts.sans, fontWeight = FontWeight.Normal, fontSize = 13.sp, lineHeight = 18.sp),
    label = TextStyle(fontFamily = Fonts.sans, fontWeight = FontWeight.Medium, fontSize = 13.sp, lineHeight = 18.sp),
    mono = TextStyle(fontFamily = Fonts.mono, fontWeight = FontWeight.Normal, fontSize = 13.sp, lineHeight = 18.sp),
    monoSmall = TextStyle(fontFamily = Fonts.mono, fontWeight = FontWeight.Normal, fontSize = 11.sp, lineHeight = 14.sp),
    monoLarge = TextStyle(fontFamily = Fonts.mono, fontWeight = FontWeight.Medium, fontSize = 34.sp, lineHeight = 40.sp),
)

val LocalPalette = staticCompositionLocalOf { ChalkPalette.ChalkLight }
val LocalPriorityType = staticCompositionLocalOf { priorityType }

/** Shorthand: `Chalk.colors.ink`, `Chalk.type.label`. */
object Chalk {
    val colors: ChalkPalette
        @Composable get() = LocalPalette.current
    val type: PriorityType
        @Composable get() = LocalPriorityType.current
}

/** The palette a spec and a mode resolve to. */
fun ThemeSpec.palette(mode: ThemeMode, systemDark: Boolean): ChalkPalette = when (lockedAppearance) {
    "dark" -> dark
    "light" -> light
    else -> when (mode) {
        ThemeMode.LIGHT -> light
        ThemeMode.DARK -> dark
        ThemeMode.SYSTEM -> if (systemDark) dark else light
    }
}

/**
 * Material 3, themed down to Chalk: every surface tone is paper or raised (no
 * tonal elevation), the outline is the hairline border, and the shapes are the
 * 6dp / 8dp scale. Components still read [Chalk] for anything Material lacks.
 */
@Composable
fun PriorityTheme(
    spec: ThemeSpec = ThemeSpec.Chalk,
    mode: ThemeMode = ThemeMode.SYSTEM,
    content: @Composable () -> Unit,
) {
    val systemDark = isSystemInDarkTheme()
    val palette = spec.palette(mode, systemDark)
    val scheme = remember(palette) { palette.toColorScheme() }
    val typography = remember { materialTypography() }
    CompositionLocalProvider(LocalPalette provides palette, LocalPriorityType provides priorityType) {
        MaterialTheme(colorScheme = scheme, typography = typography, shapes = shapes, content = content)
    }
}

private val shapes = Shapes(
    extraSmall = RoundedCornerShape(Metrics.controlRadius),
    small = RoundedCornerShape(Metrics.controlRadius),
    medium = RoundedCornerShape(Metrics.cardRadius),
    large = RoundedCornerShape(Metrics.cardRadius),
    extraLarge = RoundedCornerShape(Metrics.cardRadius),
)

private fun ChalkPalette.toColorScheme() = if (isDark) {
    darkColorScheme(
        primary = primary, onPrimary = onAccent, primaryContainer = primary.copy(alpha = 0.16f), onPrimaryContainer = ink,
        secondary = mutedText, onSecondary = paper, secondaryContainer = well, onSecondaryContainer = ink,
        tertiary = categoricalPurple, onTertiary = onAccent, tertiaryContainer = well, onTertiaryContainer = ink,
        background = paper, onBackground = ink, surface = paper, onSurface = ink, surfaceVariant = well,
        onSurfaceVariant = mutedText, surfaceTint = Color.Transparent, inverseSurface = ink, inverseOnSurface = paper,
        inversePrimary = primary, error = danger, onError = onAccent, errorContainer = danger.copy(alpha = 0.16f),
        onErrorContainer = ink, outline = inputBorder, outlineVariant = border, scrim = Color(0x99000000),
        surfaceBright = raised, surfaceDim = paper, surfaceContainer = raised, surfaceContainerHigh = raised,
        surfaceContainerHighest = raised, surfaceContainerLow = raised, surfaceContainerLowest = raised,
    )
} else {
    lightColorScheme(
        primary = primary, onPrimary = onAccent, primaryContainer = primary.copy(alpha = 0.12f), onPrimaryContainer = ink,
        secondary = mutedText, onSecondary = raised, secondaryContainer = well, onSecondaryContainer = ink,
        tertiary = categoricalPurple, onTertiary = onAccent, tertiaryContainer = well, onTertiaryContainer = ink,
        background = paper, onBackground = ink, surface = paper, onSurface = ink, surfaceVariant = well,
        onSurfaceVariant = mutedText, surfaceTint = Color.Transparent, inverseSurface = ink, inverseOnSurface = paper,
        inversePrimary = primary, error = danger, onError = onAccent, errorContainer = danger.copy(alpha = 0.12f),
        onErrorContainer = ink, outline = inputBorder, outlineVariant = border, scrim = Color(0x66000000),
        surfaceBright = raised, surfaceDim = paper, surfaceContainer = raised, surfaceContainerHigh = raised,
        surfaceContainerHighest = raised, surfaceContainerLow = raised, surfaceContainerLowest = raised,
    )
}

private fun materialTypography(): Typography {
    val base = Typography()
    fun TextStyle.plex() = copy(fontFamily = Fonts.sans)
    return Typography(
        displayLarge = base.displayLarge.plex(), displayMedium = base.displayMedium.plex(),
        displaySmall = base.displaySmall.plex(), headlineLarge = base.headlineLarge.plex(),
        headlineMedium = base.headlineMedium.plex(), headlineSmall = base.headlineSmall.plex(),
        titleLarge = priorityType.title, titleMedium = priorityType.heading, titleSmall = priorityType.bodyStrong,
        bodyLarge = priorityType.body, bodyMedium = priorityType.body, bodySmall = priorityType.small,
        labelLarge = priorityType.bodyStrong.copy(fontSize = 14.sp), labelMedium = priorityType.label,
        labelSmall = priorityType.small.copy(fontSize = 11.sp),
    )
}
