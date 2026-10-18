package uk.co.maybeitsadam.takt.watch.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.wear.compose.material3.ColorScheme
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Typography
import uk.co.maybeitsadam.takt.watch.R

/**
 * Takt's dark palette, as hex, for the watch. The phone's theme tokens come
 * from the Rust core, which the watch never loads, so these are the house
 * hexes themselves: grape surfaces, azure for action, the status hues.
 */
object WatchColors {
    val page = Color(0xFF1C1A23)
    val raised = Color(0xFF25232F)
    val hover = Color(0xFF2D2B38)
    val border = Color(0xFF34313F)
    val ink = Color(0xFFF5F4F7)
    val muted = Color(0xFFB6B3BF)
    val dim = Color(0xFF6E6B7C)
    val azure = Color(0xFF007FFF)
    val emerald = Color(0xFF4CC38E)
    val raspberry = Color(0xFFD62246)
    val amber = Color(0xFFFFBF00)
}

/** The radii: 8dp for cards, 6dp for buttons; nothing between. */
object WatchShape {
    val card = 8.dp
    val control = 6.dp
    val hairline = 1.dp
    /** Every tappable thing is at least this tall. */
    val target = 48.dp
}

val PlexSans = FontFamily(
    Font(R.font.ibmplexsans_regular, FontWeight.Normal),
    Font(R.font.ibmplexsans_medium, FontWeight.Medium),
)

val Lilex = FontFamily(Font(R.font.lilex_medium, FontWeight.Medium))

private val scheme = ColorScheme(
    primary = WatchColors.azure,
    primaryDim = WatchColors.azure,
    primaryContainer = WatchColors.raised,
    onPrimary = Color.White,
    onPrimaryContainer = WatchColors.ink,
    secondary = WatchColors.muted,
    secondaryContainer = WatchColors.raised,
    onSecondary = WatchColors.page,
    onSecondaryContainer = WatchColors.ink,
    tertiary = WatchColors.emerald,
    surfaceContainerLow = WatchColors.page,
    surfaceContainer = WatchColors.raised,
    surfaceContainerHigh = WatchColors.hover,
    onSurface = WatchColors.ink,
    onSurfaceVariant = WatchColors.muted,
    outline = WatchColors.border,
    outlineVariant = WatchColors.border,
    background = WatchColors.page,
    onBackground = WatchColors.ink,
    error = WatchColors.raspberry,
    onError = Color.White,
)

@Composable
fun WatchTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = scheme, typography = Typography(defaultFontFamily = PlexSans), content = content)
}
